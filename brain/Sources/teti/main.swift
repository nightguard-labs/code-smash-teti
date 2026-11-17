import Foundation
import BrainCore
import BrainMind

// teti: run Code Smash TeTi's thinking loop on a task from the terminal.
//
//   teti solve --task "build X" --dir <project folder> [--project name] [--loops 6]
//              [--brain]                      use Code Smash TeTi's own server (127.0.0.1:11450)
//              [--model qwen3.6-shared]       or another local model (default host 127.0.0.1:11435)
//              [--lane fast|middle|big|auto]  fast = the quick 9B (server from memory/fast-lane.json)
//                                             middle = Qwen 3.6 35B team-of-experts (fits in RAM, fast)
//                                             big  = the 122B brain (same as --brain)
//                                             auto = the stack: 9B (2 loops) → 35B (2) → Qwen3-Next 80B (3) → 122B;
//                                                    each step up only if Te's checks still fail, same folder
//              [--skip fast,middle,...]       leave layers out of the stack (lane names or labels like "35B")

setvbuf(stdout, nil, _IOLBF, 0)
let argv = CommandLine.arguments
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }

guard argv.dropFirst().first == "solve", let task = opt("--task"), let dir = opt("--dir") else {
    print("usage: teti solve --task \"...\" --dir <folder> [--project name] [--loops N] [--brain | --model M --host URL]"); exit(2)
}
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let lane = opt("--lane") ?? (argv.contains("--brain") ? "big" : "custom")
// the fast lane's server: default = whichever won the fast-lane race (memory/fast-lane.json), else the Python MTP server
let fastPick = (try? JSONSerialization.jsonObject(with: Data(contentsOf: BrainPaths.memory.appendingPathComponent("fast-lane.json"))) as? [String: String]) ?? [:]
let fastClient = LocalChatClient(host: opt("--fast-host") ?? fastPick["host"] ?? "http://127.0.0.1:11440",
                                 model: opt("--fast-model") ?? fastPick["model"] ?? "qwen3.5-9b-mtp", numCtx: 32768)
let middleClient = LocalChatClient(host: opt("--middle-host") ?? fastPick["middleHost"] ?? "http://127.0.0.1:11435",
                                   model: opt("--middle-model") ?? fastPick["middleModel"] ?? "qwen3.6-shared", numCtx: 65536)
func client(for lane: String) -> ModelClient {
    switch lane {
    case "big": return BrainSocketClient()
    case "middle": return middleClient
    case "fast", "auto": return fastClient
    default: return LocalChatClient(host: opt("--host") ?? "http://127.0.0.1:11435", model: opt("--model") ?? "qwen3.6-shared")
    }
}
let printer: @Sendable (LoopEvent) -> Void = { ev in
    let t = { () -> String in let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date()) }()
    switch ev {
    case .phase(let p, let n): print("\n[\(t)] ── \(p)\(n > 0 ? "  (loop \(n))" : "") ──")
    case .note(let s): print("[\(t)]    \(s)")
    case .check(let name, let ok, let d): print("[\(t)]    \(ok ? "✅" : "❌") \(name)\(d.isEmpty ? "" : "  — \(d)")")
    case .verdict(let p, let n, let f): print("[\(t)]    Te verdict: \(p)/\(n) checks pass\n" + f.split(separator: "\n").map { "           \($0)" }.joined(separator: "\n"))
    case .branch(let s): print("[\(t)]    🌿 \(s)")
    case .finished(let r):
        print("\n══ \(r.solved ? "✅ SOLVED" : "❌ NOT SOLVED") in \(r.loops) loop(s), \(r.checksPassed)/\(r.checksTotal) checks, \(Int(r.seconds))s")
        if !r.approach.isEmpty { print("   approach: \(r.approach)") }
        if !r.files.isEmpty { print("   files: \(r.files.joined(separator: ", "))") }
        if let h = r.helpRequest { print("   help request written: \(h)") }
    }
}
let maxLoops = Int(opt("--loops") ?? "6") ?? 6
let t0 = Date()

// MARK: the brain stack (owner, 11/09): each layer gets the task only if the layers before it didn't pass Te's checks.
//   ⚡ 9B → 🧠 35B → 🦾 Qwen3-Next 80B → 🐘 Code Smash TeTi 122B (last). The 80B and 122B share the one big-brain
//   slot (127.0.0.1:11450, run by the control panel); moving between them swaps the brain (~1 min).
struct Layer { let lane: String; let label: String; let loops: Int; let brain: String? }
let skip = Set((opt("--skip") ?? "").split(separator: ",").map(String.init))
let stack: [Layer] = [
    Layer(lane: "fast", label: "⚡ 9B", loops: 2, brain: nil),   // 4-bit since 11/17 (memory/fast-lane.json)
    Layer(lane: "middle", label: "🧠 35B", loops: 2, brain: nil),
    // 80B DEMOTED 11/16 (owner): older generation, est. 5-8 words/s on 32 GB = same answers as the 35B, 4-6x slower.
    // Overnight-only with the 122B. Its slot goes to Qwen3.8-27B once the 27B passes its race.
    Layer(lane: "big", label: "🦾 Qwen3-Next 80B", loops: 3, brain: "code-smash-next"),
    // DEMOTED 11/16 (owner OK): on 32 GB the 122B writes ~1.2 words/s (2 h per task), so it can't meet the 9-minute rule.
    // It only joins as the slow overnight backup when asked: --overnight (or TETI_OVERNIGHT=1).
    Layer(lane: "big", label: "🐘 Code Smash TeTi 122B", loops: maxLoops, brain: "code-smash-teti-c90-b2"),
].filter { ($0.label.contains("122B") == false && $0.label.contains("80B") == false) || CommandLine.arguments.contains("--overnight") || ProcessInfo.processInfo.environment["TETI_OVERNIGHT"] == "1" }
 .filter { !skip.contains($0.label.components(separatedBy: " ").dropFirst().joined(separator: " ")) && !skip.contains($0.lane) }

