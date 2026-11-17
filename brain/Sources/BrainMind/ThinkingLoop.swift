import Foundation
import BrainCore

// The thinking loop, modeled on the owner's own mind (11/05):
//
//   Te (frame)  → defines what "done" means as runnable checks — objective, external, evidence
//   Ti (build)  → builds it with precise internal logic
//   Te (check)  → runs the checks for real; judges only by evidence; ONLY Te can declare done
//   Ti (improve)→ fixes what Te found … and around again
//
//   Ni  recall at the start (verified knowledge, strongest first); learns the winning approach at the end
//   Si  project journal updated every loop (survives context limits and restarts)
//   Ne  "what if": when the loop is stuck, branch into different approaches in sandbox copies; Te picks the winner
//   Help: if it still can't pass, it writes a help request instead of spinning or pretending

public enum LoopEvent: Sendable {
    case phase(String, loop: Int)
    case note(String)
    case check(name: String, passed: Bool, detail: String)
    case verdict(passed: Int, total: Int, feedback: String)
    case branch(String)
    case finished(LoopResult)
}

public struct LoopResult: Codable, Sendable {
    public var solved: Bool
    public var loops: Int
    public var checksPassed: Int
    public var checksTotal: Int
    public var approach: String
    public var files: [String]
    public var helpRequest: String?
    public var seconds: Double
    /// What a smaller brain passes up the stack when it hits its limit (owner 11/10: "pass it onto the larger one, but just
    /// the parts it could not do"): the same checks, which ones already pass, and its last findings.
    public var handoff: Handoff? = nil
}

public struct HandoffCheck: Codable, Sendable { public var name: String; public var command: String; public var expect: String?; public var passed: Bool }
public struct Handoff: Codable, Sendable {
    public var checks: [HandoffCheck]
    public var findings: String
    public var passing: [String] { checks.filter { $0.passed }.map { $0.name } }
    public var failing: [String] { checks.filter { !$0.passed }.map { $0.name } }
}

struct Check: Codable { var name: String; var command: String; var expect: String? }

