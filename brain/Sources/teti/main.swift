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
    Layer(lane: "fast", label: "⚡ 9B", loops: 2, brain: nil),
    Layer(lane: "middle", label: "🧠 35B", loops: 2, brain: nil),
    Layer(lane: "big", label: "🦾 Qwen3-Next 80B", loops: 3, brain: "code-smash-next"),
    Layer(lane: "big", label: "🐘 Code Smash TeTi 122B", loops: maxLoops, brain: nil),   // nil = the owner's active 122B
].filter { !skip.contains($0.label.components(separatedBy: " ").dropFirst().joined(separator: " ")) && !skip.contains($0.lane) }

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
    if let mh = fastPick["middleHost"], mh.contains("1143") {
        _ = await http("POST", mh + "/api/generate", ["model": fastPick["middleModel"] ?? "qwen3.6-shared", "keep_alive": 0], timeout: 60)
    }
    print("   🔁 big-brain slot → \(want) (about a minute to load)")
    _ = await http("POST", "http://127.0.0.1:8790/api/use", ["name": want, "force": true])
    if await slotModel() == nil { _ = await http("POST", "http://127.0.0.1:8790/api/start", [:]) }
    for _ in 0..<60 { if await slotModel() == want { return true }; try? await Task.sleep(nanoseconds: 5_000_000_000) }
    print("   ✗ \(want) didn't come up in the big-brain slot"); return false
}

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
    if lane == "fast" { print("⚡ fast lane: Qwen 9B") }
    solved = await ThinkingLoop(model: client(for: lane), dir: dir, project: opt("--project"), si: WorkingMemory(), ni: KnowledgeBank(),
                                maxLoops: maxLoops, emit: printer).run(task: task).solved
}
exit(solved ? 0 : 1)
