import Foundation
import Darwin

// The wire between servers on this Mac: Unix domain sockets (Apple-native, no network stack, never leaves
// the machine) carrying length-prefixed frames. Each frame = 4-byte big-endian length + JSON of a BrainCore type.

public enum WireError: Error, CustomStringConvertible {
    case system(String), closed, tooLarge(Int)
    public var description: String {
        switch self {
        case .system(let s): return s
        case .closed: return "connection closed"
        case .tooLarge(let n): return "frame too large (\(n) bytes)"
        }
    }
}

public struct WireConnection: @unchecked Sendable {
    public let fd: Int32
    public init(fd: Int32) { self.fd = fd }

    public func send<T: Encodable>(_ value: T) throws {
        let body = try JSONEncoder().encode(value)
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        try frame.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { throw WireError.system("write failed: \(String(cString: strerror(errno)))") }
                off += n
            }
        }
    }

    public func receive<T: Decodable>(_ type: T.Type) throws -> T {
        let header = try readExactly(4)
        let len = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard len <= 64 << 20 else { throw WireError.tooLarge(len) }
        return try JSONDecoder().decode(T.self, from: try readExactly(len))
    }

    private func readExactly(_ n: Int) throws -> Data {
        var data = Data(count: n)
        var off = 0
        try data.withUnsafeMutableBytes { raw in
            while off < n {
                let r = Darwin.read(fd, raw.baseAddress! + off, n - off)
                if r == 0 { throw WireError.closed }
                if r < 0 { throw WireError.system("read failed: \(String(cString: strerror(errno)))") }
                off += r
            }
        }
        return data
    }

    public func close() { Darwin.close(fd) }
}

public enum Wire {
    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    /// Listen on a Unix socket; calls `handler` on a background thread for each connection.
    public static func listen(at path: String, handler: @escaping @Sendable (WireConnection) -> Void) throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.system("socket() failed") }
        var addr = address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw WireError.system("bind(\(path)) failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)   // only this user can talk to the brain
        guard Darwin.listen(fd, 16) == 0 else { throw WireError.system("listen() failed") }
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                Thread.detachNewThread { handler(WireConnection(fd: c)) }
            }
        }
    }

    public static func connect(to path: String) throws -> WireConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.system("socket() failed") }
        var addr = address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(fd); throw WireError.system("connect(\(path)) failed: \(String(cString: strerror(errno)))") }
        return WireConnection(fd: fd)
    }
}
