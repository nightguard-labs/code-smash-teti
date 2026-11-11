import Foundation
import Darwin

// Shared relay language (engine ⇄ SSD relay). Owner design 11/05:
//  • one-way lanes: requests go engine → relay on the request lane; data comes back relay → engine on
//    separate data lanes (one per read lane), so nothing waits for traffic going the other way
//  • many lanes per drive, and every request takes the path of least resistance (shortest expected wait)

/// Where the knowledge bank's blocks (experts) live. Written by the `lay` tool, read by the relay.
public struct BankIndex: Codable, Sendable {
    public struct Drive: Codable, Sendable {
        public var name: String
        public var file: String      // bank file on that drive
        public var lanes: Int        // parallel read lanes to open on it
        public init(name: String, file: String, lanes: Int) { self.name = name; self.file = file; self.lanes = lanes }
    }
    public struct Location: Codable, Sendable {
        public var drive: Int
        public var offset: Int
        public init(drive: Int, offset: Int) { self.drive = drive; self.offset = offset }
    }
    public struct Block: Codable, Sendable {
        public var id: Int
        public var length: Int
        public var locations: [Location]   // more than one = mirrored on several drives
        public init(id: Int, length: Int, locations: [Location]) { self.id = id; self.length = length; self.locations = locations }
    }
    public var drives: [Drive]
    public var blocks: [Block]
    public init(drives: [Drive], blocks: [Block]) { self.drives = drives; self.blocks = blocks }
}

/// Request lane message (engine → relay): fixed 12 bytes, no JSON on the hot path.
public struct RelayAsk: Sendable {
    public var id: UInt64
    public var block: UInt32
    public init(id: UInt64, block: UInt32) { self.id = id; self.block = block }
    public static let size = 12
    public func encode() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Self.size)
        withUnsafeBytes(of: id.bigEndian) { for i in 0..<8 { b[i] = $0[i] } }
        withUnsafeBytes(of: block.bigEndian) { for i in 0..<4 { b[8 + i] = $0[i] } }
        return b
    }
    public static func decode(_ p: UnsafeRawPointer) -> RelayAsk {
        RelayAsk(id: UInt64(bigEndian: p.loadUnaligned(as: UInt64.self)),
                 block: UInt32(bigEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
    }
}

/// Data lane frame header (relay → engine), followed by `length` bytes of block data.
public struct RelayDelivery: Sendable {
    public var id: UInt64, block: UInt32, length: UInt32, lane: UInt16, stolen: UInt16, micros: UInt32
    public static let size = 24
    public init(id: UInt64, block: UInt32, length: UInt32, lane: UInt16, stolen: UInt16, micros: UInt32) {
        self.id = id; self.block = block; self.length = length; self.lane = lane; self.stolen = stolen; self.micros = micros
    }
    public func write(to p: UnsafeMutableRawPointer) {
        p.storeBytes(of: id.bigEndian, toByteOffset: 0, as: UInt64.self)
        p.storeBytes(of: block.bigEndian, toByteOffset: 8, as: UInt32.self)
        p.storeBytes(of: length.bigEndian, toByteOffset: 12, as: UInt32.self)
        p.storeBytes(of: lane.bigEndian, toByteOffset: 16, as: UInt16.self)
        p.storeBytes(of: stolen.bigEndian, toByteOffset: 18, as: UInt16.self)
        p.storeBytes(of: micros.bigEndian, toByteOffset: 20, as: UInt32.self)
    }
    public static func read(_ p: UnsafeRawPointer) -> RelayDelivery {
        RelayDelivery(id: UInt64(bigEndian: p.loadUnaligned(as: UInt64.self)),
                      block: UInt32(bigEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                      length: UInt32(bigEndian: p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                      lane: UInt16(bigEndian: p.loadUnaligned(fromByteOffset: 16, as: UInt16.self)),
                      stolen: UInt16(bigEndian: p.loadUnaligned(fromByteOffset: 18, as: UInt16.self)),
                      micros: UInt32(bigEndian: p.loadUnaligned(fromByteOffset: 20, as: UInt32.self)))
    }
}

public extension BrainPaths {
    static let relayRequests = run.appendingPathComponent("relay-req.sock")
    static let relayData = run.appendingPathComponent("relay-data.sock")
}

/// Raw, blocking byte I/O helpers for the hot path.
public enum RawIO {
    public static func writeAll(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let w = Darwin.write(fd, p + off, n - off)
            if w <= 0 { if errno == EINTR { continue }; return false }
            off += w
        }
        return true
    }
    public static func readAll(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let r = Darwin.read(fd, p + off, n - off)
            if r <= 0 { if r < 0 && errno == EINTR { continue }; return false }
            off += r
        }
        return true
    }
    /// Listening Unix socket (owner-only permissions). Returns the listening fd.
    public static func listenUnix(_ path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let b = Array(path.utf8.prefix(buf.count - 1)); buf.copyBytes(from: b); buf[b.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 64) == 0 else { throw WireError.system("listen \(path): \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        return fd
    }
    public static func connectUnix(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let b = Array(path.utf8.prefix(buf.count - 1)); buf.copyBytes(from: b); buf[b.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { Darwin.close(fd); throw WireError.system("connect \(path): \(String(cString: strerror(errno)))") }
        var big: Int32 = 8 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}
