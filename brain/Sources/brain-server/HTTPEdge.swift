import Foundation
import Network

/// Minimal HTTP/1.1 server on Apple's Network framework. Localhost only.
/// Used for the outer edge (Ollama-compatible API); servers inside the brain talk over Unix sockets instead.
final class HTTPEdge: @unchecked Sendable {
    struct Request { let method: String; let path: String; let body: Data }

    /// The handler writes the response through `Responder` (supports streaming).
    typealias Handler = @Sendable (Request, Responder) async -> Void

    final class Responder: @unchecked Sendable {
        let conn: NWConnection
        private var sentHead = false
        init(_ c: NWConnection) { conn = c }

        func head(_ status: Int = 200, type: String = "application/json") {
            guard !sentHead else { return }
            sentHead = true
            let text = status == 200 ? "OK" : status == 404 ? "Not Found" : "Error"
            let h = "HTTP/1.1 \(status) \(text)\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-cache\r\n\r\n"
            conn.send(content: Data(h.utf8), completion: .idempotent)
        }
        func write(_ s: String) async {
            head()
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                conn.send(content: Data(s.utf8), completion: .contentProcessed { _ in k.resume() })
            }
        }
        func json(_ obj: Any, status: Int = 200) async {
            head(status)
            let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            await write(String(decoding: d, as: UTF8.self))
        }
        func finish() { conn.send(content: nil, isComplete: true, completion: .contentProcessed { [conn] _ in conn.cancel() }) }
    }

    private let listener: NWListener
    private let handler: Handler

    init(port: UInt16, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: .global(qos: .userInitiated))
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .global(qos: .userInitiated))
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                let r = Responder(c)
                Task { await self.handler(req, r); r.finish() }
            } else if done || err != nil || buf.count > 32 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    /// Returns a request once headers + full body (per Content-Length) have arrived.
    static func parse(_ buf: Data) -> Request? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var length = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
            length = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = buf[sep.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), body: Data(body.prefix(length)))
    }
}
