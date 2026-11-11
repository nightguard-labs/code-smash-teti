import Foundation
import CryptoKit
import BrainCore
import BrainMind

// brain-sleep: Code Smash TeTi's sleep. A real maintenance cycle (owner 11/05), run when the Mac is NOT in use:
//   1. consolidate memory   merge duplicates, natural forgetting, retire dead knowledge, turn repeated lessons into rules
//   2. tidy working memory  trim old project journals, archive abandoned ones
//   3. repair               verify the knowledge bank (sha256), the hot file, binaries, disk space; rotate logs
//   4. dream                replay unsolved tasks in a sandbox copy; a solve counts (reward + learning)
//   5. train                LoRA on rewarded wins; adopt only if held-out loss improves
//   5b. prune               nightly expert-usage profiling → plan → pruned brain → held-out exam → adopt if it passes
//   6. morning report       memory/sleep/<date>.md + a notification
//
//   brain-sleep auto     (launchd, every 30 min) sleeps only if idle ≥ 45 min, on AC, nothing running, ≥ 12 h since last sleep
//   brain-sleep now [--min-examples N] [--iterations N] [--train-model DIR] [--no-dream] [--no-train]

setvbuf(stdout, nil, _IOLBF, 0)
let argv = CommandLine.arguments
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
let fm = FileManager.default
let sleepDir = BrainPaths.memory.appendingPathComponent("sleep")
try? fm.createDirectory(at: sleepDir, withIntermediateDirectories: true)

func sh(_ exe: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

var report: [String] = []
func say(_ s: String) { print(s); report.append(s) }

// MARK: gate (only sleep when not in use)

func idleSeconds() -> Double {
    let out = sh("/usr/sbin/ioreg", ["-c", "IOHIDSystem", "-d", "4"])
    guard let r = out.range(of: "\"HIDIdleTime\" = ") else { return 0 }
    let num = out[r.upperBound...].prefix { $0.isNumber }
    return (Double(num) ?? 0) / 1e9
}
let lastFile = sleepDir.appendingPathComponent("last.json")
func lastSleep() -> Date {
    guard let d = fm.contents(atPath: lastFile.path), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Double],
          let t = o["time"] else { return .distantPast }
    return Date(timeIntervalSince1970: t)
}

if argv.dropFirst().first == "auto" {
    let idle = idleSeconds()
    let onAC = sh("/usr/bin/pmset", ["-g", "batt"]).contains("AC Power")
    let busy = !sh("/usr/bin/pgrep", ["-f", "release/(teti|front-desk|lay|prune|expert-test|brain-sleep now)"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let rested = Date().timeIntervalSince(lastSleep()) < 12 * 3600
    if idle < 45 * 60 || !onAC || busy || rested { exit(0) }   // awake, on battery, working, or already slept
} else if argv.dropFirst().first != "now" {
    print("usage: brain-sleep auto | brain-sleep now [--min-examples N] [--iterations N] [--train-model DIR] [--no-dream] [--no-train] [--no-prune] [--profile-tokens N]"); exit(2)
}

let t0 = Date()
let day = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: Date()) }()
say("# 🌙 Code Smash TeTi sleep report — \(day)\n")
let ni = KnowledgeBank(), si = WorkingMemory()

/// The model used to think during sleep: the real brain if loaded, else the shared local model.
func sleepModel() async -> ModelClient? {
    func up(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url), let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    let b = await BrainLink.best()
    if b.isBrain { return b.client }
    if await up("http://127.0.0.1:11435/api/tags") != nil { return LocalChatClient() }
    return nil
}
let model = await sleepModel()

// MARK: 1. consolidate memory