public actor ThinkingLoop {
    let model: ModelClient
    let dir: String
    let project: String
    let si: WorkingMemory
    let ni: KnowledgeBank
    let maxLoops: Int
    let track = TrackKeeper()
    var lastTiFinal = ""
    var keyCode: String? = nil          // Fi's trusted answer key, kept to judge checks added LATER (gate5v3 task 3, 11/16)
    /// Ti's voice (exam task 12, 11/10): checks Ti flagged as contradicting the task, name → why. Fi judges them.
    var tiFlags: [String: String] = [:]
    var fiJudged: Set<String> = []
    // 11/10 task 12 rerun: Ti said "this is contradictory... but I can't change the test" and never used <wrong_check>,
    // so Fi never ran. Code-level triggers instead: Ti's own doubt words, or a check stuck failing 3 rounds.
    var tiDoubt = ""
    var failStreak: [String: Int] = [:]
    var versionTags: [String] = []          // every distinct version of the code, oldest first (.teti/versions/<tag>)
    var versionPrints: Set<Int> = []
    static let doubtPattern = #"(?i)(contradict|test (is|must be|might be|could be) wrong|check (is|must be|might be) wrong|can'?t change the test|cannot change the test|unless the test|suspicious|the test expects .{1,80} but|impossible to satisfy)"#
    var neTried: [String] = []
    var taskStart = Date()               // Se's clock, readable inside Ti's build too
    /// Se → Ti inside a build (task 9: one Ti build ran 83 min): each build gets at most this many minutes.
    nonisolated static var buildCapMinutes: Double { Double(ProcessInfo.processInfo.environment["TETI_BUILD_CAP_MIN"] ?? "") ?? 30 }          // Si → Ne: every idea Ne already tried on this task (user, 11/10: no repeats)
    /// Errors Ti caused during this task (compiler/runtime "error:" lines), so a fix can become a NEVER rule.
    var mistakes: [String] = []
    static let languages = ["swift", "python", "javascript", "typescript", "bash", "shell", "rust", "go", "c", "cpp", "java", "ruby"]
    static func languagesIn(_ text: String) -> [String] {
        let low = text.lowercased()
        var l = Set(low.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { languages.contains($0) })
        for (ext, lang) in [(".swift", "swift"), (".py", "python"), (".js", "javascript"), (".ts", "typescript"), (".sh", "bash"), (".rs", "rust")] where low.contains(ext) { l.insert(lang) }
        return l.sorted()
    }
    let emit: @Sendable (LoopEvent) -> Void
    var files = Set<String>()
    var log: FileHandle?

    public init(model: ModelClient, dir: String, project: String? = nil, si: WorkingMemory, ni: KnowledgeBank,
                maxLoops: Int = 6, emit: @escaping @Sendable (LoopEvent) -> Void) {
        self.model = model; self.dir = URL(fileURLWithPath: dir).standardizedFileURL.path
        self.project = project ?? URL(fileURLWithPath: dir).lastPathComponent
        self.si = si; self.ni = ni; self.maxLoops = maxLoops; self.emit = emit
    }

    // MARK: prompts

    static let tePersona = """
    You are Te, the extraverted-thinking side of Code Smash TeTi. You care about objective, external results: does it
    actually work, measured by evidence. You never accept claims, only command output. Be brief and concrete.
    """
    static let tiPersona = """
    You are Ti, the introverted-thinking side of Code Smash TeTi. You build: precise, logically consistent, clean code
    for macOS (Apple M1 Pro, zsh, BSD tools; not Linux). You work in the current folder with relative paths.
    """

    static let stakes = """
    FAILURE IS BAD, just like in real life: a failed build wastes the owner's time and money and breaks trust, and every
    failed loop goes on your permanent record. Get it right. The WORST failure is claiming something works when it doesn't;
    that is a lie, and it is recorded. If you can't do it, say so honestly; that is not a failure of character, faking is.
    """
    static let tiTools = """
    HOW YOU WORK:
    - Write a file with:  <write_file path="relative/name.ext">
    whole file contents, exactly as written
    </write_file>
    - Run a command (to inspect or test) with: <run>command</run>   You will get the output back.
    - If a check CONTRADICTS the task (its expected answer is wrong when you work it out from the task text), don't bend
      working code to fit it. Say so with: <wrong_check name="check-name">what the task says vs what the check expects</wrong_check>
      Fi will judge it fairly against the task. Only flag a check you have worked out by hand; flagging a fair check is recorded.
    - No internet. Don't install packages. Use what's on a standard Mac (python3, swiftc, zsh, BSD tools).
    - Before finishing, delete any data/test files your own testing created, so Te checks a clean project.
    - When your build is complete, reply WITHOUT any <run>, and end with one line: <approach>how you solved it</approach>
    - BE BRIEF: every word you write costs the owner time. No plans, no restating the task, no explanations of the code.
      Go straight to <write_file> / <run>. When fixing an error, at most ONE short sentence on what was wrong.
    """

    // MARK: run

    var lastOk: [String: Bool] = [:], liveChecks: [Check] = [], lastFeedbackText = ""

    public func run(task: String, handoff: Handoff? = nil) async -> LoopResult {
        let t0 = Date()
        taskStart = t0
        try? FileManager.default.createDirectory(atPath: dir + "/.teti", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/.teti/transcript.jsonl", contents: nil)
        log = FileHandle(forWritingAtPath: dir + "/.teti/transcript.jsonl")
        defer { try? log?.close() }

        // Ni: what do we already know that's proven?
        let recalled = await ni.recall(task)
        if !recalled.isEmpty { emit(.note("Ni recalled \(recalled.count) proven insight(s)")) }
        let langs = Self.languagesIn(task)
        let nevers = await ni.neverRules(for: langs)
        if !nevers.isEmpty { emit(.note("Ni has \(nevers.count) hard rule(s) for \(langs.joined(separator: "/"))")) }
        let dos = recalled.filter { !$0.isAvoid && !$0.isNever }, avoids = recalled.filter { $0.isAvoid }
        if !avoids.isEmpty { emit(.note("Ni warns about \(avoids.count) past failure(s)")) }
        await track.update { $0.tasks += 1 }
        let knowledge = (nevers.isEmpty ? "" : "HARD RULES — each one cost you a failed build before. Obey them in your FIRST draft:\n" +
                         nevers.map { "- \($0.text)" }.joined(separator: "\n") + "\n\n") + Self.stakes + "\n" + (await track.record.line) + "\n\n" +
            (dos.isEmpty ? "" : "PROVEN TO WORK (verified earlier):\n" + dos.map { "- \($0.text)" }.joined(separator: "\n") + "\n") +
            (avoids.isEmpty ? "" : "PROVEN TO FAIL — DO NOT REPEAT (this hurt before):\n" + avoids.map { "- \($0.text)" }.joined(separator: "\n"))

        // Te frames the goal as checks
        var checks: [Check]
        var locked: Set<String> = []
        if let h = handoff, !h.checks.isEmpty {
            // Handoff: a smaller brain already built most of it. Same checks, the passing ones are locked, fix only the rest.
            checks = h.checks.map { Check(name: $0.name, command: $0.command, expect: $0.expect) }
            locked = Set(h.passing)
            emit(.note("⬆️ handoff: \(h.passing.count) of \(h.checks.count) checks already pass (locked), working only on: \(h.failing.joined(separator: ", "))"))
        } else {
            // FUNCTION STACKS (user idea 11/16, like MBTI orders): code picks the role order per task. TETI_STACK=fixed keeps
            // the old order (Te first) so both can be raced on the same tasks.
            let stack = pickStack(task)
            var teKnowledge = knowledge
            emit(.note("Stack: \(stack)"))
            if stack == "ne-first" { teKnowledge += await neFirst(task: task) }
            // TOOL OFFLOADING for tests (user 11/16, after 4 rounds where the CODE was right and Te's tests were wrong): Te only
            // picks the cases (judgment); code writes every test in one safe format; two independent answer keys work out the
            // exact expected output (exact work). TETI_TE=classic keeps the old path for racing.
            var viaCases: [Check] = []
            if ProcessInfo.processInfo.environment["TETI_TE"] != "classic" { viaCases = await teCasesChecks(task: task, knowledge: teKnowledge) }
            if viaCases.count >= 3 {
                checks = viaCases
            } else {
                emit(.phase("Te: defining what done means", loop: 0))
                checks = await teFrame(task: task, knowledge: teKnowledge)
                checks = dropBrokenInputs(checks)
                checks = await formatGate(task: task, knowledge: knowledge, checks: checks)
                checks = await answerKey(task: task, checks: checks)
            }
        }
        guard !checks.isEmpty else {
            return finish(t0, solved: false, loops: 0, passed: 0, total: 0, approach: "",
                          help: helpRequest(task: task, why: "Te could not turn the task into runnable checks.", checks: [], feedback: ""))
        }
        for c in checks { emit(.note("Te check '\(c.name)': \(c.command)" + (c.expect.map { "  (expect: \(Self.exactSpec($0)?.text ?? $0))" } ?? ""))) }
        try? await si.update(project) { j in
            j.goal = task; j.plan = checks.map { "check \($0.name): \($0.command)" }; j.openProblems = []
        }

        var feedback = handoff.map { h in
            "HANDOFF: a smaller brain built this and got stuck. The code in the folder is its work, keep it.\n" +
            "These checks ALREADY PASS, so don't break them: \(h.passing.joined(separator: ", "))\n" +
            "Fix ONLY these failing parts: \(h.failing.joined(separator: ", "))\n" +
            "Its last findings:\n\(String(h.findings.suffix(2500)))"
        } ?? ""
        var approach = "", lastFails: Set<String> = [], stuck = 0, lastPassed = -1, lastImproveLoop = 0
        var pendingSwitch: (kind: String, choice: String, passed: Int)? = nil
        var versions: [Int: (loop: Int, passed: Int)] = [:]     // Se's memory of every version of the code
        var neBreakDone = false
        neTried = []
        var best = (passed: 0, total: checks.count)
        var bestSaved = -1, bestOk: Set<String> = []
        tiFlags = [:]; fiJudged = []; tiDoubt = ""; failStreak = [:]
        versionTags = []; versionPrints = []
        try? FileManager.default.removeItem(atPath: dir + "/.teti/versions")

        // Fast path (user 11/11, after the baseline: plain 35B one try = 8/12 in ~4 min, the loop 11/12 in ~90 min).
        // Ask once, plainly, like the baseline. If Te's checks pass and Ne can't break it, done in seconds. Otherwise the
        // full loop starts from that draft. Skipped on a handoff (the bigger brain continues the smaller one's work).
        if handoff == nil, ProcessInfo.processInfo.environment["TETI_NO_FAST_PATH"] == nil {
            emit(.phase("Fast path: one plain try", loop: 0))
            let fm = FileManager.default
            let existing = ((fm.enumerator(atPath: dir)?.allObjects as? [String]) ?? []).filter { f in
                !f.hasPrefix(".") && !f.contains("/.") && ((try? fm.attributesOfItem(atPath: dir + "/" + f))?[.type] as? FileAttributeType) == .typeRegular &&
                (((try? fm.attributesOfItem(atPath: dir + "/" + f))?[.size] as? Int) ?? 99999) < 20000 }.sorted()
            let shown = existing.compactMap { f in (try? String(contentsOfFile: dir + "/" + f, encoding: .utf8)).map { "\n\nEXISTING FILE \(f):\n```\n\($0)\n```" } }.joined()
            // BEST OF 3 (user 11/16, "many tries, pick the best"): up to 3 plain drafts, each in its own copy, scored by the
            // checks the answer key already vetted; stop early on a perfect one. Out of the box the model was a coin flip on
            // tasks 2/4/8/12 (1 in 3), so 3 tries in ~3 min beat one try + a long loop. TETI_DRAFTS=1 = the old single try.
            let nDrafts = max(1, Int(ProcessInfo.processInfo.environment["TETI_DRAFTS"] ?? "") ?? 3)
            // outside .teti: Sandbox.inside refuses any path under /.teti/ (first try of this, 11/16, saved nothing)
            let draftRoot = NSTemporaryDirectory() + "teti-drafts-" + UUID().uuidString
            try? fm.removeItem(atPath: draftRoot)
            var top: (path: String, p: Int, wrote: [String], k: Int)? = nil
            for k in 1...nDrafts {
                let reply = await ask([.init(role: .system, content: "You are a helpful coding assistant."),
                                       .init(role: .user, content: task + shown + "\n\nReply with every file you create or change, each one complete, as:\n<write_file path=\"relative/path\">full file content</write_file>")],
                                      phase: "fast-path-\(k)", maxTokens: 8192)
                let d = draftRoot + "/d\(k)"
                copyProject(from: dir, to: d)
                var w: [String] = []
                var pw = parseWrites(reply)
                // Same rule as the out-of-box test (baseline.py): a plain ``` block counts when the task names exactly one
                // file (speed2, 11/16: 3 good drafts with the TOTAL line were thrown away for missing the file tag).
                if pw.isEmpty, let only = Self.singleFileName(task), let code = Self.firstCodeBlock(reply) { pw = [(only, code)] }
                for (path, body) in pw {
                    guard let p = Sandbox.inside(d, path) else { continue }
                    try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    if (try? body.write(toFile: p, atomically: true, encoding: .utf8)) != nil { w.append(path) }
                }
                guard !w.isEmpty else { emit(.note("Draft \(k): wrote no files")); continue }
                let pk = runChecks(checks, in: d, emitting: false).filter { $0.ok }.count
                emit(.note(String(format: "Draft %d of %d: %d/%d checks pass (%.0f s in)", k, nDrafts, pk, checks.count, Date().timeIntervalSince(t0))))
                if top == nil || pk > top!.p { top = (d, pk, w, k) }
                if pk == checks.count { break }
            }
            var wrote: [String] = []
            if let t = top {
                replaceProject(dir, with: t.path); wrote = t.wrote
                if nDrafts > 1 { emit(.note("Fast path: keeping draft \(t.k) (\(t.p)/\(checks.count))")) }
            }
            try? fm.removeItem(atPath: draftRoot)
            if !wrote.isEmpty {
                saveVersion("fast-path")
                var r0 = runChecks(checks, in: dir, emitting: true)
                var p0 = r0.filter { $0.ok }.count
                emit(.note(String(format: "Fast path: wrote %@, %d/%d checks pass after %.0f s", wrote.joined(separator: ", "), p0, checks.count, Date().timeIntervalSince(t0))))
                // Fix E (exam task 3, 11/11, three runs in a row): the plain draft was CORRECT every time and Te's checks were wrong
                // (4.0 vs "integer if whole", && test $? traps, invalid JSON fed as if valid). Ti then bent good code to fit bad
                // checks, once into a false win. So when the draft and a check disagree, Fi rules on the check BEFORE Ti touches code.
                var fiUpheld = ""
                if p0 < checks.count {
                    let disputed = r0.filter { !$0.ok }
                    for r in disputed { tiFlags[r.check.name] = "(fast path) a plain first draft written straight from the task fails this check. Before anyone changes that draft: does the CHECK match the TASK text (the expected output and its format, and input the task calls valid)? If the check is right, say so." }
                    let (rulings, upheld) = await fiJudge(task: task, flagged: disputed)
                    fiUpheld = upheld
                    for f in rulings { if let i = checks.firstIndex(where: { $0.name == f.name }) { checks[i] = f; emit(.note("Fi: the draft was right, check '\(f.name)' contradicted the task, corrected")) } }
                    if !rulings.isEmpty {
                        r0 = runChecks(checks, in: dir, emitting: true)
                        p0 = r0.filter { $0.ok }.count
                        emit(.note("Fast path: after Fi's rulings the draft passes \(p0)/\(checks.count)"))
                    }
                }
                best = (p0, checks.count)
                // lang-swift task 12 (11/16): the kept draft scored 9/10, the first fix round dropped it to 6/10, and rollback
                // didn't help because only loop rounds counted as "best". The kept draft is the first best version now.
                bestSaved = p0; bestOk = Set(r0.filter { $0.ok }.map { $0.check.name })
                try? FileManager.default.removeItem(atPath: dir + "/.teti/best")
                copyProject(from: dir, to: dir + "/.teti/best")
                if p0 == checks.count {
                    neBreakDone = true
                    if let fb = await neGate(task: task, checks: &checks) {
                        feedback = "FAST PATH: a first draft is in the folder and passed every original check, but:\n" + fb
                    } else {
                        emit(.verdict(passed: checks.count, total: checks.count, feedback: "the fast path passed every check and Ne couldn't break it"))
                        await learn(task: task, approach: "fast path: one plain try", checks: checks, recalled: recalled)
                        await reward(10, "solved on the fast path", solved: true, firstTry: true)
                        return finish(t0, solved: true, loops: 0, passed: checks.count, total: checks.count, approach: "fast path", help: nil)
                    }
                } else {
                    let fails = r0.filter { !$0.ok }.map { "- \($0.check.name): \(String($0.output.suffix(300)))" }.joined(separator: "\n")
                    feedback = "FAST PATH: a first plain draft is in the folder and passed \(p0)/\(checks.count) checks. Fi checked the failing checks against the task and they stand. Keep what works, fix these:\n" + fails + (fiUpheld.isEmpty ? "" : "\n" + fiUpheld)
                }
            } else { emit(.note("Fast path: the model wrote no files, the full loop takes over")) }
        }

        // Rounds are a soft limit when time is the real budget (user, exam task 12, 11/11): it used all 6 rounds in 19 min
        // and quit with 41 min left. Past maxLoops, keep going while one more round fits in the budget, up to 2x.
        // Small stack layers (under 6 rounds) still hand up on time.
        let hardCap = maxLoops >= 6 ? maxLoops * 2 : maxLoops
        var ran = 0
        for loop in 1...hardCap {
            if loop > maxLoops {
                let used = Date().timeIntervalSince(t0) / 60, perRound = used / Double(loop - 1)
                if used + perRound > Self.timeBudgetMinutes { break }
                emit(.note(String(format: "Se: round %d of %d was the limit, but %.0f min are left (a round takes ~%.0f), so one more", loop - 1, maxLoops, Self.timeBudgetMinutes - used, perRound)))
            }
            ran = loop
            // Ti builds / improves
            emit(.phase(loop == 1 ? "Ti: building" : "Ti: improving", loop: loop))
            let seBefore = seSnapshot(dir)
            approach = await tiBuild(task: task, checks: checks, feedback: feedback, knowledge: knowledge, in: dir, steer: nil)
            let seAfter = seSnapshot(dir)
            let (seChange, seChanged) = seDiff(seBefore, seAfter)
            emit(.note("Se: what changed this round:\n" + seChange))
            // Se remembers every version, not just the last one: back at an old version = going in circles
            let fingerprint = seAfter.keys.sorted().map { $0 + "\u{0}" + seAfter[$0]! }.joined(separator: "\u{1}").hashValue
            var circleNote = ""
            if let old = versions[fingerprint], old.loop < loop {
                circleNote = "⚠ SE: GOING IN CIRCLES. Your code is now exactly what it was after loop \(old.loop), which scored \(old.passed)/\(checks.count). Undoing and redoing won't help: change something you haven't changed before.\n"
                emit(.note("Se: going in circles, the code is back to its loop \(old.loop) version"))
            }

            // Te checks reality
            emit(.phase("Te: checking against reality", loop: loop))
            var results = runChecks(checks, in: dir, emitting: true)
            checks = results.map { $0.check }        // keep Se's corrected directions for the next rounds
            lastOk = Dictionary(results.map { ($0.check.name, $0.ok) }, uniquingKeysWith: { a, _ in a }); liveChecks = checks
            let brokeLocked = results.filter { !$0.ok && locked.contains($0.check.name) }.map { $0.check.name }
            if !brokeLocked.isEmpty { emit(.note("Se: the bigger brain broke check(s) that already worked: \(brokeLocked.joined(separator: ", "))")) }
            var passed = results.filter { $0.ok }.count
            if versions[fingerprint] == nil { versions[fingerprint] = (loop, passed) }
            best = (passed, checks.count)
            var fails = Set(results.filter { !$0.ok }.map { $0.check.name })
            try? await si.update(project) { j in
                j.done.append("loop \(loop): \(passed)/\(checks.count) checks pass — \(approach)")
                j.done.append("loop \(loop) Se saw: " + String(seChange.prefix(400)))
                j.openProblems = results.filter { !$0.ok }.map { "\($0.check.name): \(String($0.output.suffix(200)))" }
                if !approach.isEmpty { j.decisions.append("approach: \(approach)") }
                for f in files { if j.files[f] == nil { j.files[f] = "written by Ti" } }
            }
            if fails.isEmpty && !neBreakDone {
                neBreakDone = true
                if let fb = await neGate(task: task, checks: &checks) {
                    feedback = fb
                    emit(.verdict(passed: passed, total: checks.count, feedback: feedback))
                    lastFails = []; lastPassed = passed
                    continue
                }
            }
            if fails.isEmpty {
                emit(.verdict(passed: passed, total: checks.count, feedback: "all checks pass, verified by real output"))
                await learn(task: task, approach: approach, checks: checks, recalled: recalled)
                await reward(loop == 1 ? 10 : 5, loop == 1 ? "solved on the first try" : "solved", solved: true, firstTry: loop == 1)
                return finish(t0, solved: true, loops: loop, passed: checks.count, total: checks.count, approach: approach, help: nil)
            }
            // Te audits itself first: is a failing CHECK broken (not the program)? Then repair the check, no penalty to Ti.
            let fixes = await teAuditChecks(task: task, results: results, tiSays: lastTiFinal)
            if !fixes.isEmpty {
                for f in fixes { if let i = checks.firstIndex(where: { $0.name == f.name }) { checks[i] = f; emit(.note("Te repaired its own broken check '\(f.name)'")) } }
                results = runChecks(checks, in: dir, emitting: true)
                let p2 = results.filter { $0.ok }.count
                best = (p2, checks.count)
                if p2 == checks.count && !neBreakDone {
                    neBreakDone = true
                    if let fb = await neGate(task: task, checks: &checks) {
                        feedback = fb
                        emit(.verdict(passed: p2, total: checks.count, feedback: feedback))
                        lastFails = []; lastPassed = p2
                        continue
                    }
                }
                if p2 == checks.count {
                    emit(.verdict(passed: p2, total: checks.count, feedback: "all checks pass after Te fixed its own exam"))
                    await learn(task: task, approach: approach, checks: checks, recalled: recalled)
                    await reward(loop == 1 ? 10 : 5, loop == 1 ? "solved on the first try" : "solved", solved: true, firstTry: loop == 1)
                    return finish(t0, solved: true, loops: loop, passed: p2, total: checks.count, approach: approach, help: nil)
                }
            }
            // Fi judges the checks Ti flagged as contradicting the task (each check once; never a locked handoff check)
            var fiNote = ""
            for r in results { failStreak[r.check.name] = r.ok ? 0 : (failStreak[r.check.name] ?? 0) + (seChanged ? 1 : 0) }
            for r in results where !r.ok && tiFlags[r.check.name] == nil && !fiJudged.contains(r.check.name) && !locked.contains(r.check.name) {
                if !tiDoubt.isEmpty {
                    tiFlags[r.check.name] = "(Ti doubted the checks in its own words) " + tiDoubt
                    emit(.note("Se: Ti said a check looks wrong but didn't flag it, so '\(r.check.name)' goes to Fi"))
                } else if (failStreak[r.check.name] ?? 0) >= 3 {
                    tiFlags[r.check.name] = "(no flag from Ti) this check failed 3 rounds in a row while the code kept changing"
                    emit(.note("Se: '\(r.check.name)' failed 3 rounds in a row, Fi will check it is fair"))
                }
            }
            tiDoubt = ""
            let flagged = results.filter { !$0.ok && tiFlags[$0.check.name] != nil && !fiJudged.contains($0.check.name) && !locked.contains($0.check.name) }
            if !flagged.isEmpty {
                let (rulings, upheld) = await fiJudge(task: task, flagged: flagged)
                fiNote = upheld.isEmpty ? "" : upheld + "\n"
                if !upheld.isEmpty { emit(.note("Fi: \(flagged.count - rulings.count) flagged check(s) are fair to the task, they stay")) }
                for f in rulings { if let i = checks.firstIndex(where: { $0.name == f.name }) { checks[i] = f; emit(.note("Fi: Ti was right, check '\(f.name)' contradicted the task, corrected")) } }
                if !rulings.isEmpty {
                    results = runChecks(checks, in: dir, emitting: true)
                    let p3 = results.filter { $0.ok }.count
                    best = (p3, checks.count)
                    if p3 == checks.count && !neBreakDone {
                        neBreakDone = true
                        if let fb = await neGate(task: task, checks: &checks) {
                            feedback = fb
                            emit(.verdict(passed: p3, total: checks.count, feedback: feedback))
                            lastFails = []; lastPassed = p3
                            continue
                        }
                    }
                    if p3 == checks.count {
                        emit(.verdict(passed: p3, total: checks.count, feedback: "all checks pass after Fi corrected a check that contradicted the task"))
                        await learn(task: task, approach: approach, checks: checks, recalled: recalled)
                        await reward(loop == 1 ? 10 : 5, loop == 1 ? "solved on the first try" : "solved", solved: true, firstTry: loop == 1)
                        return finish(t0, solved: true, loops: loop, passed: p3, total: checks.count, approach: approach, help: nil)
                    }
                }
            }
            passed = results.filter { $0.ok }.count
            fails = Set(results.filter { !$0.ok }.map { $0.check.name })
            lastOk = Dictionary(results.map { ($0.check.name, $0.ok) }, uniquingKeysWith: { a, _ in a }); liveChecks = checks
            saveVersion("round-\(loop)")
            // Se keeps the best version so far, not just the last one
            // ROLLBACK (user 11/16, lock what works): this round broke check(s) the best version passed and didn't beat it,
            // so put the best version back before Ti tries again (task 11 bounced 8 -> 5 -> 8 -> 5).
            var rollbackNote = ""
            let nowOk = Set(results.filter { $0.ok }.map { $0.check.name })
            let brokeGood = bestOk.subtracting(nowOk)
            if bestSaved >= 0, passed <= bestSaved, !brokeGood.isEmpty, FileManager.default.fileExists(atPath: dir + "/.teti/best") {
                replaceProject(dir, with: dir + "/.teti/best")
                results = runChecks(checks, in: dir, emitting: false)
                passed = results.filter { $0.ok }.count
                fails = Set(results.filter { !$0.ok }.map { $0.check.name })
                lastOk = Dictionary(results.map { ($0.check.name, $0.ok) }, uniquingKeysWith: { a, _ in a })
                best = (passed, checks.count)
                rollbackNote = "⚠ SE ROLLED BACK: your last change broke \(brokeGood.sorted().joined(separator: ", ")), which worked before. The code is back to the best version (\(passed)/\(checks.count)). Make a SMALLER fix that keeps those passing.\n"
                emit(.note("Se: the change broke \(brokeGood.count) check(s) that worked, rolled back to the best version (\(passed)/\(checks.count))"))
            }
            if passed > bestSaved {
                bestSaved = passed; lastImproveLoop = loop; bestOk = Set(results.filter { $0.ok }.map { $0.check.name })
                try? FileManager.default.removeItem(atPath: dir + "/.teti/best")
                copyProject(from: dir, to: dir + "/.teti/best")
            }
            // Se: over budget with no progress means the loop is about to stop, so skip Te's slow write-up (12-19 min on task 11)
            let doneForNow = loop > 1 && passed <= lastPassed && Date().timeIntervalSince(t0) / 60 > Self.timeBudgetMinutes
            feedback = doneForNow ? "(Se: over the time budget with no progress, Te's write-up skipped)" : await teVerdict(task: task, results: results)
            // Se passes what it saw on to the thinking functions (Ti next round, Ne if it branches)
            let sameFailure = seChanged && fails == lastFails && loop > 1
            let minsLeft = Self.timeBudgetMinutes - Date().timeIntervalSince(t0) / 60
            feedback = rollbackNote + fiNote + circleNote + String(format: "SE: about %.0f minutes left on this task%@\n", max(0, minsLeft),
                                           minsLeft < 30 ? ", so make small targeted fixes, no rewrites" : "") +
                "SE, what actually changed in the code this round:\n\(seChange)\n" +
                (seChanged ? "" : "(Ti changed nothing, so the result can't have improved.)\n") +
                (sameFailure ? "The code changed but the SAME checks failed the same way: the problem may not be in this code. Look at the failing output itself.\n" : "") +
                "\n" + feedback
            if !fails.isEmpty { feedback += "\nIf you worked out by hand that a failing check contradicts the task, flag it with <wrong_check name=\"check-name\">why</wrong_check> instead of bending working code to fit it." }
            if !brokeLocked.isEmpty { feedback = "⚠ SE: YOU BROKE checks the smaller brain had working: \(brokeLocked.joined(separator: ", ")). Put them back first.\n" + feedback }
            lastFeedbackText = feedback
            await track.update { $0.failedLoops += 1; $0.points -= 1 }
            if Self.claimsSuccess(lastTiFinal) {
                await track.update { $0.falseClaims += 1; $0.points -= 10; $0.streak = 0 }
                feedback = "⚠ You said it works, but \(checks.count - passed) check(s) FAIL. That false claim is on your record. Never claim success without proof.\n" + feedback
                emit(.note("Te caught a FALSE success claim (recorded)"))
            }
            await rememberPain(task: task, feedback: feedback, results: results)
            emit(.verdict(passed: passed, total: checks.count, feedback: feedback))

            // Se: how long has this taken, and is the problem even in the code?
            let minutes = Date().timeIntervalSince(t0) / 60
            let budget = Self.timeBudgetMinutes
            let failing = results.filter { !$0.ok }
            let setupProblem = !failing.isEmpty && failing.allSatisfy { Self.isEnvironmentError($0.output) }
            emit(.note(String(format: "Se: %.0f min on this task (budget %.0f)", minutes, budget) +
                       (setupProblem ? " · every failure is a setup error (missing file/package, shell quirk), not the logic" : "")))
            let noProgress = loop > 1 && passed <= lastPassed
            if minutes > budget && noProgress {
                emit(.note(String(format: "Se: over the time budget (%.0f of %.0f min) with no progress, handing this up", minutes, budget)))
                for r in recalled where !r.isAvoid { await ni.reinforce(r.id, success: false) }
                await track.update { $0.unsolved += 1; $0.points -= 5; $0.streak = 0 }
                return finish(t0, solved: false, loops: loop, passed: restoreBest(checks, current: passed), total: best.total, approach: approach,
                              help: helpRequest(task: task, why: String(format: "Se stopped it: %.0f min, over the %.0f min budget, no progress.", minutes, budget) +
                                                (setupProblem ? " Every failure looked like a setup error, so check the tests/environment first." : ""),
                                                checks: checks, feedback: feedback))
            }

            // SPEED LADDER (user 11/16: "better thinking but 20x slower, find a sweet spot"). gate6v1 task 11 hit its best score
            // at minute 7 and looped 32 more minutes without beating it. No new best in 3 rounds and past the plateau time
            // (default 10 min, TETI_PLATEAU_MIN) = stop and keep the best version.
            let plateauMin = Double(ProcessInfo.processInfo.environment["TETI_PLATEAU_MIN"] ?? "") ?? 10
            // NEARLY DONE (diag1 task 6, 11/16): at 90%+ of checks, 2 rounds with no new best = stop and keep the best (it
            // had 9/10 at 6 min, its code already passed every hidden test, and it looped on a debatable check to 9+ min).
            // (lang-py 11/16: 8/9 = 88.9% just missed 90%) only ONE failing check out of 5+ also counts as nearly done
            let nearlyDone = (bestSaved * 10 >= checks.count * 9 || (checks.count >= 5 && bestSaved >= checks.count - 1)) && loop - lastImproveLoop >= 2
            if (loop - lastImproveLoop >= 3 && minutes >= plateauMin) || nearlyDone {
                emit(.note(String(format: "Se: no new best score in %d rounds and %.0f min used, stopping and keeping the best version (%d/%d)", loop - lastImproveLoop, minutes, max(bestSaved, 0), checks.count)))
                for r in recalled where !r.isAvoid { await ni.reinforce(r.id, success: false) }
                await track.update { $0.unsolved += 1; $0.points -= 2; $0.streak = 0 }
                return finish(t0, solved: false, loops: loop, passed: restoreBest(checks, current: passed), total: best.total, approach: approach,
                              help: helpRequest(task: task, why: String(format: "Se stopped it: stuck at its best score for %d rounds (%.0f min).", loop - lastImproveLoop, minutes),
                                                checks: checks, feedback: feedback))
            }

            // Ne: stuck on the same failures? try different paths in parallel sandboxes
            // A wall = no progress since last loop (same failures, or the score didn't go up).
            stuck = (loop > 1 && (fails == lastFails || passed <= lastPassed)) ? stuck + 1 : 0
            lastFails = fails; lastPassed = passed
            // the perception switch: when stuck, choose ONE way to look at the problem (Se or Ne), in one fast step
            if let pending = pendingSwitch { recordSwitch(kind: pending.kind, choice: pending.choice, progress: passed > pending.passed) ; pendingSwitch = nil }
            if stuck >= 1 && loop < hardCap {
                let pick = await perceptionSwitch(task: task, results: results, seChange: seChange, codeChanged: seChanged)
                emit(.note("🔀 switch → \(pick.choice) (\(pick.why))"))
                pendingSwitch = (Self.failureKind(results.filter { !$0.ok }.map { $0.output }), pick.choice, passed)
                if pick.choice == "Se" {
                    // Se mode: re-look at the tests and setup instead of rewriting the program
                    feedback = "SE MODE: the failures look like they come from the tests or setup, not your logic. Read the failing output literally. If your program is right, say so plainly and don't rewrite it.\n\n" + feedback
                    stuck = 0
                }
            }
            if stuck >= 1 && loop < hardCap {
                if let win = await neBranch(task: task, checks: checks, feedback: feedback, knowledge: knowledge, current: passed, startedAt: t0) {
                    approach = win
                    let r2 = runChecks(checks, in: dir, emitting: true)
                    let p2 = r2.filter { $0.ok }.count
                    best = (p2, checks.count)
                    var neHeld = true
                    if p2 == checks.count && !neBreakDone {
                        neBreakDone = true
                        if let fb = await neGate(task: task, checks: &checks) { feedback = fb; neHeld = false }
                    }
                    if p2 == checks.count && neHeld {
                        emit(.verdict(passed: p2, total: checks.count, feedback: "Ne's path passes every check"))
                        await learn(task: task, approach: approach, checks: checks, recalled: recalled)
                        await reward(5 + 3, "solved via a Ne breakthrough", solved: true, firstTry: false)
                        return finish(t0, solved: true, loops: loop, passed: p2, total: checks.count, approach: approach, help: nil)
                    }
                    if neHeld { feedback = await teVerdict(task: task, results: r2) }   // keep Ne's "broke it" feedback otherwise
                    lastFails = Set(r2.filter { !$0.ok }.map { $0.check.name })
                }
                stuck = 0
            }
            // Te may add a check it realizes was missing (never removes one)
            if loop == 2, let extra = await teAddCheck(task: task, checks: checks) { checks.append(extra); emit(.note("Te added check '\(extra.name)'")) }
        }
        for r in recalled where !r.isAvoid { await ni.reinforce(r.id, success: false) }
        await track.update { $0.unsolved += 1; $0.points -= 5; $0.streak = 0 }
        emit(.note("💢 -5: unsolved (streak reset)"))
        return finish(t0, solved: false, loops: ran, passed: restoreBest(liveChecks, current: best.passed), total: best.total, approach: approach,
                      help: helpRequest(task: task, why: "Still failing after \(ran) Te⇄Ti loops.", checks: checks, feedback: feedback))
    }

    // MARK: Te

    /// Router (pure code, no model call). "ne-first" = edge-heavy spec: Ne (red team) lists edge cases BEFORE Te (test
    /// generator) writes checks. Everything else keeps the normal Te-first order. TETI_STACK=fixed turns routing off.
    func pickStack(_ task: String) -> String {
        // PAUSED 11/16 (user: testing took too much time): routing is OFF unless TETI_STACK=routed.
        if ProcessInfo.processInfo.environment["TETI_STACK"] != "routed" { return "fixed (Te first)" }
        return Self.ruleSentences(task).count >= 3 ? "ne-first" : "te-first"
    }

    /// Ne goes first: a short list of edge CASES from the task text, no expected answers (Te and the answer key own those,
    /// so Ne's arithmetic can't plant a wrong expected value like gate5v3's 4.0).
    func neFirst(task: String) async -> String {
        emit(.phase("Ne: what edge cases does this task hide? (before Te writes checks)", loop: 0))
        let reply = await ask([.init(role: .system, content: "You are Ne, the what-if explorer of Code Smash TeTi."),
                               .init(role: .user, content: """
            TASK: \(task)

            Before anyone writes tests: list the edge cases this TASK text actually requires (ties, empty input, nesting,
            missing items, number formats, exact output lines, error exits...). Only cases the task words require.
            For each, one line: <case cite="exact words from the TASK">the input situation to test</case>
            Do NOT give expected outputs. At most 8 cases.
            """)], phase: "ne-first", maxTokens: 600)
        let pairs = allMatchPairs(#"<case\s+cite="([^"]*)"\s*>([^<]+)</case>"#, reply).filter { Self.citeInTask($0.0, task) }
        guard !pairs.isEmpty else { emit(.note("Ne: no edge cases with a real task quote")); return "" }
        emit(.note("Ne listed \(pairs.count) edge case(s) for Te"))
        return "\n\nNE (red team) WENT FIRST and listed these edge cases. Give each one a check (work out the expected output yourself from the TASK):\n" +
            pairs.map { "- \($0.1.trimmingCharacters(in: .whitespacesAndNewlines))  (task: \"\($0.0)\")" }.joined(separator: "\n")
    }

    func teFrame(task: String, knowledge: String) async -> [Check] {
        let prompt = """
        TASK from the owner:
        \(task)

        Files already in the folder: \(listing(dir))

        Define what "done" means as 2-6 shell checks that PROVE the task works when run in the project folder.
        Each check runs with the project folder as its current directory: name project files plainly (tool.py), never ../tool.py. FE SAYS: think like the real user, and test each requirement more than one way, including the cases people actually hit (signs, empty or bad input, repeats).
        SWIFT PACKAGES (a folder with Package.swift): build with `swift build`; the program then lives in the HIDDEN folder .build/debug/<name> (with the dot), never build/; or run it with `swift run <name>`. Never make build/ folders or links. A SINGLE .swift FILE with no Package.swift is NOT a package: run it exactly the way the task says (for example `swift tempconv.swift 100 C`); never use `swift run` or `swift build` for it.
        Each check is a zsh command that exits 0 only if that part works. Checks run IN ORDER, together, on a fresh
        copy of the project folder; if the program stores data, the FIRST check should start by deleting that data file.
        INDEPENDENCE: when a check needs input data, the check must create its OWN test input inline (for example
        printf 'line1\nline2\n' > te_input.txt && ./prog te_input.txt) and compare against the answer YOU worked out.
        Never rely on sample files Ti writes; Ti must not be able to shape the exam.
        FAIR TO THE TASK (9B exam, 11/11): for error cases check only what the task states (the exit code, and that something
        went to stderr); never require exact error wording the task doesn't give. Feed input the way the task says: if the
        program takes a file path, write the input to a file first and pass its path; never use - or stdin unless the task says so.
        EXACT OUTPUT (exam task 3, 11/11): compare program output exactly, out=$(...) && test "$out" = "4"; never grep -q for a
        number (grep -q "4" also matches 14 and 4.0). Follow the task's FORMAT words literally ("as an integer if whole" means
        4, not 4.0). Feed only input the task calls valid unless the check is testing the error case (invalid JSON must exit 1,
        so never expect a sum from it). Two JSON values in one file are NOT valid JSON. Duplicate keys in one object are not a real case.
        EXIT CODES: a check passes only if its command exits 0. If the task REQUIRES a non-zero exit (errors), write the
        check as: out=$(./prog bad 2>&1); test $? -eq 1 && echo "$out" | grep -q "error"   (never let the expected
        error exit fail your check). Use plain grep -q "text" (no unusual flags). Optionally add expect="text" when the
        output must contain specific text. Test real behavior (run the program, compare output), not just that a file exists.
        EVERY RULE GETS A CHECK (11/16): each check must quote, in cite="...", the exact TASK words it tests. Give every
        edge rule in the task its own check: ties, empty input, trailing newline or spaces, nested data, decimals, negatives, sorting order.
        Reply with exactly:
        <goal>one sentence</goal>
        <checks>
        <check name="short-name" cite="exact words from the TASK">command</check>
        <check name="short-name" cite="exact words from the TASK" expect="text that must appear">command</check>
        </checks>
        """
        for attempt in 0..<2 {
            let reply = await ask([.init(role: .system, content: Self.tePersona + "\n" + Values.preamble + "\n" + knowledge),
                                   .init(role: .user, content: prompt + (attempt > 0 ? "\n\nIMPORTANT: use the exact <check> format." : ""))],
                                  phase: "te-frame", maxTokens: 1500)
            let cs = parseChecks(reply).filter { c in
                let ok = Sandbox.run(dir, "zsh -n -c " + Self.shellQuote(c.command), timeout: 10).0 == 0
                if !ok { emit(.note("Te check '\(c.name)' has a syntax error, dropped")) }
                return ok
            }
            // Drop exact copies (exam task 12, 11/11): Te wrote 'ccc a bb ccc' as tie-first, -third, -fifth... 32 checks, ~13 real ones
            var seenCmd = Set<String>(), copies = 0
            let unique = cs.filter { c in
                let key = c.command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ") + "\u{1}" + (c.expect ?? "")
                if seenCmd.insert(key).inserted { return true }
                copies += 1; return false
            }
            if copies > 0 { emit(.note("Te: \(copies) check(s) were exact copies of another one, dropped (\(unique.count) left)")) }
            if !unique.isEmpty { return await coverageGate(task: task, knowledge: knowledge, reply: reply, checks: unique) }
        }
        return []
    }

    /// Edge-rule sentences of the task (11/16): the fails on tasks 3, 11, 12 were all edge rules nobody tested
    /// (a tie, empty input, a trailing newline, nested data). Plain code, no model.
    nonisolated static func ruleSentences(_ task: String) -> [String] {
        let flat = task.replacingOccurrences(of: "\n", with: " ")
        let cues = ["tie", "empty", "trailing", "newline", "nested", "missing", "invalid", "not valid", "negative", "decimal",
                    "sorted", "descending", "ascending", "ignore", "skip", "still count", "exactly", "duplicate", "whitespace",
                    "blank", "zero", "case-insensitive", "case insensitive", "longest", "first"]
        // a rule ends at . ! ? followed by a space (so orders.swift and 98.6 don't split), or at ; ( ) or ", " (task 12 packs
        // 4 rules in one sentence: trailing newline; empty text; words; "the first one if tied")
        guard let rx = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+|;\s*|\(|\)|,\s+"#) else { return [] }
        let marked = rx.stringByReplacingMatches(in: flat, range: NSRange(flat.startIndex..., in: flat), withTemplate: "\u{1}")
        return marked.split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { t in t.count > 12 && cues.contains(where: { t.lowercased().contains($0) }) }
    }

    /// Coverage gate (11/16): every edge rule in the task must be quoted by at least one check. Uncovered rules go back to
    /// Te once ("these rules have no check yet"); only what Te writes for them is added. The hidden tests are never used.
    func coverageGate(task: String, knowledge: String, reply: String, checks: [Check]) async -> [Check] {
        let citePairs = allMatchPairs(#"<check\s+name="([^"]+)"[^>]*?\scite="([^"]*)""#, reply)
        let cites = citePairs.map { $0.1 }.filter { !$0.isEmpty }
        let rules = Self.ruleSentences(task)
        let uncovered = rules.filter { rule in !cites.contains { Self.citeInTask($0, rule) } }
        guard !uncovered.isEmpty else {
            if !rules.isEmpty { emit(.note("Te: all \(rules.count) edge rule(s) in the task have a check")) }
            return checks
        }
        let list = uncovered.prefix(5).map { "- \($0)" }.joined(separator: "\n")
        emit(.note("Te: \(uncovered.count) of \(rules.count) edge rule(s) have no check yet, asking for them"))
        let have = checks.map { "<check name=\"\($0.name)\">\($0.command)</check>" }.joined(separator: "\n")
        let ask2 = """
        TASK from the owner:
        \(task)

        Your checks so far:
        \(have)

        These rules from the task have NO check yet:
        \(list)

        Write ONE new check for each rule above (at most 5), same rules as before: create your own input inline, compare against
        the answer YOU worked out by hand, exact output comparison. Reply with only:
        <checks>
        <check name="short-name" cite="exact words from the TASK">command</check>
        </checks>
        """
        let r2 = await ask([.init(role: .system, content: Self.tePersona + "\n" + Values.preamble + "\n" + knowledge),
                            .init(role: .user, content: ask2)], phase: "te-coverage", maxTokens: 1200)
        let names = Set(checks.map { $0.name }), cmds = Set(checks.map { $0.command })
        let extra = parseChecks(r2).filter { c in
            guard !names.contains(c.name), !cmds.contains(c.command) else { return false }
            let ok = Sandbox.run(dir, "zsh -n -c " + Self.shellQuote(c.command), timeout: 10).0 == 0
            if !ok { emit(.note("Te coverage check '\(c.name)' has a syntax error, dropped")) }
            return ok
        }.prefix(5)
        for c in extra { emit(.note("Te check '\(c.name)': \(c.command)")) }
        emit(.note("Te: added \(extra.count) check(s) for untested edge rules"))
        return checks + extra
    }

    /// CODE DOES THE EXACT WORK (user 11/16): known error -> known fix. Common compiler/runtime errors get the exact fix
    /// attached by code, no model call (gate6v1 task 11: the Swift stderr print error cost round after round).
    nonisolated static let knownFixes: [(String, String)] = [
        (#"FileHandle' to expected argument type 'URL'|contentsOf: *FileHandle"#, "Swift: to read all of standard input use String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self). String(contentsOf:) wants a file URL, not a FileHandle."),
        (#"TextOutputStream|print\(.*to: *&"#, "Swift: to print an error, use FileHandle.standardError.write((message + \"\\n\").data(using: .utf8)!) instead of print(..., to:)."),
        (#"cannot find '([A-Za-z_]+)' in scope"#, "Swift: a name is used that doesn't exist: define it, fix its spelling, or add `import Foundation` at the top."),
        (#"No such module '([^']+)'"#, "Swift: that module isn't available; use only Foundation (standard library)."),
        (#"'main' attribute cannot be used in a module that contains top-level code"#, "Swift: remove @main (a single-file script runs its top-level code), or move the code into the @main type."),
        (#"[Ee]xpressions are not allowed at the top level"#, "Swift: top-level code only works in main.swift or a single-file script; in a package, put it in Sources/<name>/main.swift."),
        (#"value of optional type '[^']+' must be unwrapped"#, "Swift: unwrap the optional (guard let x = ... else { exit(1) } or ?? default) before using it."),
        (#"ModuleNotFoundError: No module named '([^']+)'"#, "Python: that module isn't installed; use only the standard library."),
        (#"IndentationError|TabError"#, "Python: fix the indentation (4 spaces, no tabs) on the line the error names."),
        (#"NameError: name '([^']+)' is not defined"#, "Python: a name is used before it's defined (typo, or missing import)."),
        (#"JSONDecodeError"#, "Python: invalid JSON reached json.load uncaught: wrap it in try/except json.JSONDecodeError, print the error to stderr, sys.exit(1)."),
        (#"FileNotFoundError"#, "Python: a missing file wasn't caught: wrap open() in try/except OSError, print to stderr, sys.exit(1)."),
        (#"Permission denied"#, "Run the file through its interpreter (python3 x.py / swift x.swift) or chmod +x it."),
    ]

    /// Exact output difference by code (user 11/16: no model needed to spot '.build' vs 'build'). For a check of the form
    /// out=$(program args) ... test "$out" = "expected", runs the program the same way in a fresh copy and reports the
    /// first difference character by character. Plus the known-fix table. nil = code can't explain it, ask the model.
    func codeDiagnosis(_ r: (check: Check, ok: Bool, output: String)) -> String? {
        var notes: [String] = []
        for (pat, fix) in Self.knownFixes where r.output.range(of: pat, options: .regularExpression) != nil { notes.append("KNOWN FIX: " + fix) }
        let cmd = r.check.command
        if !cmd.contains("$?"), let rx = try? NSRegularExpression(pattern: #"out=\$\(((?:"[^"]*"|'[^']*'|[^)"'])*)\)([\s\S]*?)test\s+"\$out"\s+=\s+"([^"]*)""#),
           let m = rx.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
           let pr = Range(m.range(at: 1), in: cmd), let er = Range(m.range(at: 3), in: cmd), let whole = Range(m.range, in: cmd), !cmd[pr].contains("|") {
            let fresh = dir + "/.teti/diagrun"
            try? FileManager.default.removeItem(atPath: fresh)
            copyProject(from: dir, to: fresh)
            let (code, got) = Sandbox.run(fresh, String(cmd[..<whole.lowerBound]) + String(cmd[pr]) + " 2>/dev/null", timeout: 60)
            try? FileManager.default.removeItem(atPath: fresh)
            let want = String(cmd[er]).replacingOccurrences(of: "\\n", with: "\n").trimmingCharacters(in: .newlines)
            let have = got.trimmingCharacters(in: .newlines)
            if code != 0 && have.isEmpty {
                if notes.isEmpty { return nil }                          // crashed, no known fix: the model reads the error
            } else if have != want {
                let wl = want.components(separatedBy: "\n"), hl = have.components(separatedBy: "\n")
                var d = "EXACT DIFFERENCE (found by code) for '\(r.check.name)':"
                if wl.count != hl.count { d += " expected \(wl.count) line(s), got \(hl.count)." }
                for i in 0..<max(wl.count, hl.count) {
                    let w = i < wl.count ? wl[i] : "(no line)", h = i < hl.count ? hl[i] : "(no line)"
                    guard w != h else { continue }
                    let pos = zip(w, h).prefix { $0 == $1 }.count
                    let wc = pos < w.count ? "'\(w[w.index(w.startIndex, offsetBy: pos)])'" : "end of line"
                    let hc = pos < h.count ? "'\(h[h.index(h.startIndex, offsetBy: pos)])'" : "end of line"
                    d += "\n  line \(i + 1): expected \"\(w.prefix(120))\"\n           got      \"\(h.prefix(120))\"\n  first difference at character \(pos + 1): expected \(wc), got \(hc)"
                    break
                }
                notes.insert(d, at: 0)
            }
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    func teVerdict(task: String, results: [(check: Check, ok: Bool, output: String)]) async -> String {
        // Code first: if code explains every failing check exactly, Te's model write-up (30-50 s a round) is skipped.
        let failing = results.filter { !$0.ok }
        let diags = failing.map { ($0, codeDiagnosis($0)) }
        let byCode = diags.compactMap { $0.1 }
        if !failing.isEmpty && byCode.count == failing.count {
            emit(.note("Te: code explained all \(failing.count) failing check(s) exactly, no model call"))
            return byCode.joined(separator: "\n\n")
        }
        if !byCode.isEmpty { emit(.note("Te: code explained \(byCode.count) of \(failing.count) failing check(s); the model reads the rest")) }
        let codeNotes = byCode.isEmpty ? "" : "\n\nFOUND BY CODE (exact, trust these):\n" + byCode.joined(separator: "\n\n")
        let report = results.filter { r in !diags.contains { $0.0.check.name == r.check.name && $0.1 != nil } }.map { r in
            "[\(r.ok ? "PASS" : "FAIL")] \(r.check.name): \(r.check.command)" + (r.check.expect.map { " (expect: \($0))" } ?? "") +
            (r.ok ? "" : "\n" + String(r.output.suffix(1200)))
        }.joined(separator: "\n\n")
        let reply = await ask([.init(role: .system, content: Self.tePersona),
                               .init(role: .user, content: "TASK: \(task)\n\nCHECK RESULTS (real output):\n\(report)\n\n" +
                                     "Tell Ti exactly what is wrong and what to fix, most important first. Max 8 lines. No code.")],
                              phase: "te-verdict", maxTokens: 700)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines) + codeNotes
    }

    /// Te checks its own exam: a failing check whose output shows the PROGRAM did what the task asked (or a command
    /// misuse like a grep usage error) is a broken check. Returns repaired checks; the requirement must stay the same.
    func teAuditChecks(task: String, results: [(check: Check, ok: Bool, output: String)], tiSays: String = "") async -> [Check] {
        let failing = results.filter { !$0.ok }
        guard !failing.isEmpty else { return [] }
        // Path doctor, in code (11/10, exam task 5): a check that can't find a file which DOES exist in the project is
        // a broken check, not a broken program. Te once pointed every check at ../groupsum.py and lost 2+ hours
        // blaming correct code. Repair the path before asking the model anything.
        let projectFiles = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }
        var doctored: [Check] = []
        for r in failing where r.output.contains("No such file or directory") || r.output.contains("can't open file") {
            var cmd = r.check.command
            for f in projectFiles {
                for bad in ["../\(f)", "../../\(f)", dir + "/\(f)"] where cmd.contains(bad) { cmd = cmd.replacingOccurrences(of: bad, with: f) }
            }
            if cmd != r.check.command { doctored.append(Check(name: r.check.name, command: cmd, expect: r.check.expect)) }
        }
        if !doctored.isEmpty { return doctored }
        let report = failing.map { "[\($0.check.name)] \($0.check.command)" + ($0.check.expect.map { " (expect: \($0))" } ?? "") + "\n" + String($0.output.suffix(600)) }.joined(separator: "\n\n")
        let reply = await ask([.init(role: .system, content: Self.tePersona + "\nBe strict and fair: you may be wrong too."),
                               .init(role: .user, content: """
            TASK: \(task)

            These checks FAILED (real output below). For each, decide: is the PROGRAM wrong, or is the CHECK itself broken?
            A check is broken only if: the output shows the program did exactly what the task requires but the check
            misjudged it (e.g. the task requires exit code 1 and the check treats that as failure), or the check misuses a
            command (usage error, typo), or it can't find a file that exists (checks run INSIDE a fresh copy of the
            project: refer to project files by their plain name, e.g. groupsum.py, never ../groupsum.py).
            Never weaken a real requirement.
            SE SAYS, what's actually in the project folder right now: \(projectFiles.sorted().joined(separator: ", ")).
            FI SAYS, be fair: a check must be honest to the TASK text. Punishing a program for doing exactly what the task
            asks is wrong, and so is letting a real requirement slide. If a check assumed something that isn't true here
            (an empty file, a folder, an order of steps), it is the check that's broken.
            \(tiSays.isEmpty ? "" : "\nTi, who built the program, said this after its last build (weigh it fairly, it may be right or wrong):\n" + String(tiSays.suffix(500)) + "\n")
            \(report)

            For each BROKEN check reply with a corrected <check name="same-name">command</check> testing the SAME requirement.
            If all failures are the program's fault, reply exactly: PROGRAM
            """)], phase: "te-audit", maxTokens: 900)
        let names = Set(failing.map { $0.check.name })
        return parseChecks(reply).filter { names.contains($0.name) && Sandbox.run(dir, "zsh -n -c " + Self.shellQuote($0.command), timeout: 10).0 == 0 }
    }

    /// Fi judges checks Ti flagged as contradicting the task (exam task 12, 11/10: Ti wrote "this test is extremely
    /// suspicious", had no way to say so, and bent working code to fit a check that said 5 words were 6).
    /// Returns corrected checks (same requirement, right answer) and Fi's reasons for the flags it rejected.
    /// Output-shape rules the task spells out (format checker, 11/16). Plain code, no model: task 11 says "Then print a final
    /// line 'TOTAL: grand'" and Te + blind Fi both wrote checks with no TOTAL line. Only two very literal patterns, so it never
    /// invents rules: "<N> lines" with exactly N quoted templates (each line starts with that template's first word), and
    /// "final/last line '<CAPS>...'" (the last line starts with that word). Tested on all 12 exam tasks: rules on 7, 11, 12 only.
    nonisolated static func formatRules(_ task: String) -> (lines: [String]?, last: String?) {
        let flat = task.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard let sentRx = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-Z])"#),
              let tplRx = try? NSRegularExpression(pattern: #"'([^']{2,40})'"#),
              let nRx = try? NSRegularExpression(pattern: #"\b(one|two|three|four|five|six|[1-9])\s+lines\b"#),
              let lastRx = try? NSRegularExpression(pattern: #"(?:final|last) line\s+'([A-Z]{2,}:?)"#) else { return (nil, nil) }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]
        let marked = sentRx.stringByReplacingMatches(in: flat, range: NSRange(flat.startIndex..., in: flat), withTemplate: "\u{1}")
        var lines: [String]? = nil, last: String? = nil
        for sent in marked.split(separator: "\u{1}").map(String.init) {
            let r = NSRange(sent.startIndex..., in: sent)
            let tpls = tplRx.matches(in: sent, range: r).compactMap { Range($0.range(at: 1), in: sent).map { String(sent[$0]) } }
            if let m = nRx.firstMatch(in: sent, range: r), let nr = Range(m.range(at: 1), in: sent), tpls.count >= 2 {
                let n = words[String(sent[nr])] ?? Int(sent[nr]) ?? 0
                if n == tpls.count { lines = tpls.compactMap { $0.split(separator: " ").first.map(String.init) } }
            }
            if let m = lastRx.firstMatch(in: sent, range: r), let lr = Range(m.range(at: 1), in: sent) { last = String(sent[lr]) }
        }
        return (lines, last)
    }

    /// Why a check breaks the task's output shape, or nil. Only for checks that compare the WHOLE output: out=$(prog) with no
    /// pipe, then test "$out" = "...". Error checks and checks that pick one line (| head, | grep) are left alone.
    nonisolated static func formatProblem(_ c: Check, lines: [String]?, last: String?) -> String? {
        let cmd = c.command
        guard !cmd.contains("$?"),
              let rx = try? NSRegularExpression(pattern: #"out=\$\(((?:"[^"]*"|'[^']*'|[^)"'])*)\)[\s\S]*?test\s+"\$out"\s+=\s+"([^"]*)""#, options: []),
              let m = rx.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
              let pr = Range(m.range(at: 1), in: cmd), let er = Range(m.range(at: 2), in: cmd) else { return nil }
        if cmd[pr].contains("|") { return nil }
        let expected = String(cmd[er]).replacingOccurrences(of: "\\n", with: "\n")
        let got = expected.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        if let want = lines {
            if got.count != want.count { return "the task says the output is exactly \(want.count) lines (\(want.joined(separator: ", "))), this check expects \(got.count)" }
            for (g, w) in zip(got, want) where !g.hasPrefix(w) { return "the task says a line starts with '\(w)', this check expects '\(g)'" }
        }
        if let l = last, let final = got.last, !final.hasPrefix(l) {
            return "the task says the last line starts with '\(l)', this check's expected output ends with '\(final)'"
        }
        return nil
    }

    /// Format gate: checks that break the task's own output shape go back to Te once with the exact reason; only fixed checks
    /// that now pass the shape test come back. Nothing is guessed: no rules in the task = no change.
    func formatGate(task: String, knowledge: String, checks: [Check]) async -> [Check] {
        let (lines, last) = Self.formatRules(task)
        guard lines != nil || last != nil else { return checks }
        let bad = checks.compactMap { c in Self.formatProblem(c, lines: lines, last: last).map { (c, $0) } }
        guard !bad.isEmpty else { emit(.note("Format check: all checks match the output shape the task gives")); return checks }
        for (c, why) in bad { emit(.note("Format check: '\(c.name)' is wrong: \(why)")) }
        let list = bad.map { "<check name=\"\($0.0.name)\">\($0.0.command)</check>\nPROBLEM: \($0.1)" }.joined(separator: "\n\n")
        let reply = await ask([.init(role: .system, content: Self.tePersona + "\n" + Values.preamble + "\n" + knowledge),
                               .init(role: .user, content: """
            TASK from the owner:
            \(task)

            These checks expect output that breaks the format the TASK spells out (found by code, not a guess):
            \(list)

            Rewrite each one with the SAME name and the same input, expecting the COMPLETE output the task requires (every line).
            Reply with only:
            <checks>
            <check name="same-name">command</check>
            </checks>
            """)], phase: "te-format", maxTokens: 1500)
        let badNames = Set(bad.map { $0.0.name })
        var fixed: [String: Check] = [:]
        for f in parseChecks(reply) where badNames.contains(f.name) {
            guard Self.formatProblem(f, lines: lines, last: last) == nil,
                  Sandbox.run(dir, "zsh -n -c " + Self.shellQuote(f.command), timeout: 10).0 == 0 else { continue }
            fixed[f.name] = f
        }
        let dropped = badNames.subtracting(fixed.keys)
        emit(.note("Format check: Te fixed \(fixed.count) of \(bad.count)" + (dropped.isEmpty ? "" : ", dropped \(dropped.count) it couldn't fix")))
        let out = checks.compactMap { c -> Check? in
            if let f = fixed[c.name] { return Check(name: c.name, command: f.command, expect: f.expect) }
            return badNames.contains(c.name) ? nil : c
        }
        return out.isEmpty ? checks : out
    }

    /// Input sanity, in code (gate1 task 3 false win, 11/16): Te fed duplicate-key JSON and expected a "success" answer; Ti
    /// wrote its own JSON parser to obey it and broke on real input. A check that writes JSON which isn't one valid document
    /// with unique keys, and doesn't expect an error exit, is dropped. No model call.
    func dropBrokenInputs(_ checks: [Check]) -> [Check] {
        // gate6v1 task 11 (11/16): Te ended 5 checks with '; test $? -eq 0' (does nothing: same exit code either way). Every
        // judge skips checks containing '$?', so 5 wrong checks (no TOTAL line) slipped past and the loop spent 32 min on them.
        let tailRx = try? NSRegularExpression(pattern: #"\s*;\s*test\s+\$\?\s+-eq\s+0\s*$"#)
        let checks = checks.map { c -> Check in
            guard let rx = tailRx else { return c }
            let cmd = c.command, cleaned = rx.stringByReplacingMatches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd), withTemplate: "")
            return cleaned == cmd ? c : Check(name: c.name, command: cleaned, expect: c.expect)
        }
        guard let rx = try? NSRegularExpression(pattern: #"(printf|echo)\s+(?:-e\s+)?'([^']*)'\s*>\s*([\w./-]+\.json)"#) else { return checks }
        let validator = "import json,sys\ndef h(p):\n k=[a for a,_ in p]\n if len(k)!=len(set(k)): raise ValueError('duplicate key')\n return dict(p)\njson.loads(sys.stdin.read(),object_pairs_hook=h)"
        return checks.filter { c in
            let cmd = c.command
            if cmd.contains("$?") || cmd.contains("-ne 0") { return true }   // an error-case check may feed bad JSON on purpose
            for m in rx.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) {
                guard let kr = Range(m.range(at: 1), in: cmd), let br = Range(m.range(at: 2), in: cmd) else { continue }
                var body = String(cmd[br])
                if cmd[kr] == "printf" || cmd.contains("echo -e") { body = body.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t") }
                let (code, out) = Sandbox.run(dir, "printf '%s' " + Self.shellQuote(body) + " | python3 -I -c " + Self.shellQuote(validator), timeout: 5)
                if code != 0 {
                    let why = out.contains("duplicate key") ? "duplicate keys" : (out.contains("Extra data") ? "more than one JSON value" : "invalid JSON")
                    emit(.note("Input check: dropped Te's '\(c.name)', it expects a normal answer but feeds \(why) (not a real case)"))
                    return false
                }
            }
            return true
        }
    }

    /// Answer key (test oracle, 11/16): instead of doing the math in its head, Fi writes its OWN small Python program from the
    /// task text, and code runs it on every check's input (differential testing). A check whose expected output disagrees
    /// with the answer key is dropped. Guards: if the key can't run, or disagrees with most checks (the key is probably the
    /// one that's wrong), fall back to blind Fi. Reference program lives in .teti/ (Ti never sees it).
    // ---------- Tool-offloaded tests (11/16) ----------
    static let exactTag = "\u{1}exact:"
    /// An exact test's expected exit code + output, kept inside `expect` so every place that copies a Check keeps it.
    static func exactSpec(_ e: String?) -> (rc: Int, text: String)? {
        guard let e, e.hasPrefix(exactTag) else { return nil }
        let rest = e.dropFirst(exactTag.count)
        guard let sep = rest.firstIndex(of: "\u{1}"), let rc = Int(rest[..<sep]) else { return nil }
        return (rc, String(rest[rest.index(after: sep)...]))
    }
    static func exactExpect(rc: Int, text: String) -> String { exactTag + "\(rc)\u{1}" + text }
    static func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// How the task says to run the program: the first program call written in the task text.
    static func runCommand(_ task: String) -> String? {
        // (offload quick test 11/16: "orders.swift run as" matched as `swift run as`. Whole words only now.)
        guard let rx = try? NSRegularExpression(pattern: #"(?<![\w./-])(?:python3\s+-m\s+[\w.]+|python3\s+[\w./-]+\.py|swift\s+run\s+(?:-q\s+)?[\w-]+(?![\w.])|swift\s+[\w./-]+\.swift|node\s+[\w./-]+\.js|\./[\w-]+(?![\w./]))"#),
              let m = rx.firstMatch(in: task, range: NSRange(task.startIndex..., in: task)), let r = Range(m.range, in: task) else { return nil }
        return String(task[r])
    }

    /// Te picks the cases, code writes the tests, two answer keys give the expected output.
    func teCasesChecks(task: String, knowledge: String) async -> [Check] {
        guard let run = Self.runCommand(task) else { return [] }
        emit(.phase("Te: picking test cases (code writes the tests, two answer keys work out the answers)", loop: 0))
        let reply = await ask([.init(role: .system, content: "You are Te, the test designer of Code Smash TeTi. You pick WHAT to test. You never write commands or expected answers."),
                               .init(role: .user, content: """
            TASK: \(task)
            \(knowledge.isEmpty ? "" : "\nKNOWN:\n" + knowledge.prefix(2500) + "\n")
            The program is run as: \(run)
            List 6 to 9 test cases that together prove the task is done: normal use, every rule in the task, and the tricky
            edges the task mentions (empty input, ties, a missing final newline, extra spaces, bad input, errors...).
            If the program reads a FILE, give the file's content in <file name="input.json">...</file> (same one-line \\n rule) and
            put the file name in <args>. To test a missing file, just name a file in <args> without giving it.
            For each case give ONLY the input. Use <stdin> for standard input and/or <args> for command-line arguments
            (write args exactly as you would type them in a shell, quotes included). Write stdin on ONE line using \\n for a
            new line and \\t for a tab; to leave out a final newline, just don't write one.
            Do NOT give commands. Do NOT give expected outputs: code works those out.
            Reply with only:
            <case name="short-name" cite="exact words from the TASK this tests"><stdin>...</stdin><args>...</args></case>
            """)], phase: "te-cases", maxTokens: 1500)
        guard let rx = try? NSRegularExpression(pattern: #"<case\s+name="([^"]+)"[^>]*>([\s\S]*?)</case>"#) else { return [] }
        struct Case { let name: String; let stdin: String?; let args: String; let files: [(String, String)] }
        var cases: [Case] = []
        for m in rx.matches(in: reply, range: NSRange(reply.startIndex..., in: reply)) {
            guard let nr = Range(m.range(at: 1), in: reply), let br = Range(m.range(at: 2), in: reply) else { continue }
            let body = String(reply[br])
            let stdin = allMatches(#"<stdin>([\s\S]*?)</stdin>"#, body).first.map {
                $0.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t") }
            let args = (allMatches(#"<args>([\s\S]*?)</args>"#, body).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if args.contains("|") || args.contains(";") || args.contains("&&") || args.contains("$(") || args.contains("`") { continue }
            let name = String(reply[nr]).replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "-", options: .regularExpression)
            var files: [(String, String)] = []
            if let frx = try? NSRegularExpression(pattern: #"<file\s+name="([\w.-]+)"\s*>([\s\S]*?)</file>"#) {
                for fm in frx.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                    if let fn = Range(fm.range(at: 1), in: body), let fc = Range(fm.range(at: 2), in: body) {
                        files.append((String(body[fn]), String(body[fc]).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")))
                    }
                }
            }
            if !cases.contains(where: { $0.name == name }) { cases.append(Case(name: name, stdin: stdin, args: args, files: files)) }
        }
        guard cases.count >= 3 else { emit(.note("Te: only \(cases.count) usable case(s), using the classic test writer instead")); return [] }
        // two independent answer keys
        func key(_ instruction: String, _ phase: String) async -> String? {
            let r = await ask([.init(role: .system, content: "You are a careful Python programmer. You follow the TASK text exactly."),
                               .init(role: .user, content: "TASK: \(task)\n\nThe program is run as: \(run)\n\n\(instruction) Write ONE standalone Python 3 file (standard library only) that BEHAVES like that finished program: it reads the same arguments and standard input and prints exactly what the TASK says to print, with the same exit codes. It is a stand-in for running the program, so it must NOT create files, folders or packages, and must not import the project's own code. (For a Swift task, write the Python equivalent of the program's behavior.) Count characters, words and lines with code. Reply with only:\n<python>\n...program...\n</python>")],
                              phase: phase, maxTokens: 2000)
            return allMatches(#"<python>\s*([\s\S]*?)</python>"#, r).first.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let k1 = await key("Write a short program that does EXACTLY what the TASK says.", "te-cases-key1"),
              let k2 = await key("Write an independent program for the TASK. Read every rule and format word literally; nothing extra.", "te-cases-key2") else {
            emit(.note("Te: the answer keys didn't come back, using the classic test writer instead")); return []
        }
        let scratch = dir + "/.teti/casekeys"
        try? FileManager.default.removeItem(atPath: scratch)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        for (n, k) in [("k1", k1), ("k2", k2)] {
            try? FileManager.default.createDirectory(atPath: scratch + "/" + n, withIntermediateDirectories: true)
            try? k.write(toFile: scratch + "/" + n + "/key.py", atomically: true, encoding: .utf8)
        }
        var out: [Check] = []
        var disagree: [String] = []
        for (i, c) in cases.enumerated() {
            let inFile = ".case\(i + 1).in"
            let setup = c.files.map { "printf %s \(Self.shQuote($0.1)) > \($0.0) && " }.joined() + (c.stdin.map { "printf %s \(Self.shQuote($0)) > \(inFile) && " } ?? "")
            let feed = c.stdin == nil ? "" : " < \(inFile)"
            let argPart = c.args.isEmpty ? "" : " " + c.args
            var results: [(Int, String)] = []
            for n in ["k1", "k2"] {
                let (rc, o) = Sandbox.run(scratch + "/" + n, setup + "python3 -I key.py" + argPart + feed + " 2>/dev/null", timeout: 20)
                results.append((Int(rc), o))
            }
            guard results[0].0 == results[1].0, Self.norm(results[0].1) == Self.norm(results[1].1) else { disagree.append(c.name); continue }
            if results[0].0 != 0 && results[0].1.contains("Traceback") { disagree.append(c.name); continue }
            out.append(Check(name: c.name, command: setup + run + argPart + feed + " 2>/dev/null",
                             expect: Self.exactExpect(rc: results[0].0, text: results[0].1)))
        }
        // Sanity (offload 11/16 false win): tests whose expected output is empty can pass with NO real program. Need at least 2
        // tests with real output, or the tests prove nothing.
        let withOutput = out.filter { (Self.exactSpec($0.expect)?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.count
        if withOutput < 2 {
            emit(.note("Te: only \(withOutput) of the generated tests check real output (run command: \(run)), so they prove nothing; using the classic test writer instead"))
            return []
        }
        // a package that must build gets a build test too (the keys can't check that part)
        if task.contains("swift build") { out.insert(Check(name: "builds", command: "swift build -q 2>&1 | grep -E 'error:|note:' | head -20; swift build -q >/dev/null 2>&1", expect: nil), at: 0) }   // build test shows compiler errors (offload 11/16: hidden errors cost 4 min)
        emit(.note("Te picked \(cases.count) case(s); the two answer keys agree on \(cases.count - disagree.count)" +
                   (disagree.isEmpty ? "" : " (they disagree on \(disagree.joined(separator: ", ")), so those are left out)") +
                   "; code wrote \(out.count) exact test(s)"))
        if !out.isEmpty { keyCode = k1 }
        return out
    }

    /// Expect-style check -> run the answer key in place of the program. Only when the program's output IS the check's
    /// output (one program call, nothing piped or chained after it).
    static func expectJob(_ c: Check) -> (run: String, want: String)? {
        guard let want = c.expect, !want.isEmpty, exactSpec(want) == nil,
              let rx = try? NSRegularExpression(pattern: #"(python3\s+-m\s+[\w.]+|python3\s+[\w./-]+\.py|swift\s+run\s+(?:-q\s+)?[\w-]+|swift\s+[\w./-]+\.swift|\.build/[\w./-]+|\./[\w.-]+)"#) else { return nil }
        let cmd = c.command
        let ms = rx.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd))
        guard ms.count == 1, let r = Range(ms[0].range, in: cmd) else { return nil }
        let tail = cmd[r.upperBound...]
        if tail.contains("|") || tail.contains("&&") || tail.contains(";") { return nil }
        return (cmd.replacingCharacters(in: r, with: "python3 -I .teti/answer_key.py") + " 2>/dev/null", want.replacingOccurrences(of: "\\n", with: "\n"))
    }
    /// Any-style check -> the same check with every call of the program replaced by the answer key (exit code decides).
    /// Only when all program calls are the same program, and never for build checks (the key has nothing to build).
    static func swapJob(_ c: Check) -> String? {
        let cmd = c.command
        if cmd.contains("swift build") || cmd.contains("test -f") || cmd.contains("ls ") || cmd.contains("grep -q") && cmd.contains(".swift") { return nil }
        guard let rx = try? NSRegularExpression(pattern: #"python3\s+-m\s+[\w.]+|python3\s+[\w./-]+\.py|swift\s+run\s+(?:-q\s+)?[\w-]+|swift\s+[\w./-]+\.swift|\.build/[\w./-]+|\./[\w.-]+(?=\s|$|\|)"#) else { return nil }
        let ms = rx.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd))
        guard !ms.isEmpty else { return nil }
        let progs = Set(ms.compactMap { Range($0.range, in: cmd).map { String(cmd[$0]) } })
        guard progs.count == 1 else { return nil }
        return rx.stringByReplacingMatches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd), withTemplate: "python3 -I .teti/answer_key.py") + " 2>&1"
    }
    /// Compare outputs line by line, ignoring trailing spaces and blank edges.
    static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    func answerKey(task: String, checks: [Check]) async -> [Check] {
        guard let rx = try? NSRegularExpression(pattern: #"out=\$\(\s*((?:python3\s+\S+\.py)|(?:swift\s+run\s+(?:-q\s+)?\S+)|(?:swift\s+\S+\.swift)|(?:\.build/\S+)|(?:\./\S+))((?:"[^"]*"|'[^']*'|[^)"'])*)\)([\s\S]*?)test\s+"\$out"\s+=\s+"([^"]*)""#) else { return checks }
        struct Job { let name: String; let run: String; let want: String?; var passOnly: Bool { want == nil } }
        var jobs: [Job] = []
        for c in checks where !c.command.contains("$?") {
            let cmd = c.command
            guard let m = rx.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
                  let ar = Range(m.range(at: 2), in: cmd), let wr = Range(m.range(at: 4), in: cmd), let whole = Range(m.range, in: cmd) else { continue }
            if cmd[ar].contains("|") { continue }
            let setup = String(cmd[..<whole.lowerBound])            // the part that writes the check's own input files
            let run = setup + "python3 -I .teti/answer_key.py" + cmd[ar] + " 2>/dev/null"
            jobs.append(Job(name: c.name, run: run, want: String(cmd[wr]).replacingOccurrences(of: "\\n", with: "\n")))
        }
        // lang2-py task 12 (11/16): Te's checks were `printf 'abc def' | python3 -m textstats` + expect="...chars 6..." (wrong,
        // it's 7). The key only read out=$(...) checks, so it never ran and wrong counts stood for 9 min. Expect-style too now.
        for c in checks where !c.command.contains("$?") && !jobs.contains(where: { $0.name == c.name }) {
            if let ej = Self.expectJob(c) { jobs.append(Job(name: c.name, run: ej.run, want: ej.want)) }
            // lang3-py (11/16): third style, `prog file | grep -q "^lines 3$"` (no expect). General rule: swap the key in for
            // the program and run the WHOLE check; if it fails with the trusted key, the check is wrong, whatever its style.
            else if let sw = Self.swapJob(c) { jobs.append(Job(name: c.name, run: sw, want: nil)) }
        }
        guard jobs.count >= 2 else { return await fiPreAudit(task: task, checks: checks) }
        emit(.phase("Fi: writes its own answer key and runs it on \(jobs.count) check inputs", loop: 0))
        let reply = await ask([.init(role: .system, content: "You are Fi, the fairness judge of Code Smash TeTi. You follow the TASK text exactly."),
                               .init(role: .user, content: """
            TASK: \(task)

            Write a short Python 3 program (standard library only) that does EXACTLY what the TASK says: same arguments, same
            standard input, same printed output, same exit codes. If the task describes a Swift program or package, write the
            Python equivalent of the program's behavior. Follow every rule and format word in the task literally. Nothing extra.
            Reply with only:
            <python>
            ...program...
            </python>
            """)], phase: "fi-answer-key", maxTokens: 2000)
        guard let code = allMatches(#"<python>\s*([\s\S]*?)</python>"#, reply).first, !code.isEmpty else {
            emit(.note("Fi: no answer key came back, using blind Fi instead")); return await fiPreAudit(task: task, checks: checks)
        }
        let scratch = dir + "/.teti/keyrun"
        try? FileManager.default.removeItem(atPath: scratch)
        try? FileManager.default.createDirectory(atPath: scratch + "/.teti", withIntermediateDirectories: true)
        try? code.write(toFile: scratch + "/.teti/answer_key.py", atomically: true, encoding: .utf8)
        var agree = 0, ran = 0
        var drop: [(String, String, String)] = []
        for j in jobs {
            let (rc, out) = Sandbox.run(scratch, j.run, timeout: 20)
            if j.passOnly {
                if out.contains("answer_key.py") && (out.contains("Traceback") || out.contains("Error")) { continue }   // key crashed: no vote
                ran += 1
                if rc == 0 { agree += 1 } else { drop.append((j.name, "check passes", "fails even with the answer key")) }
                continue
            }
            if (rc != 0 && out.isEmpty) || out.hasPrefix("zsh:") { continue }   // key crashed / shell error (diag2 task 6): no vote
            ran += 1
            let got = Self.norm(out), want = Self.norm(j.want ?? "")
            if got == want { agree += 1 } else { drop.append((j.name, want, got)) }
        }
        try? FileManager.default.removeItem(atPath: scratch)
        guard ran >= 2 else { emit(.note("Fi: the answer key couldn't run on the checks, using blind Fi instead")); return await fiPreAudit(task: task, checks: checks) }
        if drop.count * 2 > ran {
            // Two-key tiebreaker (lang4 11/16): Te miscounts often, so "key disagrees with most checks" doesn't mean the key is wrong.
            // A second key, written fresh with a different instruction, settles it: if the two keys agree with EACH OTHER on most
            // inputs, two programs outvote one model's guesses (N-version programming). Otherwise fall back to blind Fi.
            emit(.note("Fi: the answer key disagrees with \(drop.count) of \(ran) checks; writing a second, independent key to break the tie"))
            let reply2 = await ask([.init(role: .system, content: "You are a careful Python programmer. Read the task word by word."),
                                    .init(role: .user, content: "TASK: \(task)\n\nWrite a small, independent Python 3 program (standard library only) that behaves exactly as the TASK says (same input, same printed output, same exit codes; for a Swift task, write its Python equivalent). Count characters, lines and words with code, never by hand. Reply with only:\n<python>\n...program...\n</python>")],
                                   phase: "fi-answer-key-2", maxTokens: 2000)
            var trusted = false
            if let code2 = allMatches(#"<python>\s*([\s\S]*?)</python>"#, reply2).first, !code2.isEmpty {
                let s1 = dir + "/.teti/keyrun", s2 = dir + "/.teti/keyrun2"
                for (sd, cd) in [(s1, code), (s2, code2)] {
                    try? FileManager.default.removeItem(atPath: sd)
                    try? FileManager.default.createDirectory(atPath: sd + "/.teti", withIntermediateDirectories: true)
                    try? cd.write(toFile: sd + "/.teti/answer_key.py", atomically: true, encoding: .utf8)
                }
                var same = 0, both = 0
                for j in jobs where !j.passOnly {
                    let (r1, o1) = Sandbox.run(s1, j.run, timeout: 20), (r2, o2) = Sandbox.run(s2, j.run, timeout: 20)
                    if (r1 != 0 && o1.isEmpty) || (r2 != 0 && o2.isEmpty) { continue }
                    both += 1; if Self.norm(o1) == Self.norm(o2) { same += 1 }
                }
                try? FileManager.default.removeItem(atPath: s1); try? FileManager.default.removeItem(atPath: s2)
                trusted = both >= 2 && same * 10 >= both * 8
                emit(.note("Fi: the two keys agree with each other on \(same) of \(both) inputs" + (trusted ? ", so the keys win over Te's expected answers" : ", so neither is trusted; using blind Fi")))
            }
            if !trusted { return await fiPreAudit(task: task, checks: checks) }
        }
        for (n, w, g) in drop {
            emit(.note("Answer key: '\(n)' Te expects \"\(w.prefix(80))\" but the answer key prints \"\(g.prefix(80))\", check dropped"))
        }
        emit(.note("Answer key: agrees with \(agree) of \(ran) checks" + (drop.isEmpty ? "" : ", dropped \(drop.count)")))
        keyCode = code
        let names = Set(drop.map { $0.0 })
        let kept = checks.filter { !names.contains($0.name) }
        return kept.isEmpty ? checks : kept
    }

    /// Late checks (gate5v3 task 3, 11/16): Ne's "break-float-sum" expected 4.0 against the task's "integer if whole", was
    /// added AFTER the answer key ran, and pushed Ti into printing 21.0 = a false win. Every check added later (Ne, Te add)
    /// now goes through the input check and the same trusted key. No model call: the key program is reused.
    func lateCheck(_ checks: [Check], who: String) -> [Check] {
        var cs = dropBrokenInputs(checks)
        guard let code = keyCode, !cs.isEmpty,
              let rx = try? NSRegularExpression(pattern: #"out=\$\(\s*((?:python3\s+\S+\.py)|(?:swift\s+run\s+(?:-q\s+)?\S+)|(?:swift\s+\S+\.swift)|(?:\.build/\S+)|(?:\./\S+))((?:"[^"]*"|'[^']*'|[^)"'])*)\)([\s\S]*?)test\s+"\$out"\s+=\s+"([^"]*)""#) else { return cs }
        let scratch = dir + "/.teti/keyrun-late"
        try? FileManager.default.removeItem(atPath: scratch)
        try? FileManager.default.createDirectory(atPath: scratch + "/.teti", withIntermediateDirectories: true)
        try? code.write(toFile: scratch + "/.teti/answer_key.py", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        cs = cs.filter { c in
            if !c.command.contains("$?"), let ej = Self.expectJob(c) {
                let (rc, out) = Sandbox.run(scratch, ej.run, timeout: 20)
                if (rc != 0 && out.isEmpty) || out.hasPrefix("zsh:") { return true }
                if Self.norm(out) == Self.norm(ej.want) { return true }
                emit(.note("Answer key (\(who)): '\(c.name)' expects \"\(ej.want.prefix(80))\" but the key prints \"\(Self.norm(out).prefix(80))\", check dropped"))
                return false
            }
            if !c.command.contains("$?"), c.expect?.isEmpty ?? true, !c.command.contains("out=$("), let sw = Self.swapJob(c) {
                let (rc, out) = Sandbox.run(scratch, sw, timeout: 20)
                if rc == 0 || (out.contains("answer_key.py") && out.contains("Traceback")) { return true }
                emit(.note("Answer key (\(who)): '\(c.name)' fails even with the answer key standing in for the program, check dropped"))
                return false
            }
            let cmd = c.command
            guard !cmd.contains("$?"), let m = rx.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
                  let ar = Range(m.range(at: 2), in: cmd), let wr = Range(m.range(at: 4), in: cmd), let whole = Range(m.range, in: cmd),
                  !cmd[ar].contains("|") else { return true }
            let run = String(cmd[..<whole.lowerBound]) + "python3 -I .teti/answer_key.py" + cmd[ar] + " 2>/dev/null"
            let (rc, out) = Sandbox.run(scratch, run, timeout: 20)
            if (rc != 0 && out.isEmpty) || out.hasPrefix("zsh:") { return true }   // key crashed / shell error: no vote
            let got = out.trimmingCharacters(in: .newlines)
            let want = String(cmd[wr]).replacingOccurrences(of: "\\n", with: "\n").trimmingCharacters(in: .newlines)
            if got == want { return true }
            emit(.note("Answer key: \(who)'s '\(c.name)' expects \"\(want.prefix(80))\" but the answer key prints \"\(got.prefix(80))\", check dropped"))
            return false
        }
        return cs
    }

    /// Fi answers BLIND before Ti codes (gate1/gate2 task 3, 11/16): shown Te's checks, Fi agreed "4.0" was right twice
    /// (it was 1.5). Now Fi never sees Te's expected answer: code hides it, Fi works the answer out from the task, and code
    /// compares. Disagree = the check is dropped (a wrong check is worse than a missing one: it makes false wins).
    func fiPreAudit(task: String, checks: [Check]) async -> [Check] {
        guard let rx = try? NSRegularExpression(pattern: #"test\s+"\$out"\s+=\s+"([^"]*)""#) else { return checks }
        var hidden: [(name: String, shown: String, want: String)] = []
        for c in checks {
            let cmd = c.command
            let ms = rx.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd))
            guard ms.count == 1, let r = Range(ms[0].range(at: 1), in: cmd), let whole = Range(ms[0].range, in: cmd) else { continue }
            hidden.append((c.name, cmd.replacingCharacters(in: whole, with: "test \"$out\" = \"???\""), String(cmd[r])))
        }
        guard !hidden.isEmpty else { return checks }
        emit(.phase("Fi: works out \(hidden.count) expected answer(s) blind, before Ti starts", loop: 0))
        let list = hidden.map { "[\($0.name)] \($0.shown)" }.joined(separator: "\n")
        let msgs: [BrainMessage] = [.init(role: .system, content: "You are Fi, the fairness judge of Code Smash TeTi. You follow the TASK text exactly."),
                                    .init(role: .user, content: """
            TASK: \(task)

            Each command below runs a CORRECT program and compares its output to ???.
            \(list)

            For each one, work out from the TASK words only exactly what a correct program prints there (follow the task's FORMAT
            words: integer vs decimal, decimals, order, ties). CALCULATOR: never do arithmetic in your head; if you need math,
            reply FIRST with only <calc>python expression</calc> lines and stop.
            Then reply one line per check: <answer name="check-name">exact printed text</answer>
            """)]
        var reply = await ask(msgs, phase: "fi-blind", maxTokens: 1200)
        let calcs = Array(allMatches(#"<calc>(.*?)</calc>"#, reply).prefix(16))
        if !calcs.isEmpty {
            let answers = calcs.map { e -> String in
                let py = "print(eval(" + Self.pyString(e) + ", {'__builtins__': {}}, {'len': len, 'sum': sum, 'range': range, 'min': min, 'max': max, 'abs': abs, 'divmod': divmod, 'str': str, 'list': list, 'sorted': sorted, 'round': round, 'int': int, 'float': float}))"
                let (code, out) = Sandbox.run(dir, "python3 -I -c " + Self.shellQuote(py), timeout: 5)
                return e + " = " + (code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : "(error)")
            }
            emit(.note("Fi: used the calculator: " + answers.joined(separator: " · ").prefix(300)))
            reply = await ask(msgs + [.init(role: .assistant, content: reply),
                                      .init(role: .user, content: "EXACT ANSWERS (computed, trust them):\n" + answers.joined(separator: "\n") + "\nNow give every <answer>.")],
                              phase: "fi-blind-calc", maxTokens: 1200)
        }
        let fiSays = Dictionary(allMatchPairs(#"<answer\s+name="([^"]+)"\s*>(.*?)</answer>"#, reply), uniquingKeysWith: { a, _ in a })
        var drop = Set<String>()
        for h in hidden {
            guard let f = fiSays[h.name]?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }   // no answer = no vote
            if f != h.want {
                drop.insert(h.name)
                emit(.note("Fi (blind): '\(h.name)' Te expects \"\(h.want)\" but the task gives \"\(f)\", check dropped"))
            }
        }
        if drop.isEmpty { emit(.note("Fi (blind): agrees with all \(hidden.count) expected answers")) }
        let kept = checks.filter { !drop.contains($0.name) }
        return kept.isEmpty ? checks : kept
    }

    func fiJudge(task: String, flagged: [(check: Check, ok: Bool, output: String)]) async -> (fixes: [Check], upheld: String) {
        emit(.phase("Fi: is Ti right that a check contradicts the task?", loop: 0))
        let report = flagged.map { r in
            "[\(r.check.name)] \(r.check.command)" + (r.check.expect.map { " (expect: \($0))" } ?? "") +
            computerCount(r.check.command) +
            "\nTI SAYS: \(String((tiFlags[r.check.name] ?? "").prefix(500)))\nREAL OUTPUT:\n\(String(r.output.suffix(500)))"
        }.joined(separator: "\n\n")
        let fiMsgs: [BrainMessage] = [.init(role: .system, content: "You are Fi, the fairness judge of Code Smash TeTi. You side with the TASK text, not with Te or Ti."),
                               .init(role: .user, content: """
            TASK: \(task)

            Ti, the builder, says these checks contradict the task:
            \(report)

            For each one, work it out by hand from the TASK text: take the exact input the check uses and compute, step by step,
            what a correct program must output (count words, lines, characters one by one). Then compare with what the check expects.
            - If the check expects something the task does NOT require (a wrong count, a wrong definition), it is unfair: reply with a
              corrected <check name="same-name">command</check> that tests the SAME requirement with the right expected answer.
            - If the check is right and Ti is wrong, reply <fair name="same-name">one sentence: why the task requires it</fair>.
            Never drop or weaken a real requirement.
            CALCULATOR: never do arithmetic in your head. If a ruling depends on any math (remainders, sums, lengths, what the last
            line of a range is), reply FIRST with only <calc>python expression</calc> lines, e.g. <calc>1000000 % 3</calc>, and stop.
            You will get the exact answers back, then rule. The calculator gives the VALUE; how it must be PRINTED follows the
            task's own words (exam task 3, 11/11: "as an integer if the sum is a whole number" means 1.5 + 2.5 prints 4, not 4.0).
            """)]
        var reply = await ask(fiMsgs, phase: "fi-judge", maxTokens: 1200)
        // Fi's math calculator (9B exam task 1, 11/11): Ne's check said the last line for N=1000000 is FizzBuzz; 1000000 % 3 == 1,
        // so it's Buzz, and Fi ruled it fair. Run Fi's <calc> requests for real, then let it rule with the answers.
        let calcs = Array(allMatches(#"<calc>(.*?)</calc>"#, reply).prefix(12))
        if !calcs.isEmpty {
            let answers = calcs.map { e -> String in
                let py = "print(eval(" + Self.pyString(e) + ", {'__builtins__': {}}, {'len': len, 'sum': sum, 'range': range, 'min': min, 'max': max, 'abs': abs, 'divmod': divmod, 'str': str, 'list': list, 'sorted': sorted}))"
                let (code, out) = Sandbox.run(dir, "python3 -I -c " + Self.shellQuote(py), timeout: 5)
                return e + " = " + (code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : "(error)")
            }
            emit(.note("Fi: used the calculator: " + answers.joined(separator: " · ").prefix(300)))
            reply = await ask(fiMsgs + [.init(role: .assistant, content: reply),
                                        .init(role: .user, content: "EXACT ANSWERS (computed, trust them):\n" + answers.joined(separator: "\n") + "\nNow rule on every check.")],
                              phase: "fi-judge-calc", maxTokens: 1200)
        }
        let names = Set(flagged.map { $0.check.name })
        fiJudged.formUnion(names)
        let proposed = parseChecks(reply).filter { names.contains($0.name) && Sandbox.run(dir, "zsh -n -c " + Self.shellQuote($0.command), timeout: 10).0 == 0 }
        // Test the judge's fix before trusting it (user, exam task 12, 11/11): Fi "corrected" 30 checks and every one failed
        // next round with the same "no such file" error. A fix that fails exactly like the original changed nothing.
        func same(_ a: String) -> String { a.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        let before = Dictionary(flagged.map { ($0.check.name, same($0.output)) }, uniquingKeysWith: { a, _ in a })
        let tried = runChecks(proposed, in: dir, emitting: false)
        let fixes = tried.filter { $0.ok || same($0.output) != before[$0.check.name] }.map(\.check)
        let dud = tried.filter { !$0.ok && same($0.output) == before[$0.check.name] }
        if !dud.isEmpty {
            emit(.note("Fi: tested \(dud.count) of its own fix(es) and they fail exactly like before, so they're dropped (the problem isn't the expected answer)"))
        }
        let fair = allMatchPairs(#"<fair\s+name="([^"]+)"\s*>(.*?)</fair>"#, reply).filter { names.contains($0.0) && !fixes.map(\.name).contains($0.0) }
        let upheld = fair.map { "FI RULED check '\($0.0)' is FAIR to the task: \($0.1.trimmingCharacters(in: .whitespacesAndNewlines)) Fix the program, not the check." }.joined(separator: "\n")
        return (fixes, upheld)
    }

    /// Fi's calculator (user, exam task 12, 11/11): Te wrote "chars 16" for alpha⏎beta⏎gamma⏎ (really 17) and "longest gamma"
    /// (a tie, so the first one, alpha, wins), and Fi ruled it fair. Models guess counts; the computer doesn't. Count the
    /// check's printf input for real and hand Fi the facts.
    func computerCount(_ cmd: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: #"\bprintf\s+(?:'%b'\s+)?('(?:[^']*)')"#),
              let m = rx.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
              let a = Range(m.range(at: 1), in: cmd) else { return "" }
        let py = #"import sys; d=sys.stdin.buffer.read(); t=d.decode('utf-8','replace'); w=t.split(); lw=max(w,key=len) if w else ''; nl=t.count('\n'); print(f"characters (every one, newlines included): {len(t)} | bytes: {len(d)} | newline characters: {nl} | lines (a last line without a newline still counts): {nl + (1 if t and not t.endswith(chr(10)) else 0)} | words (split on spaces/newlines): {len(w)} | longest word (first one wins a tie): {lw!r}")"#
        let (code, out) = Sandbox.run(dir, "printf " + cmd[a] + " | python3 -c " + Self.shellQuote(py), timeout: 10)
        guard code == 0, !out.isEmpty else { return "" }
        return "\nCOMPUTER COUNT of this check's input (exact, measured by running it; trust it over any count done in your head): " +
            out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep the best version (exam task 12, 11/10: the code scored 4/5 at 20:02 and ended at 3/5). On an unsolved finish,
    /// grade the saved best copy with today's checks; if it beats the current code, put it back.
    /// Re-grade every saved version (exam task 3, 11/11: the fast-path draft was correct, but a wrong check scored it low,
    /// the loop "fixed" it into a wrong program, and the single best copy had been picked with those wrong checks).
    /// On an unsolved finish, every version is graded with the FINAL checks; the top one goes back (a tie keeps the newer).
    func restoreBest(_ checks: [Check], current: Int) -> Int {
        let fm = FileManager.default
        var places = versionTags.suffix(12).map { (name: $0, path: dir + "/.teti/versions/" + $0) }
        if fm.fileExists(atPath: dir + "/.teti/best") { places.insert((name: "best", path: dir + "/.teti/best"), at: 0) }
        var top: (name: String, path: String, p: Int, r: [(check: Check, ok: Bool, output: String)])? = nil
        for v in places where fm.fileExists(atPath: v.path) {
            let r = runChecks(checks, in: v.path, emitting: false)
            let p = r.filter { $0.ok }.count
            if top == nil || p >= top!.p { top = (v.name, v.path, p, r) }
        }
        guard let t = top, t.p > current else { return current }
        replaceProject(dir, with: t.path)
        lastOk = Dictionary(t.r.map { ($0.check.name, $0.ok) }, uniquingKeysWith: { a, _ in a })
        emit(.note("Se: re-graded \(places.count) saved versions with the final checks; '\(t.name)' scores \(t.p)/\(checks.count) vs \(current) for the last one, so it goes back"))
        return t.p
    }

    /// Save the code as it is now, once per distinct version (no .build, it rebuilds).
    func saveVersion(_ tag: String) {
        let snap = seSnapshot(dir)
        let fp = snap.keys.sorted().map { $0 + "\u{0}" + snap[$0]! }.joined(separator: "\u{1}").hashValue
        guard !snap.isEmpty, !versionPrints.contains(fp) else { return }
        versionPrints.insert(fp); versionTags.append(tag)
        let to = dir + "/.teti/versions/" + tag
        try? FileManager.default.removeItem(atPath: to)
        try? FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: true)
        for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where item != ".teti" && item != ".build" {
            try? FileManager.default.copyItem(atPath: dir + "/" + item, toPath: to + "/" + item)
        }
    }

    /// A Python string literal for any text (JSON strings are valid Python literals).
    nonisolated static func pyString(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "''"
    }

    nonisolated static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Ne → Te before "solved" (user, 11/10; false wins on tasks 3 and 6): when every check passes, Ne asks "what could
    /// break this?" and writes a few hard cases straight from the task text. They join the exam for good; if any fails,
    /// it isn't solved yet. Runs once per task, so it costs one short model call.
    func neTryToBreak(task: String, checks: [Check]) async -> (extra: [Check], broke: [(check: Check, ok: Bool, output: String)]) {
        emit(.phase("Ne: what could break this?", loop: 0))
        let reply = await ask([.init(role: .system, content: "You are Ne, the what-if explorer of Code Smash TeTi. Your job now: break the program before the real users do."),
                               .init(role: .user, content: """
            TASK: \(task)

            The program passes these checks:
            \(checks.map { "- \($0.name): \($0.command)" }.joined(separator: "\n"))

            FE SAYS, think like the person who will use this: what would a real user actually type, in what order, and what
            would they expect to see? Prefer the mistakes and cases real people hit over clever ones nobody would.
            Go through the TASK text requirement by requirement. Where the checks test a requirement only once or only the easy
            way, write a check that tries to break it: other positions, combinations, edge values (e.g. a minus sign in
            front of a number in different places, nested or empty input, the largest/smallest case the task allows).
            Only test what the TASK text actually requires. Work out each expected output carefully by hand.
            SE SAYS, look at what's already here: each check runs in a fresh copy of the folder exactly as it is now, and it
            contains: \(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted().joined(separator: ", ")).
            If the program saves data (a .json, .txt, .db file), that file may already hold entries from earlier runs: any check
            that depends on what's stored must start clean first (e.g. rm -f todo.json && ...), or its expected output is wrong.
            FI SAYS, be fair: every check must quote, in cite="...", the exact words of the TASK sentence it tests. If you can't
            quote the task for a case (e.g. the task never mentions negative numbers), the case isn't required: leave it out.
            Reply with at most 4 checks, each as <check name="break-..." cite="exact words from the TASK">shell command that exits 0 only when correct</check>.
            If the checks already cover everything hard, reply NONE.
            """)], phase: "ne-break", maxTokens: 700)
        let names = Set(checks.map { $0.name })
        // Fi's quote gate (task 11, 11/10): a break test whose cite isn't really in the task text is dropped, no model call.
        let cites = Dictionary(allMatchPairs(#"<check\s+name="([^"]+)"\s+cite="([^"]*)""#, reply), uniquingKeysWith: { a, _ in a })
        let extraRaw = Array(parseChecks(reply).filter { c in
            guard !names.contains(c.name), Sandbox.run(dir, "zsh -n -c " + Self.shellQuote(c.command), timeout: 10).0 == 0 else { return false }
            guard Self.citeInTask(cites[c.name], task) else { emit(.note("Fi: dropped Ne's '\(c.name)', its quote \"\(cites[c.name] ?? "none")\" isn't in the task")); return false }
            return true
        }.prefix(4))
        let extra = lateCheck(Array(extraRaw), who: "Ne")
        guard !extra.isEmpty else { emit(.note("Ne: couldn't find a way to break it")); return ([], []) }
        let results = runChecks(extra, in: dir, emitting: true)
        let broke = results.filter { !$0.ok }
        emit(.note(broke.isEmpty ? "Ne tried \(extra.count) ways to break it: it held" : "Ne broke it \(broke.count) way(s) out of \(extra.count)"))
        return (results.map { $0.check }, broke)
    }

    /// The false-win guard as one step, used on EVERY route to "solved" (task 9 slipped past it via Te's repair route).
    /// Returns feedback for Ti if Ne broke the program with a fair test, nil if it held.
    func neGate(task: String, checks: inout [Check]) async -> String? {
        var (extra, broke) = await neTryToBreak(task: task, checks: checks)
        if !broke.isEmpty {
            let fair = await teAuditChecks(task: task, results: broke, tiSays: lastTiFinal)
            if !fair.isEmpty {
                for f in fair { if let i = extra.firstIndex(where: { $0.name == f.name }) { extra[i] = f } }
                emit(.note("Fi: \(fair.count) of Ne's break test(s) weren't fair to the task, repaired"))
                broke = runChecks(extra, in: dir, emitting: true).filter { !$0.ok }
            }
        }
        checks += extra
        guard !broke.isEmpty else { return nil }
        return "NE TRIED TO BREAK IT and found real gaps (the task text requires these; if a check is wrong, say why):\n" + (await teVerdict(task: task, results: broke))
    }

    func teAddCheck(task: String, checks: [Check]) async -> Check? {
        let reply = await ask([.init(role: .system, content: Self.tePersona),
                               .init(role: .user, content: "TASK: \(task)\nCURRENT CHECKS:\n" + checks.map { "- \($0.name): \($0.command)" }.joined(separator: "\n") +
                                     "\n\nIs an important requirement of the task NOT covered? If yes, reply with ONE <check name=\"...\">command</check>. If not, reply NONE.")],
                              phase: "te-add", maxTokens: 400)
        return parseChecks(reply).first.flatMap { c in checks.contains { $0.name == c.name } ? nil : lateCheck([c], who: "Te").first }
    }

    // MARK: Ti

    /// One Ti phase: build/fix with up to 8 inner rounds of writing files and running commands.
    func tiBuild(task: String, checks: [Check], feedback: String, knowledge: String, in where_: String, steer: String?) async -> String {
        // CLEAN CONTEXT (user 11/16: "it gets hung up... then starts making simple errors"): the full journal grew 2 lines
        // per round (up to 15  'done' lines with code-change dumps + the whole plan again) and all of it went back to Ti.
        // Now Ti sees only the last 2 steps; the checks, the files and Te's current findings are in the message anyway.
        let jr = await si.journal(project)
        let journal = ProcessInfo.processInfo.environment["TETI_FULL_JOURNAL"] != nil ? jr.briefing :
            (jr.done.isEmpty ? "" : "LAST STEPS (\(project)):\n" + jr.done.suffix(2).map { "- " + String($0.prefix(300)) }.joined(separator: "\n")) + factsCell(jr)
        var msgs: [BrainMessage] = [
            // Only what stays the same for the whole task goes in the system message, so the engine's prompt memory can reuse
            // it across every loop and Ne path. The journal changes after each check, so it rides in the user message (11/10).
            .init(role: .system, content: Self.tiPersona + "\n" + Values.preamble + "\n\n" + Self.tiTools + "\n\n" + knowledge),
            // PROMPT MEMORY ORDER (user 11/16): what stays the same across rounds (task, checks) comes first, so the engine
            // reuses it; what changes every round (last steps, facts cell, files, findings) goes last. Only 30% of prompt
            // tokens were being reused before.
            .init(role: .user, content: """
            TASK: \(task)

            Te will judge your work ONLY by these checks (you can't change them):
            \(checks.map { "- \($0.name): \($0.command)" + ($0.expect.map { "  → output must contain: \($0)" } ?? "") }.joined(separator: "\n"))

            \(journal)

            Files now: \(listing(where_))
            \(feedback.isEmpty ? "" : "\nTe's findings from the last check — fix these:\n\(feedback)\n")
            \(steer.map { "\nUse THIS approach: \($0)\n" } ?? "")
            Build it now. Test with <run> before finishing.
            """)]
        var approach = ""
        let buildStart = Date()
        for round in 0..<8 {
            if round > 0 {
                let build = Date().timeIntervalSince(buildStart) / 60, total = Date().timeIntervalSince(taskStart) / 60
                if build > Self.buildCapMinutes || total > Self.timeBudgetMinutes {
                    emit(.note(String(format: "Se → Ti: this build has run %.0f min (cap %.0f, task %.0f of %.0f), stop and let Te check what's there",
                                      build, Self.buildCapMinutes, total, Self.timeBudgetMinutes)))
                    break
                }
            }
            let reply = await ask(msgs, phase: "ti-\(round)", maxTokens: 6000)
            msgs.append(.init(role: .assistant, content: reply))
            var results: [String] = []
            var written: [String] = []
            for (path, body) in parseWrites(reply) {
                guard let p = Sandbox.inside(where_, path) else { results.append("[write \(path)] refused: outside the project folder"); continue }
                try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if (try? body.write(toFile: p, atomically: true, encoding: .utf8)) != nil {
                    files.insert(String(p.dropFirst(where_.count + 1))); written.append(p); results.append("[write \(path)] saved (\(body.count) chars)")
                } else { results.append("[write \(path)] FAILED") }
            }
            let runs = parseRuns(reply)
            for cmd in runs.prefix(4) {
                let (code, out) = Sandbox.run(where_, cmd)
                results.append("[run] \(cmd)\nexit \(code)\n\(out.isEmpty ? "(no output)" : out)")
                if code != 0 {
                    let errs = out.split(separator: "\n").filter { $0.contains("error:") }.prefix(3).joined(separator: "\n")
                    if !errs.isEmpty && !mistakes.contains(errs) { mistakes.append(String(errs.suffix(600))) }
                }
            }
            if let a = firstMatch(#"<approach>(.*?)</approach>"#, reply) { approach = a.trimmingCharacters(in: .whitespacesAndNewlines) }
            for (name, why) in allMatchPairs(#"<wrong_check\s+name="([^"]+)"\s*>(.*?)</wrong_check>"#, reply) where checks.contains(where: { $0.name == name }) {
                if tiFlags[name] == nil { emit(.note("Ti flagged check '\(name)' as contradicting the task, Fi will judge")) }
                tiFlags[name] = why.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let r = reply.range(of: Self.doubtPattern, options: .regularExpression) {
                let lo = reply.index(r.lowerBound, offsetBy: -250, limitedBy: reply.startIndex) ?? reply.startIndex
                let hi = reply.index(r.upperBound, offsetBy: 250, limitedBy: reply.endIndex) ?? reply.endIndex
                tiDoubt = String(reply[lo..<hi])
            }
            // Se checks the syntax of every file Ti just wrote (80B task 1, 11/10: an unfinished `if i` line cost 80+ min).
            let broken = Self.syntaxErrors(written, in: where_)
            for b in broken { results.append("[syntax check] " + b) }
            if !broken.isEmpty { emit(.note("Se: \(broken.count) file(s) Ti wrote don't parse, sent straight back to Ti")) }
            if runs.isEmpty && broken.isEmpty { lastTiFinal = reply; break }            // Ti says it's done building
            if runs.isEmpty { msgs.append(.init(role: .user, content: results.joined(separator: "\n\n") + "\n\nSE: these files don't even parse, so no check can pass. Fix the syntax error first, rewrite the whole file with <write_file>, then finish.")); continue }
            msgs.append(.init(role: .user, content: results.joined(separator: "\n\n") + "\n\nContinue. When done, reply with no <run> and end with <approach>…</approach>."))
        }
        return approach.isEmpty ? "(no approach stated)" : approach
    }

    /// FACTS CELL (user 11/16: "an extra memory cell... better at checking for small changes like the .build vs /build
    /// problem"). Built by CODE, never summarized by the model: a model summary is exactly where '.build' turns into
    /// 'build'. Exact error lines already hit and approaches already tried, deduped and capped (~1.5k chars), so the old
    /// rounds can be dropped from the context without losing the small details.
    func factsCell(_ jr: ProjectJournal) -> String {
        var out = ""
        let errs = Array(NSOrderedSet(array: mistakes.reversed()).array.compactMap { $0 as? String }.prefix(3))
        if !errs.isEmpty { out += "\n\nEXACT ERRORS ALREADY HIT ON THIS TASK (copied, not summarized; check paths and names character by character):\n" + errs.map { "- " + String($0.prefix(300)) }.joined(separator: "\n") }
        let tried = Array(NSOrderedSet(array: jr.decisions.reversed()).array.compactMap { $0 as? String }.prefix(4))
        if !tried.isEmpty { out += "\nAPPROACHES ALREADY TRIED (don't repeat one that didn't raise the score):\n" + tried.map { "- " + String($0.prefix(160)) }.joined(separator: "\n") }
        return out
    }

    // MARK: Ne

    /// "What if": propose different approaches, try each in its own sandbox copy, keep the one Te scores best.
    // Se ⇄ Ne (user, 11/10: "ne and se need to communicate so ne does not spend too long"): Se tells Ne how much time is
    // left before it brainstorms; after every path Ne reports back (time spent, score) and Se decides: go on, or stop.
    func neBranch(task: String, checks: [Check], feedback: String, knowledge: String, current: Int, startedAt t0: Date) async -> String? {
        let budget = Self.timeBudgetMinutes
        func minutesLeft() -> Double { budget - Date().timeIntervalSince(t0) / 60 }
        let left0 = minutesLeft()
        emit(.note(String(format: "Se → Ne: %.0f min left in the budget", max(0, left0))))
        guard left0 > 5 else { emit(.note("Se: not enough time left for new paths, Ne stands down")); return nil }
        let reply = await ask([.init(role: .system, content: "You are Ne, the what-if explorer of Code Smash TeTi. Propose genuinely different ways to solve the task.\nEvery idea must work offline on a standard Mac with NO extra packages: Python's standard library only (no pandas, numpy, requests), swiftc, zsh, BSD tools."),
                               .init(role: .user, content: "TASK: \(task)\nThe current approach is stuck. Te says:\n\(feedback)\n\n" +
                                     String(format: "Se says: about %.0f minutes are left, so prefer ideas that fix the failing checks with a small change over full rewrites.\n", left0) +
                                     (neTried.isEmpty ? "" : "Si says you ALREADY TRIED these on this task, none won. Do not repeat them or minor variations:\n" + neTried.map { "- " + String($0.prefix(160)) }.joined(separator: "\n") + "\n") +
                                     "Brainstorm: ask what if…? Give 2-3 DIFFERENT approaches, one per line, each as <idea>…</idea>.")],
                              phase: "ne", maxTokens: 600)
        // Remembered breakthroughs on similar walls go first (strongest first), then fresh brainstorm ideas.
        let past = await ni.recall("stuck breakthrough " + task + " " + feedback, limit: 3).filter { $0.tags.contains("breakthrough") }
        if !past.isEmpty { emit(.note("Ne remembers \(past.count) breakthrough(s) from similar walls")) }
        let remembered = past.compactMap { $0.text.components(separatedBy: "→ breakthrough: ").last }
        let ideas = Array((remembered.prefix(1) + allMatches(#"<idea>(.*?)</idea>"#, reply)).prefix(3))
        guard !ideas.isEmpty else { return nil }
        emit(.phase("Ne: trying \(ideas.count) different paths", loop: 0))
        let base = dir + "/.teti/branches"
        try? FileManager.default.removeItem(atPath: base)
        var bestScore = current, bestIdea: String?, bestDir: String?, ties = 0
        for (i, idea) in ideas.enumerated() {
            let left = minutesLeft()
            if left <= 0 { emit(.note("Se: the time budget is used up, Ne stops before path \(i + 1)")); break }
            if i > 0 && ties >= 2 { emit(.note("Se: two paths in a row tied the old score, so this wall isn't about the approach. Ne stops")); break }
            let share = left / Double(ideas.count - i)
            emit(.note(String(format: "Se → Ne: path %d gets about %.0f min", i + 1, share)))
            let tPath = Date()
            let b = base + "/\(i + 1)"
            copyProject(from: dir, to: b)
            emit(.branch("path \(i + 1): \(idea)"))
            neTried.append(idea)
            _ = await tiBuild(task: task, checks: checks, feedback: feedback, knowledge: knowledge, in: b, steer: idea)
            let score = runChecks(checks, in: b, emitting: false).filter { $0.ok }.count
            let spent = Date().timeIntervalSince(tPath) / 60
            emit(.note(String(format: "path %d scored %d/%d · Ne → Se: took %.0f min", i + 1, score, checks.count, spent)))
            ties = score <= current ? ties + 1 : 0
            if score > bestScore { bestScore = score; bestIdea = idea; bestDir = b }
            if spent > share * 1.5 && score <= current { emit(.note("Se: that path ran well over its share with no gain, Ne stops")); break }
            if score == checks.count { break }
        }
        guard let w = bestDir, let idea = bestIdea else { emit(.note("Ne: no path beat the current one")); return nil }
        emit(.note("Ne: path '\(idea)' wins (\(bestScore)/\(checks.count)), adopting it"))
        replaceProject(dir, with: w)
        if let old = past.first(where: { $0.text.hasSuffix(idea) }) {
            await ni.reinforce(old.id, success: true)
            emit(.note("Ni: remembered breakthrough worked again, strengthened"))
        } else {
            let wall = feedback.split(separator: "\n").first.map(String.init) ?? "a failing check"
            let words = (task + " " + wall).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 }
            if let id = await ni.learn("When stuck on: \(wall.prefix(160)) → breakthrough: \(idea)",
                                       tags: ["breakthrough", "stuck"] + Array(Set(words)).sorted(),
                                       verifiedBy: "Ne branch scored \(bestScore)/\(checks.count) vs \(current) before") {
                await ni.reinforce(id, success: true)   // breakthroughs start stronger than ordinary insights
                emit(.note("Ni: new breakthrough remembered"))
                await track.update { $0.breakthroughs += 1; $0.points += 3 }
                emit(.note("⭐ +3: breakthrough found"))
            }
        }
        for p in past where !p.text.hasSuffix(idea) { await ni.reinforce(p.id, success: false) }
        return idea
    }

    // MARK: Ni learning (only Te-verified results go in)

    func learn(task: String, approach: String, checks: [Check], recalled: [Insight]) async {
        for r in recalled { await ni.reinforce(r.id, success: true) }
        let tags = task.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 }
        var approach = approach
        if approach == "(no approach stated)" {   // ask Ti to name what worked, so the win is never lost
            let files = self.files.sorted().prefix(6).map { f -> String in
                "--- \(f)\n" + String(((try? String(contentsOfFile: dir + "/" + f, encoding: .utf8)) ?? "").prefix(1500)) }.joined(separator: "\n")
            approach = await ask([.init(role: .system, content: Self.tiPersona),
                                  .init(role: .user, content: "TASK: \(task)\nYour working solution:\n\(files)\n\nIn ONE line, the key technique that made it work (reusable for similar tasks). No code.")],
                                 phase: "ti-summary", maxTokens: 150).trimmingCharacters(in: .whitespacesAndNewlines)
            if approach.isEmpty { approach = "(no approach stated)" }
        }
        if approach != "(no approach stated)" {
            await ni.learn("For a task like \"\(task.prefix(120))\": \(approach)", tags: Array(Set(tags)).sorted(),
                           verifiedBy: "Te checks passed: " + checks.map { $0.name }.joined(separator: ", "))
            emit(.note("Ni learned a verified approach"))
        }
        await learnNevers(task: task, recalledNevers: [])
    }

    /// Ti hit errors and still got Te to pass → each fixed error becomes one short, general NEVER/INSTEAD rule.
    func learnNevers(task: String, recalledNevers: [Insight]) async {
        guard !mistakes.isEmpty else { return }
        let langs = Self.languagesIn(task + " " + files.joined(separator: " "))
        let code = files.sorted().prefix(4).map { f in "--- \(f)\n" + String(((try? String(contentsOfFile: dir + "/" + f, encoding: .utf8)) ?? "").prefix(2000)) }.joined(separator: "\n")
        for err in mistakes.prefix(3) {
            let reply = await ask([.init(role: .user, content: """
                While building, this error happened:
                \(err)

                The final code that passed every check:
                \(code)

                Write ONE general rule so this never happens again, in EXACTLY this form (one line, no preamble):
                NEVER: <the thing that caused the error> → INSTEAD: <what works, as in the final code>
                If the error was not caused by a reusable coding mistake, reply NONE.
                """)], phase: "ni-never", maxTokens: 120)
            let line = (reply.components(separatedBy: "</think>").last ?? reply).trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? ""
            guard line.hasPrefix("NEVER:"), line.contains("INSTEAD:"), line.count < 300 else { continue }
            let words = line.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 4 }
            await ni.learn(line, tags: Array(Set(["rule", "never"] + (langs.isEmpty ? ["any"] : langs) + words.prefix(6))).sorted(),
                           verifiedBy: "error fixed, then Te checks passed: " + String(err.prefix(160)), kind: "never")
            emit(.note("Ni learned a hard rule: \(line.prefix(140))"))
        }
    }

    // MARK: reward

    /// Doing something right is rewarded: points, a growing streak bonus, stronger memories of what worked (Ni), and the
    /// winning run saved as a training example, so later self-training learns from verified wins only.
    func reward(_ base: Int, _ why: String, solved: Bool, firstTry: Bool) async {
        var bonus = 0
        await track.update { r in
            r.solved += 1; if firstTry { r.solvedFirstTry += 1 }
            r.streak += 1; r.bestStreak = max(r.bestStreak, r.streak)
            bonus = min(r.streak - 1, 5)
            r.points += base + bonus
        }
        emit(.note("⭐ +\(base + bonus): \(why)" + (bonus > 0 ? " (incl. +\(bonus) streak bonus)" : "")))
        let dir = BrainPaths.memory.appendingPathComponent("rewards")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.copyItem(atPath: self.dir + "/.teti/transcript.jsonl",
                                          toPath: dir.appendingPathComponent("\(stamp)-\(project).jsonl").path)
    }

    // MARK: pain memory

    /// A failure is remembered as an "avoid" lesson backed by the real failing output, so it's never repeated blindly.
    func rememberPain(task: String, feedback: String, results: [(check: Check, ok: Bool, output: String)]) async {
        guard let firstFail = results.first(where: { !$0.ok }) else { return }
        // Skip Se's own lines (time left, what changed, circles): they change every loop, so saving them made a "new" lesson
        // each time (11/10: 44 near-identical "avoid" entries that differed only in "about N minutes left").
        let seLine = { (l: String) -> Bool in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("SE") || t.hasPrefix("⚠") || t.hasPrefix("(") || t.hasPrefix("~") || t.hasPrefix("+ ") || t.hasPrefix("- ") ||
                   t.hasPrefix("was:") || t.hasPrefix("now:") || t.hasPrefix("The code changed") || t.hasPrefix("NE TRIED") || t.hasPrefix("HANDOFF")
        }
        let lesson = feedback.split(separator: "\n").map(String.init).first { !seLine($0) && $0.count > 15 } ?? "check \(firstFail.check.name) failed"
        let words = task.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 }
        await ni.learn("FAILED before on a task like \"\(task.prefix(80))\": \(lesson.prefix(200))",
                       tags: ["failure"] + Array(Set(words)).sorted(),
                       verifiedBy: "check \(firstFail.check.name) failed: " + String(firstFail.output.suffix(200)), kind: "avoid")
    }

    nonisolated static func claimsSuccess(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["works", "working", "all tests pass", "all checks pass", "successfully", "is complete", "done!", "fully functional"]
            .contains { l.contains($0) }
    }

    // MARK: helpers

    /// Te always checks a FRESH copy of the project, so leftovers from earlier runs can't fake a pass or a fail.
    // Se also feels time passing (user, 11/10: "se needs to beware of how long its taking on something").
    // Budget per task (minutes) comes from TETI_TIME_BUDGET_MIN, default 60. Over budget with no progress = stop
    // and hand the task up a layer instead of burning hours. On a stack, that's the climb.
    nonisolated static var timeBudgetMinutes: Double {
        Double(ProcessInfo.processInfo.environment["TETI_TIME_BUDGET_MIN"] ?? "") ?? 60
    }
    // Failures that come from the SETUP, not the program's logic: a missing file, a missing package, a shell quirk.
    // A new idea (Ne) can't fix these, and Ti rewriting correct code won't either.
    nonisolated static func isEnvironmentError(_ out: String) -> Bool {
        ["No such file or directory", "can't open file", "command not found", "no matches found",
         "ModuleNotFoundError", "No module named"].contains { out.contains($0) }
    }

    // MARK: Perception switch (user, 11/10): when stuck, pick ONE way to perceive the problem, Se or Ne, in one fast step.
    // Se = the problem is in what's in front of us (tests, files, paths, packages, setup). Cheap: re-look, audit the checks.
    // Ne = the approach itself needs a new idea. Expensive: parallel branches with the big model.
    // Tier 1: hard rules (instant). Tier 2: experience, past switch decisions that led to progress (instant).
    // Tier 3: one tiny question to the loaded model, drawing on what it learned in training (a few tokens).
    // Every decision and its outcome is saved, so the switch learns from real experience.
    nonisolated static let switchLog = NSString(string: "~/local-ai/brain-lab/memory/perception-switch.jsonl").expandingTildeInPath

    nonisolated static func failureKind(_ outs: [String]) -> String {
        let all = outs.joined(separator: "\n")
        if all.contains("No such file") || all.contains("can't open file") { return "missing-file" }
        if all.contains("ModuleNotFoundError") || all.contains("No module named") || all.contains("command not found") { return "missing-tool" }
        if all.contains("no matches found") { return "shell-quirk" }
        if all.contains("Traceback") || all.contains("error:") { return "crash" }
        if all.contains("Timeout") || all.contains("timed out") { return "timeout" }
        return "wrong-output"
    }

    func perceptionSwitch(task: String, results: [(check: Check, ok: Bool, output: String)], seChange: String, codeChanged: Bool) async -> (choice: String, why: String) {
        let failing = results.filter { !$0.ok }
        let kind = Self.failureKind(failing.map { $0.output })
        // Tier 1: rules
        if ["missing-file", "missing-tool", "shell-quirk"].contains(kind) { return ("Se", "rule: \(kind) is a setup problem") }
        // diag1 task 6 (11/16): 9/10 passing, Ne spent 2 min on new approaches for ONE failing check. One check = a detail,
        // not the approach: look at the check and the output (Se), don't rebuild.
        if failing.count == 1 && results.count >= 4 { return ("Se", "rule: only one check fails, that's a detail, not the approach") }
        if !codeChanged { return ("Ne", "rule: Ti changed nothing, so it needs a different idea") }
        // Tier 2: experience (same kind of failure before, and which choice made progress)
        if let text = try? String(contentsOfFile: Self.switchLog, encoding: .utf8) {
            var wins: [String: Int] = [:]
            for line in text.split(separator: "\n").suffix(500) {
                guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      j["kind"] as? String == kind, let c = j["choice"] as? String, let prog = j["progress"] as? Bool else { continue }
                wins[c, default: 0] += prog ? 1 : -1
            }
            if let best = wins.max(by: { $0.value < $1.value }), best.value >= 2 { return (best.key, "experience: \(best.key) made progress on '\(kind)' \(best.value) more times") }
        }
        // Tier 3: one tiny question to the model already loaded (its training is its life experience)
        let evidence = failing.prefix(3).map { "[\($0.check.name)] " + String($0.output.suffix(300)) }.joined(separator: "\n")
        let reply = await ask([.init(role: .user, content: """
            A program keeps failing its checks. Decide in ONE word where the problem is.
            SE = in what is in front of us: the tests themselves, file paths, missing packages, the setup or environment.
            NE = in the approach: the logic needs a genuinely different idea.
            What changed last round:
            \(String(seChange.prefix(600)))
            Failing output:
            \(evidence)
            Answer with exactly one word: SE or NE
            """)], phase: "perception-switch", maxTokens: 4)
        return reply.uppercased().contains("SE") ? ("Se", "model judged it a setup/test problem") : ("Ne", "model judged it needs a new idea")
    }

    nonisolated func recordSwitch(kind: String, choice: String, progress: Bool) {
        let line = (try? JSONSerialization.data(withJSONObject: ["kind": kind, "choice": choice, "progress": progress, "t": Date().timeIntervalSince1970])) ?? Data()
        if let h = FileHandle(forWritingAtPath: Self.switchLog) { h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); try? h.close() }
        else { FileManager.default.createFile(atPath: Self.switchLog, contents: line + Data("\n".utf8)) }
    }

    // Se remembers what was here before and sees what changed (user, 11/10), then passes it to the other
    // functions: Ti sees what its last edit really did, Te judges with it, Ne knows what was already tried,
    // Si writes it in the journal. "Changed the code, same failure" means the problem may not be in the code.
    nonisolated func seSnapshot(_ d: String) -> [String: String] {
        var snap: [String: String] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: d) else { return snap }
        while let rel = e.nextObject() as? String {
            if rel.hasPrefix(".") || rel.contains("/.") { e.skipDescendants(); continue }
            let full = d + "/" + rel
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                  let size = (try? fm.attributesOfItem(atPath: full))?[.size] as? Int, size < 200_000,
                  let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            snap[rel] = text
        }
        return snap
    }

    nonisolated func seDiff(_ before: [String: String], _ after: [String: String]) -> (summary: String, changed: Bool) {
        var lines: [String] = []
        for f in after.keys.sorted() where before[f] == nil { lines.append("+ new file \(f) (\(after[f]!.split(separator: "\n").count) lines)") }
        for f in before.keys.sorted() where after[f] == nil { lines.append("- removed \(f)") }
        for f in after.keys.sorted() {
            guard let old = before[f], let new = after[f], old != new else { continue }
            let o = old.components(separatedBy: "\n"), n = new.components(separatedBy: "\n")
            let oSet = Set(o), nSet = Set(n)
            let added = n.filter { !oSet.contains($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let removed = o.filter { !nSet.contains($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            var entry = "~ changed \(f): +\(added.count) / -\(removed.count) lines"
            for l in removed.prefix(3) { entry += "\n    was: " + l.trimmingCharacters(in: .whitespaces).prefix(100) }
            for l in added.prefix(3) { entry += "\n    now: " + l.trimmingCharacters(in: .whitespaces).prefix(100) }
            lines.append(entry)
        }
        return (lines.isEmpty ? "no files changed" : lines.joined(separator: "\n"), !lines.isEmpty)
    }

    // Se: look at what's actually in front of you before following directions (user's design, 11/10).
    // Te plans routes; it assumed a file needed directions (../groupsum.py) when it was already right here.
    // Before any check runs, Se looks at the real folder the check will stand in. If a check points somewhere
    // else for a file that is sitting right here, Se corrects the directions. Reality first, plan second.
    nonisolated func seGround(_ checks: [Check], standingIn here: String) -> (checks: [Check], notes: [String]) {
        let present = Set(((try? FileManager.default.contentsOfDirectory(atPath: here)) ?? []).filter { !$0.hasPrefix(".") })
        var notes: [String] = []
        let out = checks.map { c -> Check in
            var cmd = c.command
            for f in present {
                for wrong in ["../../\(f)", "../\(f)", dir + "/\(f)"] where cmd.contains(wrong) {
                    // where would the shell actually look, standing in this folder?
                    let target = URL(fileURLWithPath: wrong, relativeTo: URL(fileURLWithPath: here + "/")).standardized.path
                    if !FileManager.default.fileExists(atPath: target) {
                        cmd = cmd.replacingOccurrences(of: wrong, with: f)
                        notes.append("Se: '\(wrong)' → '\(f)' in check '\(c.name)' (it's right here)")
                    }
                }
            }
            return Check(name: c.name, command: cmd, expect: c.expect)
        }
        // Path doctor (exam task 12, 11/11): a Swift package builds into .build/, never build/. Checks that ran
        // ./build/debug/textstats failed 6 rounds with "no such file" while the code was fine.
        var swiftFixed = 0
        let fm = FileManager.default
        // (exam 11/11: the brain made its own build/debug -> .build link, and the old "no build/ folder" test switched
        // the doctor off.) Now: rewrite whenever build/<cfg>/<program> isn't a real, runnable file.
        let swiftOut = present.contains("Package.swift") ? out.map { c -> Check in
            guard let rx = try? NSRegularExpression(pattern: #"(^|[\s;&|(=])(?:\./)?build/(debug|release)/"#),
                  let bx = try? NSRegularExpression(pattern: #"(?:^|[\s;&|(=])(?:\./)?build/(debug|release)/([\w.+-]+)"#) else { return c }
            let r = NSRange(c.command.startIndex..., in: c.command)
            let progs = bx.matches(in: c.command, range: r).compactMap { m -> String? in
                guard let cfg = Range(m.range(at: 1), in: c.command), let bin = Range(m.range(at: 2), in: c.command) else { return nil }
                return here + "/build/" + c.command[cfg] + "/" + c.command[bin] }
            guard !progs.isEmpty, progs.contains(where: { !fm.isExecutableFile(atPath: $0) }) else { return c }
            swiftFixed += 1
            return Check(name: c.name, command: rx.stringByReplacingMatches(in: c.command, range: r, withTemplate: "$1.build/$2/"), expect: c.expect)
        } : out
        if swiftFixed > 0 { notes.append("Se: \(swiftFixed) check(s) looked in build/, but a Swift package builds into .build/, so they now look there") }
        // diag2 task 12 (11/16): checks ran ./textstats in a Swift package; no such file there, so every check failed for
        // 9+ min while the code passed every hidden test. ./NAME that isn't a real file, in a package that names NAME,
        // becomes `swift run -q NAME` (builds if needed, then runs the right binary).
        var runFixed = 0
        let pkgText = present.contains("Package.swift") ? ((try? String(contentsOfFile: here + "/Package.swift", encoding: .utf8)) ?? "") : ""
        let finalOut = pkgText.isEmpty ? swiftOut : swiftOut.map { c -> Check in
            guard let rx = try? NSRegularExpression(pattern: #"(^|[\s;&|(=])\./([A-Za-z0-9_-]+)(?=$|[\s;&|)<>])"#) else { return c }
            var cmd = c.command, changed = false
            for m in rx.matches(in: c.command, range: NSRange(c.command.startIndex..., in: c.command)).reversed() {
                guard let nr = Range(m.range(at: 2), in: c.command), let whole = Range(m.range, in: cmd), let lead = Range(m.range(at: 1), in: cmd) else { continue }
                let name = String(c.command[nr])
                guard !fm.isExecutableFile(atPath: here + "/" + name), pkgText.contains("\"\(name)\"") else { continue }
                cmd.replaceSubrange(whole, with: String(cmd[lead]) + "swift run -q " + name); changed = true
            }
            if changed { runFixed += 1 }
            return changed ? Check(name: c.name, command: cmd, expect: c.expect) : c
        }
        if runFixed > 0 { notes.append("Se: \(runFixed) check(s) ran ./program in a Swift package, where it doesn't exist; they now use `swift run -q`") }
        // HOST QUIRK (lang-py task 12, 11/16): macOS `wc -l` pads the number with spaces ("       4"), so a Linux-style
        // check `wc -l | grep -q "^4$"` can never pass here. Strip the spaces before comparing.
        var wcFixed = 0
        let quirkOut = finalOut.map { c -> Check in
            guard let rx = try? NSRegularExpression(pattern: #"wc\s+(-[lwc])(\s*)\|"#), c.command.contains("wc -") else { return c }
            let r = NSRange(c.command.startIndex..., in: c.command)
            let fixed = rx.stringByReplacingMatches(in: c.command, range: r, withTemplate: "wc $1 | tr -d ' ' $2|")
            if fixed != c.command && !c.command.contains("tr -d") { wcFixed += 1; return Check(name: c.name, command: fixed, expect: c.expect) }
            return c
        }
        if wcFixed > 0 { notes.append("Se: \(wcFixed) check(s) compare `wc` output; macOS pads it with spaces, so they now strip them first") }
        // lang4-py (11/16): 4th style `prog | diff -q - <(printf "lines 1\n...longest a")`. The printf has no final newline and
        // the program's output does, so diff fails EVERY time, even on perfect code. Rewrite to a plain expect check.
        var diffFixed = 0
        let diffOut = quirkOut.map { c -> Check in
            guard c.command.contains("diff"), c.expect?.isEmpty ?? true,
                  let rx = try? NSRegularExpression(pattern: #"\s*\|\s*diff\s+(?:-q\s+)?-\s+<\(\s*printf\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)')\s*\)\s*$"#),
                  let m = rx.firstMatch(in: c.command, range: NSRange(c.command.startIndex..., in: c.command)),
                  let whole = Range(m.range, in: c.command) else { return c }
            let body = Range(m.range(at: 1), in: c.command).map { String(c.command[$0]) } ?? Range(m.range(at: 2), in: c.command).map { String(c.command[$0]) } ?? ""
            let want = body.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            diffFixed += 1
            return Check(name: c.name, command: String(c.command[..<whole.lowerBound]), expect: want)
        }
        if diffFixed > 0 { notes.append("Se: \(diffFixed) check(s) used `diff` against printf text with no final newline (fails on any program); they now compare the output directly") }
        return (diffOut, notes)
    }

    func runChecks(_ checks: [Check], in where_: String, emitting: Bool) -> [(check: Check, ok: Bool, output: String)] {
        let fresh = dir + "/.teti/checkrun"
        try? FileManager.default.removeItem(atPath: fresh)
        copyProject(from: where_, to: fresh)
        let (seen, seNotes) = seGround(checks, standingIn: fresh)
        if emitting { for n in seNotes { emit(.note(n)) } }
        return seen.map { c in
            let (code, out) = Sandbox.run(fresh, c.command, timeout: 60)
            if let ex = Self.exactSpec(c.expect) {
                // exact test built by code: exit code and whole output must match the answer keys (trailing spaces ignored)
                let ok = Int(code) == ex.rc && Self.norm(out) == Self.norm(ex.text)
                var why = ""
                if !ok {
                    if Int(code) != ex.rc { why = "exit code \(code), the answer keys exit \(ex.rc)\n" }
                    let w = Self.norm(ex.text).components(separatedBy: "\n"), g = Self.norm(out).components(separatedBy: "\n")
                    if let i = (0..<max(w.count, g.count)).first(where: { (i: Int) -> Bool in (i < w.count ? w[i] : "∅") != (i < g.count ? g[i] : "∅") }) {
                        why += "line \(i + 1): expected \"\(i < w.count ? w[i] : "(no line)")\", got \"\(i < g.count ? g[i] : "(no line)")\"\n"
                    }
                }
                if emitting { emit(.check(name: c.name, passed: ok, detail: ok ? "" : why.replacingOccurrences(of: "\n", with: " · "))) }
                return (c, ok, "exit \(code)\n" + why + out)
            }
            let ok = code == 0 && (c.expect.map { out.contains($0) } ?? true)
            let why = (code == 0 && !ok) ? "the command passed (exit 0) but its output doesn't contain the expected text \"\(c.expect ?? "")\"\n" : ""
            if emitting { emit(.check(name: c.name, passed: ok, detail: ok ? "" : "exit \(code): " + (why.isEmpty ? "" : "output lacks expected text · ") + String(out.suffix(160)).replacingOccurrences(of: "\n", with: " "))) }
            return (c, ok, "exit \(code)\n" + why + out)
        }
    }

    func ask(_ msgs: [BrainMessage], phase: String, maxTokens: Int) async -> String {
        var reply = ""
        do { reply = try await model.complete(msgs, maxTokens: maxTokens, think: false) }
        catch { reply = ""; emit(.note("model error in \(phase): \(error.localizedDescription)")) }
        reply = reply.components(separatedBy: "</think>").last ?? reply
        if let d = try? JSONSerialization.data(withJSONObject: ["phase": phase, "ask": msgs.last?.content ?? "", "reply": reply]) {
            log?.write(d + Data("\n".utf8))
        }
        return reply
    }

    func helpRequest(task: String, why: String, checks: [Check], feedback: String) -> String {
        let path = dir + "/.teti/help-request.md"
        let text = "# Code Smash TeTi needs help\n\n**Task:** \(task)\n\n**Why:** \(why)\n\n**Checks:**\n" +
            checks.map { "- \($0.name): `\($0.command)`" }.joined(separator: "\n") + "\n\n**Te's last findings:**\n\(feedback)\n\n" +
            "Nothing was sent anywhere. The owner decides whether to pass this to Claude.\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func finish(_ t0: Date, solved: Bool, loops: Int, passed: Int, total: Int, approach: String, help: String?) -> LoopResult {
        var r = LoopResult(solved: solved, loops: loops, checksPassed: passed, checksTotal: total, approach: approach,
                           files: files.sorted(), helpRequest: help, seconds: Date().timeIntervalSince(t0))
        if !solved && !liveChecks.isEmpty {
            r.handoff = Handoff(checks: liveChecks.map { HandoffCheck(name: $0.name, command: $0.command, expect: $0.expect, passed: lastOk[$0.name] ?? false) },
                                findings: lastFeedbackText)
        }
        emit(.finished(r))
        return r
    }

    nonisolated func listing(_ d: String) -> String {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: d))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
        return items.isEmpty ? "(empty)" : items.joined(separator: ", ")
    }

    nonisolated func copyProject(from: String, to: String) {
        try? FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: true)
        for item in (try? FileManager.default.contentsOfDirectory(atPath: from)) ?? [] where item != ".teti" {
            try? FileManager.default.copyItem(atPath: from + "/" + item, toPath: to + "/" + item)
        }
    }

    nonisolated func replaceProject(_ d: String, with src: String) {
        for item in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where item != ".teti" {
            try? FileManager.default.removeItem(atPath: d + "/" + item)
        }
        copyProject(from: src, to: d)
    }

    nonisolated func parseChecks(_ s: String) -> [Check] {
        guard let rx = try? NSRegularExpression(pattern: #"<check\s+name="([^"]+)"(?:\s+cite="[^"]*")?(?:\s+expect=(?:"([^"]*)"|'([^']*)'))?(?:\s+cite="[^"]*")?\s*>(.*?)</check>"#,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        return rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
            let cmd = (g(4) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&lt;", with: "<")
            guard let name = g(1), !cmd.isEmpty else { return nil }
            // 9B exam task 3 (11/11): a "check" whose command was just the word NONE (exit 127 every round). Not a test.
            if cmd.range(of: #"^[A-Z/_-]{2,12}$"#, options: .regularExpression) != nil { return nil }
            let exp = (g(2) ?? g(3)).flatMap { $0.isEmpty ? nil : $0 }
            return Check(name: name, command: Self.noForcedFail(Self.grepDash(cmd)), expect: Self.fairExpect(exp, cmd))
        }
    }

    /// Parse-only syntax check of files Ti wrote. Writes nothing. Returns "file: error" for each broken file.
    static func syntaxErrors(_ paths: [String], in where_: String) -> [String] {
        paths.compactMap { p in
            let q = shellQuote(p), name = String(p.dropFirst(where_.count + 1))
            let cmd: String
            switch (p as NSString).pathExtension.lowercased() {
            case "py": cmd = "python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' " + q
            case "swift": cmd = "swiftc -parse " + q
            case "js", "mjs", "cjs": cmd = "command -v node >/dev/null || exit 0; node --check " + q
            case "sh", "zsh": cmd = "zsh -n " + q
            case "json": cmd = "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' " + q
            default: return nil
            }
            let (code, out) = Sandbox.run(where_, cmd, timeout: 30)
            guard code != 0 else { return nil }
            let lines = out.split(separator: "\n").suffix(6).joined(separator: "\n")
            return name + " does not parse:\n" + lines.replacingOccurrences(of: where_ + "/", with: "")
        }
    }

    /// True when every word of 4+ letters in the quote appears in the task (and there is at least one).
    nonisolated static func citeInTask(_ cite: String?, _ task: String) -> Bool {
        func words(_ t: String) -> [String] { t.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 } }
        let have = Set(words(task)), want = words(cite ?? "")
        return !want.isEmpty && want.allSatisfy { w in have.contains(w) || have.contains { $0.hasPrefix(w) || w.hasPrefix($0) && $0.count >= 5 } }
    }

    nonisolated func allMatchPairs(_ p: String, _ s: String) -> [(String, String)] {
        guard let rx = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) else { return [] }
        return rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) else { return nil }
            return (String(s[a]), String(s[b]))
        }
    }

    /// Check doctor (80B task 1, 11/10): `diff - <(printf ...)` + expect="1\n2\n…" can never pass, since diff prints nothing
    /// on a match. A command that verifies itself (diff, cmp, grep -q, test, [ ]) needs no expect; and \n in expect means a newline.
    nonisolated static func fairExpect(_ exp: String?, _ cmd: String) -> String? {
        guard let e = exp else { return nil }
        if cmd.range(of: #"(\bdiff\b|\bcmp\b|\bgrep\s+-[a-zA-Z]*q|\btest\s|\[\s)"#, options: .regularExpression) != nil { return nil }
        return e.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
    }

    /// Check doctor (9B exam task 3, 11/11): `test ... || echo "FAIL"; exit 1` exits 1 EVERY time, so it can never pass.
    /// The author meant "fail when the test fails": group the echo and the exit. A bare trailing `; exit N` becomes `|| exit N`.
    nonisolated static func noForcedFail(_ cmd: String) -> String {
        var c = cmd
        if let rx = try? NSRegularExpression(pattern: #"\|\|\s*(echo\s+(?:"[^"]*"|'[^']*'|[^;|&]*?))\s*;\s*exit\s+([1-9][0-9]*)\s*;?\s*$"#) {
            c = rx.stringByReplacingMatches(in: c, range: NSRange(c.startIndex..., in: c), withTemplate: "|| { $1; exit $2; }")
        }
        if c == cmd, let rx = try? NSRegularExpression(pattern: #"\s*;\s*exit\s+([1-9][0-9]*)\s*;?\s*$"#) {
            c = rx.stringByReplacingMatches(in: c, range: NSRange(c.startIndex..., in: c), withTemplate: " || exit $1")
        }
        // exam task 3 (11/11): `out=$(prog bad.json) && test $? -eq 1` can never pass: when prog exits 1 as the task asks,
        // && stops before the test. Two correct error checks failed 12 rounds. Use ; so the exit code reaches the test.
        if let rx = try? NSRegularExpression(pattern: #"\s*&&\s*(test\s+\$\?\s+-(?:eq|ne|gt|ge)\s+[0-9]+|\[\s+\$\?\s+-(?:eq|ne|gt|ge)\s+[0-9]+\s+\])"#) {
            c = rx.stringByReplacingMatches(in: c, range: NSRange(c.startIndex..., in: c), withTemplate: "; $1")
        }
        return c
    }

    /// Check doctor (task 10, 11/10): `grep -q "-1"` reads -1 as an option and exits 2, so a correct program
    /// fails its own check. Put -e before a pattern that starts with a dash. Leaves -e, -qe and -- alone.
    nonisolated static func grepDash(_ cmd: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: #"(\bgrep(?:\s+-[A-Za-df-z]+)*)\s+(["'])-"#) else { return cmd }
        let dashed = rx.stringByReplacingMatches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd), withTemplate: "$1 -e $2-")
        // 9B exam task 1 (11/11): the program printed "Error: missing argument" and the check ran grep -q "error", so a correct
        // program failed 4 checks over one capital letter. A task that says "print an error" doesn't fix the case: a grep for a
        // bare message word (error, usage, invalid, warning, not found) ignores case.
        let fixed = (try? NSRegularExpression(pattern: #"\bgrep(\s+-[A-Za-z]*q[A-Za-z]*)\s+(["'])(error|usage|invalid|warning|not found)\2"#, options: [.caseInsensitive]))
            .map { $0.stringByReplacingMatches(in: dashed, range: NSRange(dashed.startIndex..., in: dashed), withTemplate: "grep$1i $2$3$2") } ?? dashed
        // task 12: printf 'Hello @#$%' (one argument holding a %) fails with "invalid directive"; %b prints it as text, \n still works
        guard let pf = try? NSRegularExpression(pattern: #"\bprintf\s+('[^'%]*%[^']*')(?=\s*(?:>|\||;|&&|\)|$))"#) else { return fixed }
        return pf.matches(in: fixed, range: NSRange(fixed.startIndex..., in: fixed)).reversed().reduce(fixed) { acc, m in
            guard let r = Range(m.range, in: acc), let a = Range(m.range(at: 1), in: acc), !acc[a].contains("%%"),
                  acc[a].range(of: #"%[-+ #0-9.]*[sdifgxXobceu]"#, options: .regularExpression) == nil else { return acc }
            return acc.replacingCharacters(in: r, with: "printf '%b' " + acc[a])
        }
    }

    nonisolated func parseWrites(_ s: String) -> [(String, String)] {
        guard let rx = try? NSRegularExpression(pattern: #"<write_file\s+path="([^"]+)"\s*>\n?(.*?)\n?</write_file>"#,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        return rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (String(s[Range(m.range(at: 1), in: s)!]), String(s[Range(m.range(at: 2), in: s)!]) + "\n")
        }
    }

    /// The one file a task names (e.g. "orders.swift"), or nil if it names none or several.
    nonisolated static func singleFileName(_ task: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"\b[A-Za-z0-9_-]+\.(?:swift|py|js|ts|sh|rb|go|c|cpp|java|rs)\b"#) else { return nil }
        let names = Set(rx.matches(in: task, range: NSRange(task.startIndex..., in: task)).compactMap { Range($0.range, in: task).map { String(task[$0]) } })
        return names.count == 1 ? names.first : nil
    }

    /// The body of the first ``` fenced block.
    nonisolated static func firstCodeBlock(_ s: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"```[A-Za-z0-9_+-]*\n(.*?)```"#, options: [.dotMatchesLineSeparators]),
              let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        let body = String(s[r]); return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
    }

    nonisolated func parseRuns(_ s: String) -> [String] {
        allMatches(#"<run>(.*?)</run>"#, s).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    nonisolated func firstMatch(_ p: String, _ s: String) -> String? { allMatches(p, s).first }

    nonisolated func allMatches(_ p: String, _ s: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) else { return [] }
        return rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }
}
