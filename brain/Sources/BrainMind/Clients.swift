import Foundation
import BrainCore

/// Anything that can think: the brain's own engine, or (for testing) another local model.
public protocol ModelClient: Sendable {
    func complete(_ messages: [BrainMessage], maxTokens: Int, think: Bool) async throws -> String
}

/// Talks to an Ollama-style /api/chat on this Mac (the brain-server edge speaks the same API).
/// Localhost only by construction.
public struct LocalChatClient: ModelClient {
    public let host: String, model: String, numCtx: Int
    public init(host: String = "http://127.0.0.1:11435", model: String = "qwen3.6-shared", numCtx: Int = 65536) {
        precondition(host.contains("127.0.0.1") || host.contains("localhost"), "local models only")
        self.host = host; self.model = model; self.numCtx = numCtx
    }

    public func complete(_ messages: [BrainMessage], maxTokens: Int, think: Bool) async throws -> String {
        var req = URLRequest(url: URL(string: host + "/api/chat")!, timeoutInterval: 1800)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "think": think,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "options": ["num_ctx": numCtx, "temperature": 0.3, "num_predict": maxTokens]])
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let e = obj["error"] { throw NSError(domain: "model", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(e)"]) }
        return ((obj["message"] as? [String: Any])?["content"] as? String) ?? ""
    }
}

/// The brain's own door: a private Unix socket (run/brain.sock, owner-only permissions), length-prefixed JSON frames,
/// tokens streamed straight from the engine. Used by the brain's own parts (front desk, thinking loop, sleep);
/// HTTP stays only as the edge for outside apps. Nothing here can leave the Mac.
public struct BrainSocketClient: ModelClient {
    public let path: String
    public let temperature: Float
    public init(path: String = BrainPaths.socket.path, temperature: Float = 0.3) { self.path = path; self.temperature = temperature }

    public func complete(_ messages: [BrainMessage], maxTokens: Int, think: Bool) async throws -> String {
        let req = GenerateRequest(messages: messages, maxTokens: maxTokens, temperature: temperature, think: think)
        let path = self.path
        // the socket calls block, so they run on their own thread instead of holding up Swift's async workers
        return try await withCheckedThrowingContinuation { cont in
            Thread.detachNewThread {
                do {
                    let conn = try Wire.connect(to: path)
                    defer { conn.close() }
                    try conn.send(req)
                    var text = ""
                    loop: while true {
                        switch try conn.receive(BrainEvent.self) {
                        case .token(let t): text += t
                        case .done: break loop
                        case .failure(let f): throw NSError(domain: "brain", code: 1, userInfo: [NSLocalizedDescriptionKey: f])
                        }
                    }
                    cont.resume(returning: text)
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}

public enum BrainLink {
    /// Which model is in the brain server right now (read from its status sign), nil if it's not running.
    public static func serverModel() async -> String? {
        guard let u = URL(string: "http://127.0.0.1:\(BrainPorts.edgeHTTP)/health"),
              let (d, _) = try? await URLSession.shared.data(from: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["model"] as? String
    }
    /// The real Code Smash TeTi over its own socket door if it's running, else the shared local model stands in.
    public static func best() async -> (client: ModelClient, name: String, isBrain: Bool) {
        if let m = await serverModel(), !m.hasPrefix("test-patient"), FileManager.default.fileExists(atPath: BrainPaths.socket.path) {
            return (BrainSocketClient(), "Code Smash TeTi (\(m), socket door)", true)
        }
        return (LocalChatClient(), "qwen3.6-shared (stand-in until the brain is live)", false)
    }
}