say("## 1. Memory consolidation")
let before = await ni.all()
let faded = await ni.decay()
// The bacteria (user 11/10): copies AND near-copies of one lesson merge into one. Numbers don't make a lesson new
// ("about 28 minutes left" = "about 27 minutes left"); 80%+ of the same words = the same lesson; hard "never" rules
// merge only when they're exact copies. The strongest copy survives and keeps everyone's evidence and tags.
func lessonKey(_ t: String) -> String {
    t.lowercased().replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        .replacingOccurrences(of: "[^a-z# ]", with: " ", options: .regularExpression)
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
}
func lessonWords(_ t: String) -> Set<String> { Set(lessonKey(t).split(separator: " ").map(String.init).filter { $0.count > 2 }) }
var groups: [Insight] = []
for it in (await ni.all()).sorted(by: { $0.strength > $1.strength }) {
    let k = lessonKey(it.text), w = lessonWords(it.text)
    if let i = groups.firstIndex(where: { g in
        guard g.kind == it.kind else { return false }
        if lessonKey(g.text) == k { return true }
        if it.isNever { return false }
        let gw = lessonWords(g.text)
        return Double(gw.intersection(w).count) / Double(max(1, gw.union(w).count)) >= 0.8
    }) {
        groups[i].strength += max(0, it.strength) * 0.5; groups[i].successes += it.successes; groups[i].failures += it.failures
        groups[i].lastUsed = max(groups[i].lastUsed, it.lastUsed); groups[i].tags = Array(Set(groups[i].tags + it.tags)).sorted()
    } else { groups.append(it) }
}
let merged = groups
await ni.replaceAll(merged)
let retired = await ni.prune()
say("- \(before.count) memories → merged \(before.count - merged.count) duplicates, \(faded) faded from disuse, \(retired.count) retired")

// repeated lessons with shared tags become one general rule (like sleep turning experiences into understanding)
if let model {
    let items = await ni.all()
    var byTag: [String: [Insight]] = [:]
    for it in items where !it.tags.contains("rule") {
        for t in it.tags where t.count > 4 && !["failure", "breakthrough", "stuck"].contains(t) { byTag[t, default: []].append(it) }
    }
    var made = 0
    for (tag, group) in byTag.sorted(by: { $0.value.count > $1.value.count }) where group.count >= 3 && made < 3 {
        let kind = group.filter { $0.isAvoid }.count > group.count / 2 ? "avoid" : "do"
        let prompt = "These are verified lessons about '\(tag)':\n" + group.prefix(8).map { "- \($0.text)" }.joined(separator: "\n") +
            "\n\nWrite ONE short general rule that captures what they have in common. One line, no preamble."
        if let rule = try? await model.complete([BrainMessage(role: .user, content: prompt)], maxTokens: 120, think: false),
           !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let r = (rule.components(separatedBy: "</think>").last ?? rule).trimmingCharacters(in: .whitespacesAndNewlines)
            await ni.learn("RULE (\(tag)): \(r.prefix(240))", tags: ["rule", tag], verifiedBy: "consolidated from \(group.count) verified lessons", kind: kind)
            say("- new rule from \(group.count) lessons on '\(tag)': \(r.prefix(160))"); made += 1
        }
    }
    if made == 0 { say("- no groups of 3+ related lessons yet, so no new rules") }
}

// MARK: 2. working memory

say("\n## 2. Working memory")
var trimmed = 0, archived = 0
for p in await si.allProjects() {
    let j = await si.journal(p)
    if Date().timeIntervalSince(j.updated) > 60 * 86400 { await si.archive(p); archived += 1; continue }
    if j.done.count > 30 || j.decisions.count > 20 {
        try? await si.update(p) { $0.done = Array($0.done.suffix(30)); $0.decisions = Array($0.decisions.suffix(20)) }
        trimmed += 1
    }
}
say("- \(trimmed) journal(s) trimmed, \(archived) abandoned project(s) archived")

// MARK: 3. repair