func http(_ method: String, _ url: String, _ body: [String: Any]? = nil, timeout: Double = 30) async -> [String: Any]? {
    guard let u = URL(string: url) else { return nil }
    var r = URLRequest(url: u, timeoutInterval: timeout); r.httpMethod = method
    r.setValue("1", forHTTPHeaderField: "X-Panel"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
    guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
}
func slotModel() async -> String? { await http("GET", "http://127.0.0.1:11450/health", timeout: 5)?["model"] as? String }
/// Put `brain` in the big-brain slot (nil = the active 122B family). Frees the lighter lanes' RAM first.
func useSlot(_ brain: String?) async -> Bool {
    let want = brain ?? {
        let link = BrainPaths.models.appendingPathComponent("code-smash-teti-active").path
        let dest = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)).map { URL(fileURLWithPath: $0).lastPathComponent }
        return (dest?.hasPrefix("code-smash-teti") ?? false) ? dest! : "code-smash-teti"
    }()
    if await slotModel() == want { return true }
    _ = await http("POST", "http://127.0.0.1:11440/api/generate", ["model": "qwen3.5-9b-mtp", "keep_alive": 0], timeout: 60)
    if let fh = fastPick["host"], fh != "http://127.0.0.1:11440" {   // the 4-bit fast lane exits on this to free its RAM
        _ = await http("POST", fh + "/api/generate", ["model": fastPick["model"] ?? "", "keep_alive": 0], timeout: 20)
    }
    if let mh = fastPick["middleHost"], mh.contains("1143") {
        _ = await http("POST", mh + "/api/generate", ["model": fastPick["middleModel"] ?? "qwen3.6-shared", "keep_alive": 0], timeout: 60)
    }
    print("   🔁 big-brain slot → \(want) (about a minute to load)")
    _ = await http("POST", "http://127.0.0.1:8790/api/use", ["name": want, "force": true])
    if await slotModel() == nil { _ = await http("POST", "http://127.0.0.1:8790/api/start", [:]) }
    for _ in 0..<60 { if await slotModel() == want { return true }; try? await Task.sleep(nanoseconds: 5_000_000_000) }
    print("   ✗ \(want) didn't come up in the big-brain slot"); return false
}

/// 11/17: the fast lane is the 4-bit 9B on a small MLX server (plain_server.py). Start it on demand; it exits after
/// 10 idle minutes (or when the big-brain slot needs the RAM), so it never sits in memory unused.
func ensureFastServer() async {
    guard fastPick["engine"] == "mlx-plain", let host = fastPick["host"], let dir = fastPick["modelDir"],
          let port = URL(string: host)?.port else { return }
    if await http("GET", host + "/api/tags", timeout: 3) != nil { return }
    print("   ⚡ starting the fast lane (\(fastPick["model"] ?? "9B"))…")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: home + "/local-ai/models/mlx-venv/bin/python")
    p.arguments = [home + "/local-ai/models/plain_server.py", dir, String(port), fastPick["model"] ?? "qwen9b-4bit", "600"]
    let log = FileHandle(forWritingAtPath: home + "/local-ai/brain-lab/logs/plain-fast-lane.log")
        ?? { FileManager.default.createFile(atPath: home + "/local-ai/brain-lab/logs/plain-fast-lane.log", contents: nil)
             return FileHandle(forWritingAtPath: home + "/local-ai/brain-lab/logs/plain-fast-lane.log")! }()
    log.seekToEndOfFile(); p.standardOutput = log; p.standardError = log
    try? p.run()
    for _ in 0..<60 { if await http("GET", host + "/api/tags", timeout: 3) != nil { return }; try? await Task.sleep(nanoseconds: 2_000_000_000) }
    print("   ✗ the fast lane didn't start (see logs/plain-fast-lane.log)")
}
if lane == "fast" || lane == "auto" { await ensureFastServer() }

var solved = false
if lane == "auto" {
    var r: LoopResult? = nil
    for (i, layer) in stack.enumerated() {
        if i > 0 {
            let h = r?.handoff
            print("\n⬆️  not passing Te's checks yet: \(layer.label) takes over" +
                  (h.map { " just the parts the smaller brain couldn't do: \($0.failing.joined(separator: ", ")) (\($0.passing.count) of \($0.checks.count) checks already pass, locked)" } ?? " (it sees the earlier attempts)"))
        }
        else { print("\(layer.label) takes it first") }
        if layer.lane == "big", !(await useSlot(layer.brain)) { continue }
        r = await ThinkingLoop(model: client(for: layer.lane), dir: dir, project: opt("--project"), si: WorkingMemory(), ni: KnowledgeBank(),
                               maxLoops: min(layer.loops, maxLoops), emit: printer).run(task: task, handoff: r?.handoff)
        if r!.solved { print("   solved by: \(layer.label) · total \(Int(Date().timeIntervalSince(t0)))s"); break }
    }
    solved = r?.solved ?? false
    if !solved { print("   solved by: nobody yet · total \(Int(Date().timeIntervalSince(t0)))s") }
} else {
    if lane == "fast" { print("⚡ fast lane: Qwen 9B (\(fastPick["model"] ?? "default"))") }
    solved = await ThinkingLoop(model: client(for: lane), dir: dir, project: opt("--project"), si: WorkingMemory(), ni: KnowledgeBank(),
                                maxLoops: maxLoops, emit: printer).run(task: task).solved
}
exit(solved ? 0 : 1)
