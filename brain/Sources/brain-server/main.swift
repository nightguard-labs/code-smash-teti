import Foundation
import BrainCore
import BrainEngine
import BrainMind

// brain-server: the main server of Code Smash TeTi. Organs run as Swift actors in parallel:
//   Engine (GPU) · WorkingMemory (Si) · KnowledgeBank (Ni) · Values (Fi)
// Doors:
//   • Unix socket  ~/local-ai/brain-lab/run/brain.sock  (other brain servers; BrainCore frames)
//   • HTTP 127.0.0.1:11450, Ollama-compatible            (chat apps, bench, other tools)
//
//   brain-server --model <mlx model folder> [--name label] [--port 11451 --socket run/fast.sock]

setvbuf(stdout, nil, _IOLBF, 0)
func arg(_ n: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: n), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

let engine = Engine()
let si = WorkingMemory()
let ni = KnowledgeBank()

/// The mind wraps every request: values first, then recalled knowledge (Ni) and project memory (Si).
func enrich(_ req: GenerateRequest) async -> GenerateRequest {
    var r = req
    // The FIRST user message (the task), not the last: the last changes every step, so the recalled facts at the top of
    // the prompt changed too and prompt memory missed every time (80B, 11/10: ~70 s re-reading per step).
    let ask = req.messages.first(where: { $0.role == .user })?.content ?? ""
    var system = Values.preamble
    // A caller with its own system message (TeTi's thinking loop) already recalls its own knowledge. Adding the server's
    // recall on top made the top of the prompt differ call to call (recall reorders as it's used), so prompt memory
    // missed nearly every step (11/10). Those callers get only the fixed rules, which never change.
    if let i = r.messages.firstIndex(where: { $0.role == .system }) {
        if !r.messages[i].content.contains("Hard rules: nothing leaves this computer") { r.messages[i].content = system + "\n\n" + r.messages[i].content }
        return r
    }
    let known = await ni.recall(ask)
    if !known.isEmpty {
        system += "\n\nVERIFIED KNOWLEDGE (proven earlier, strongest first):\n" +
            known.map { "- \($0.text)" }.joined(separator: "\n")
    }
    if let p = req.project { system += "\n\n" + (await si.journal(p)).briefing }
    if let i = r.messages.firstIndex(where: { $0.role == .system }) {
        r.messages[i].content = system + "\n\n" + r.messages[i].content
    } else {
        r.messages.insert(BrainMessage(role: .system, content: system), at: 0)
    }
    return r
}

// ---- load the model
guard let modelPath = arg("--model") else {
    print("usage: brain-server --model <mlx model folder> [--name label]"); exit(2)
}
let name = arg("--name") ?? URL(fileURLWithPath: modelPath).lastPathComponent
print("🧠 Code Smash TeTi: loading \(name) …")
let t0 = Date()
do { try await engine.load(directory: URL(fileURLWithPath: modelPath), name: name) }
catch { print("✗ load failed: \(error)"); exit(1) }
print(String(format: "✓ loaded in %.1fs", Date().timeIntervalSince(t0)))

// ---- door 1: Unix socket for the other brain servers
try FileManager.default.createDirectory(at: BrainPaths.run, withIntermediateDirectories: true)
// --port / --socket let a second server (the fast lane, 127.0.0.1:11451) run beside the big brain
let httpPort = UInt16(arg("--port") ?? "") ?? BrainPorts.edgeHTTP
let sockPath = arg("--socket") ?? BrainPaths.socket.path
try Wire.listen(at: sockPath) { conn in
    defer { conn.close() }
    guard let req = try? conn.receive(GenerateRequest.self) else { return }
    let sem = DispatchSemaphore(value: 0)
    Task {
        for await ev in await engine.generate(await enrich(req)) { try? conn.send(ev) }
        sem.signal()
    }
    sem.wait()
}
print("✓ socket door: \(sockPath)")

// ---- door 2: Ollama-compatible HTTP edge
let edge = try HTTPEdge(port: httpPort) { req, out in
    switch (req.method, req.path) {
    case ("GET", "/"), ("GET", "/health"):
        var h: [String: Any] = ["status": "ok", "model": await engine.modelName, "knowledge": await ni.count]
        if let st = await engine.streamStats { h["experts"] = st.line }
        let (re, rd) = (await engine.reusedTokens, await engine.readTokens)
        if re + rd > 0 { h["promptMemory"] = String(format: "%d of %d prompt tokens remembered (%.0f%%)", re, re + rd, Double(re) / Double(re + rd) * 100) }
        await out.json(h)
    case ("GET", "/api/tags"):
        await out.json(["models": [["name": "code-smash-teti", "model": "code-smash-teti", "details": ["family": await engine.modelName]]]])
    case ("POST", "/api/chat"):
        guard let j = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            await out.json(["error": "bad JSON"], status: 400); return
        }
        let msgs = (j["messages"] as? [[String: Any]] ?? []).compactMap { m -> BrainMessage? in
            guard let r = Role(rawValue: m["role"] as? String ?? ""), let c = m["content"] as? String else { return nil }
            return BrainMessage(role: r, content: c)
        }
        let opts = j["options"] as? [String: Any] ?? [:]
        let g = GenerateRequest(messages: msgs,
                                maxTokens: opts["num_predict"] as? Int ?? 4096,
                                temperature: Float(opts["temperature"] as? Double ?? 0.3),
                                think: j["think"] as? Bool ?? false,
                                project: j["project"] as? String)
        let stream = j["stream"] as? Bool ?? true
        var text = ""
        var stats: GenerateStats?
        for await ev in await engine.generate(await enrich(g)) {
            switch ev {
            case .token(let s):
                text += s
                if stream {
                    let line = try! JSONSerialization.data(withJSONObject: [
                        "model": "code-smash-teti", "message": ["role": "assistant", "content": s], "done": false])
                    await out.write(String(decoding: line, as: UTF8.self) + "\n")
                }
            case .done(let st): stats = st
            case .failure(let e): await out.json(["error": e], status: 500); return
            }
        }
        var final: [String: Any] = ["model": "code-smash-teti", "done": true, "done_reason": "stop",
                                    "eval_count": stats?.generatedTokens ?? 0,
                                    "prompt_eval_count": stats?.promptTokens ?? 0,
                                    "eval_duration": Int((Double(stats?.generatedTokens ?? 0) / max(stats?.tokensPerSecond ?? 1, 0.001)) * 1e9)]
        final["message"] = ["role": "assistant", "content": stream ? "" : text]
        let d = try! JSONSerialization.data(withJSONObject: final)
        await out.write(String(decoding: d, as: UTF8.self) + (stream ? "\n" : ""))
    default:
        await out.json(["error": "not found"], status: 404)
    }
}
edge.start()
print("✓ HTTP edge: http://127.0.0.1:\(httpPort)  (Ollama-compatible /api/chat)")
print("🧠 Code Smash TeTi is awake")

// keep running
while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