say("\n## 3. Repair")
var problems = 0
// the brain family the owner is using: the original behind the active brain (Code Smash TeTi or Qwen3-Next);
// its slim versions share its evidence, adapters and shrink ladder
let brainDir: URL = {
    let active = URL(fileURLWithPath: activeBrain()).lastPathComponent
    let root = active.replacingOccurrences(of: #"-(c\d+-b\d|pruned)$"#, with: "", options: .regularExpression)
    let d = BrainPaths.models.appendingPathComponent(root)
    return fm.fileExists(atPath: d.appendingPathComponent("bank-meta.json").path) ? d : BrainPaths.models.appendingPathComponent("code-smash-teti")
}()
if fm.fileExists(atPath: brainDir.appendingPathComponent("bank-meta.json").path),
   let md = fm.contents(atPath: brainDir.appendingPathComponent("bank-meta.json").path),
   let meta = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
   let entries = meta["entries"] as? [[String: Any]], let blockLen = meta["blockLength"] as? Int,
   let parts = meta["parts"] as? [[String: Any]], let last = parts.last,
   let lo = last["offset"] as? Int, let ll = last["length"] as? Int {
    let raw = lo + ll
    let fd = open(brainDir.appendingPathComponent("bank.bin").path, O_RDONLY); _ = fcntl(fd, F_NOCACHE, 1)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: blockLen, alignment: 16384)
    var bad = 0
    let sample = entries.shuffled().prefix(64)
    for e in sample {
        let b = e["block"] as? Int ?? 0
        _ = pread(fd, buf, blockLen, off_t(b * blockLen))
        let sum = SHA256.hash(data: UnsafeRawBufferPointer(start: buf, count: raw)).map { String(format: "%02x", $0) }.joined()
        if sum != e["sha256"] as? String { bad += 1 }
    }
    close(fd); buf.deallocate()
    problems += bad
    say("- knowledge bank: \(sample.count) random experts checked by sha256 → \(bad == 0 ? "all healthy ✓" : "\(bad) DAMAGED ✗ (re-run lay for those layers)")")
} else { say("- knowledge bank: not laid yet (download still running), skipped") }
for b in ["brain-server", "brain-relay", "lay", "teti", "front-desk", "brain-sleep"] {
    let p = BrainPaths.root.appendingPathComponent("brain/.build/release/\(b)").path
    if !fm.isExecutableFile(atPath: p) { problems += 1; say("- missing program: \(b) ✗ (rebuild with swift build -c release)") }
}
let free = sh("/bin/df", ["-g", "/System/Volumes/Data"]).split(separator: "\n").last?.split(separator: " ").compactMap { Int($0) }
if let f = free, f.count >= 3 { say("- disk: \(f[2]) GB free" + (f[2] < 40 ? " ⚠ getting low" : " ✓")); if f[2] < 40 { problems += 1 } }
var rotated = 0
for f in (try? fm.contentsOfDirectory(atPath: BrainPaths.logs.path)) ?? [] where f.hasSuffix(".log") {
    let p = BrainPaths.logs.appendingPathComponent(f).path
    if let s = (try? fm.attributesOfItem(atPath: p))?[.size] as? Int, s > 20 << 20 {
        try? fm.removeItem(atPath: p + ".old"); try? fm.moveItem(atPath: p, toPath: p + ".old"); rotated += 1
    }
}
say("- logs rotated: \(rotated) · problems found: \(problems)")

// MARK: 4. dream (replay unsolved work)

say("\n## 4. Dreaming (replaying unsolved tasks)")
if argv.contains("--no-dream") { say("- skipped (--no-dream)") }
else if let model {
    var hard: [(String, String)] = []
    for base in ["projects", "runs"] {
        let root = BrainPaths.root.appendingPathComponent(base).path
        for d in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let help = "\(root)/\(d)/.teti/help-request.md"
            if let t = try? String(contentsOfFile: help, encoding: .utf8),
               let task = t.components(separatedBy: "**Task:** ").dropFirst().first?.components(separatedBy: "\n\n").first {
                hard.append(("\(root)/\(d)", task))
            }
        }
    }
    if hard.isEmpty { say("- nothing unsolved to replay") }
    for (src, task) in hard.prefix(2) {
        let name = URL(fileURLWithPath: src).lastPathComponent
        let dream = BrainPaths.memory.appendingPathComponent("dreams/\(name)").path
        try? fm.removeItem(atPath: dream)
        try? fm.createDirectory(atPath: dream, withIntermediateDirectories: true)
        let loop = ThinkingLoop(model: model, dir: dream, project: "dream-\(name)", si: si, ni: ni, maxLoops: 3) { _ in }
        let r = await loop.run(task: task)
        say("- \(name): \(r.solved ? "✅ solved in the dream (\(r.loops) loop(s)) — solution in \(dream)" : "still unsolved (\(r.checksPassed)/\(r.checksTotal))")")
    }
} else { say("- no model available, skipped") }

// MARK: brain server: asleep while the heavy work runs
// The live brain server holds ~15–20 GB. Training, profiling and the prune exam each load the full brain too, and
// two copies don't fit in 32 GB. So the server is stopped before heavy work and started again afterwards (only when
// no task is running; the busy gate above already guarantees that).
var pausedBrain = false
func brainServerPID() -> Int32? {
    // the big brain only: a fast-lane server (started with --port) stays up
    return sh("/bin/ps", ["-axo", "pid=,command="]).split(separator: "\n").first {
        $0.contains("release/brain-server --model") && !$0.contains("caffeinate") && !$0.contains("--port")
    }.flatMap { Int32($0.split(separator: " ").first ?? "") }
}
func pauseBrain() {
    guard !pausedBrain, let pid = brainServerPID() else { return }
    kill(pid, SIGTERM)
    for _ in 0..<30 where brainServerPID() != nil { Thread.sleep(forTimeInterval: 1) }
    pausedBrain = true
    say("- brain server put to sleep for the heavy work (it comes back afterwards)")
}
/// The brain the server should run: models/code-smash-teti-active if it points somewhere real, else the original.
func activeBrain() -> String {
    let link = BrainPaths.models.appendingPathComponent("code-smash-teti-active").path
    if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link) {
        let full = dest.hasPrefix("/") ? dest : BrainPaths.models.appendingPathComponent(dest).path
        if FileManager.default.fileExists(atPath: full + "/bank-meta.json") { return full }
    }
    return BrainPaths.models.appendingPathComponent("code-smash-teti").path
}
func resumeBrain() {
    guard pausedBrain else { return }
    // its own session, so it keeps running after this sleep job exits
    let py = """
    import subprocess
    subprocess.Popen(['caffeinate','-i','.build/release/brain-server','--model','\(activeBrain())','--name','code-smash-teti'],
        cwd='\(BrainPaths.root.appendingPathComponent("brain").path)',
        stdout=open('\(BrainPaths.root.appendingPathComponent("logs/brain-server.log").path)','w'), stderr=subprocess.STDOUT, start_new_session=True)
    """
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-c", py]
    try? p.run(); p.waitUntilExit()
    say("- brain server woken up again (\(URL(fileURLWithPath: activeBrain()).lastPathComponent))")
}

// MARK: 5. train

say("\n## 5. Overnight training")
let examples = Trainer.buildDataset()
let minEx = Int(opt("--min-examples") ?? "8") ?? 8
let trainModel = opt("--train-model").map { URL(fileURLWithPath: $0) }
    ?? (fm.fileExists(atPath: brainDir.appendingPathComponent("bank-meta.json").path) && fm.fileExists(atPath: brainDir.appendingPathComponent("hot.safetensors").path) ? brainDir : nil)
let sharedLoaded = sh("/usr/bin/curl", ["-s", "--max-time", "5", "http://127.0.0.1:11435/api/ps"]).contains("\"name\"")
if argv.contains("--no-train") { say("- skipped (--no-train)") }
else if examples.count < minEx { say("- \(examples.count) rewarded examples so far; training starts at \(minEx)") }
else if let tm = trainModel, tm == brainDir && sharedLoaded {
    say("- skipped: the shared model is loaded by another app, and the full brain can't train next to it")
} else if let tm = trainModel {
    pauseBrain()
    do {
        let o = try await Trainer.train(modelDir: tm, examples: examples, iterations: Int(opt("--iterations") ?? "60") ?? 60) { print($0) }
        say("- \(tm.lastPathComponent): \(o.summary)")
    } catch { say("- training failed: \(error)"); problems += 1 }
} else {
    say("- \(examples.count) examples ready; the full brain isn't laid yet")
}

// MARK: 5b. pruning (owner 11/05: "have sleep run the pruning overnight")
// Night by night: count expert usage on the owner's code → plan → build the pruned brain → held-out exam.
// The pruned brain becomes active (models/code-smash-teti-active) ONLY if it passes the exam.

say("\n## 6. Pruning")
/// Run a brain tool as its own process (its memory is fully returned when it exits), echoing its output.
func runTool(_ args: [String]) -> (ok: Bool, out: String) {
    let p = Process()
    p.executableURL = BrainPaths.root.appendingPathComponent("brain/.build/release/prune")
    p.arguments = args
    if ["profile", "exam", "apply", "slim", "ladder"].contains(args.first ?? "") { pauseBrain() }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    var out = ""
    pipe.fileHandleForReading.readabilityHandler = { h in
        let s = String(decoding: h.availableData, as: UTF8.self); if !s.isEmpty { print(s, terminator: ""); out += s }
    }
    do { try p.run() } catch { return (false, "could not start prune: \(error)") }
    p.waitUntilExit(); pipe.fileHandleForReading.readabilityHandler = nil
    out += String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (p.terminationStatus == 0, out)
}
func lastLine(_ s: String, containing k: String) -> String {
    s.split(separator: "\n").last { $0.contains(k) }.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
}
let prunedDir = BrainPaths.models.appendingPathComponent("code-smash-teti-pruned")
let activeLink = BrainPaths.models.appendingPathComponent("code-smash-teti-active")
let cycleFile = BrainPaths.memory.appendingPathComponent(brainDir.lastPathComponent == "code-smash-teti" ? "prune/last-cycle.json" : "prune/last-cycle-\(brainDir.lastPathComponent).json")
let laid = fm.fileExists(atPath: brainDir.appendingPathComponent("bank-meta.json").path) && fm.fileExists(atPath: brainDir.appendingPathComponent("hot.safetensors").path)
let sharedInUse = sh("/usr/bin/curl", ["-s", "--max-time", "5", "http://127.0.0.1:11435/api/ps"]).contains("\"name\"")
if argv.contains("--no-prune") { say("- skipped (--no-prune)") }
else if !laid { say("- the full brain isn't laid yet, skipped") }
else if sharedInUse { say("- skipped: the shared model is loaded by another app, and both won't fit in RAM together") }
else {
    // 1) profile a slice of the owner's code (resumes where last night stopped)
    let progFile = BrainPaths.memory.appendingPathComponent("prune/profile-progress-\(brainDir.lastPathComponent).json")
    var prog = (try? JSONSerialization.jsonObject(with: Data(contentsOf: progFile)) as? [String: Int]) ?? [:]
    if prog["complete"] != 1 {   // a slice every night until all of the owner's code has been read once
        let r = runTool(["profile", "--brain", brainDir.path, "--tokens", opt("--profile-tokens") ?? "100000"])
        say("- profiling: " + (r.ok ? lastLine(r.out, containing: "usage counted") : "failed: \(lastLine(r.out, containing: "")))"))
        if !r.ok { problems += 1 }
        prog = (try? JSONSerialization.jsonObject(with: Data(contentsOf: progFile)) as? [String: Int]) ?? [:]
    }
    let tokens = prog["tokens"] ?? 0
    let last = (try? JSONSerialization.jsonObject(with: Data(contentsOf: cycleFile)) as? [String: Any]) ?? [:]
    let lastTokens = last["tokens"] as? Int ?? 0
    if tokens < 20_000 { say("- \(tokens) tokens of evidence so far; pruning starts at 20,000") }
    else if lastTokens > 0 && Double(tokens) < Double(lastTokens) * 1.5 { say("- pruned brain is up to date (evidence \(tokens) tokens; re-prunes when it grows 50%)") }
    else {
        // 2) the shrink ladder: safest cut first, exam on unseen code, keep the best that passes; it becomes active
        //    only if it also codes at least as well as the original (hidden-test coding check)
        let r = runTool(["ladder", "--brain", brainDir.path, "--adopt"])
        say("- shrink ladder: " + lastLine(r.out, containing: "## Result:").replacingOccurrences(of: "## ", with: ""))
        let adopt = lastLine(r.out, containing: "adopted")
        if !adopt.isEmpty { say("- " + adopt.trimmingCharacters(in: CharacterSet(charactersIn: "- "))) }
        if !r.ok { problems += 1 }
    }
}

resumeBrain()

// MARK: 6. morning report

let mins = Int(Date().timeIntervalSince(t0) / 60)
say("\n_Slept \(mins) min. Problems needing the owner: \(problems)._")
let fname = day.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "") + ".md"
try? report.joined(separator: "\n").write(to: sleepDir.appendingPathComponent(fname), atomically: true, encoding: .utf8)
try? JSONSerialization.data(withJSONObject: ["time": Date().timeIntervalSince1970]).write(to: lastFile)
_ = sh("/usr/bin/osascript", ["-e", "display notification \"Slept \(mins) min · \(problems) problem(s). Report in brain-lab/memory/sleep.\" with title \"🌙 Code Smash TeTi woke up\""])
print("\nreport: \(sleepDir.appendingPathComponent(fname).path)")
