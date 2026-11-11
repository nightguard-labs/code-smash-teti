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
    /// Ti's voice (exam task 12, 11/10): checks Ti flagged as contradicting the task, name → why. Fi judges them.
    var tiFlags: [String: String] = [:]
    var fiJudged: Set<String> = []
    // 11/10 task 12 rerun: Ti said "this is contradictory... but I can't change the test" and never used <wrong_check>,
    // so Fi never ran. Code-level triggers instead: Ti's own doubt words, or a check stuck failing 3 rounds.
    var tiDoubt = ""
    var failStreak: [String: Int] = [:]
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
            emit(.phase("Te: defining what done means", loop: 0))
            checks = await teFrame(task: task, knowledge: knowledge)
        }
        guard !checks.isEmpty else {
            return finish(t0, solved: false, loops: 0, passed: 0, total: 0, approach: "",
                          help: helpRequest(task: task, why: "Te could not turn the task into runnable checks.", checks: [], feedback: ""))
        }
        for c in checks { emit(.note("Te check '\(c.name)': \(c.command)" + (c.expect.map { "  (expect: \($0))" } ?? ""))) }
        try? await si.update(project) { j in
            j.goal = task; j.plan = checks.map { "check \($0.name): \($0.command)" }; j.openProblems = []
        }

        var feedback = handoff.map { h in
            "HANDOFF: a smaller brain built this and got stuck. The code in the folder is its work, keep it.\n" +
            "These checks ALREADY PASS, so don't break them: \(h.passing.joined(separator: ", "))\n" +
            "Fix ONLY these failing parts: \(h.failing.joined(separator: ", "))\n" +
            "Its last findings:\n\(String(h.findings.suffix(2500)))"
        } ?? ""
        var approach = "", lastFails: Set<String> = [], stuck = 0, lastPassed = -1
        var pendingSwitch: (kind: String, choice: String, passed: Int)? = nil
        var versions: [Int: (loop: Int, passed: Int)] = [:]     // Se's memory of every version of the code
        var neBreakDone = false
        neTried = []
        var best = (passed: 0, total: checks.count)
        var bestSaved = -1
        tiFlags = [:]; fiJudged = []; tiDoubt = ""; failStreak = [:]
        for loop in 1...maxLoops {
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
                return finish(t0, solved: true, loops: loop, passed: passed, total: checks.count, approach: approach, help: nil)
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
            // Se keeps the best version so far, not just the last one
            if passed > bestSaved {
                bestSaved = passed
                try? FileManager.default.removeItem(atPath: dir + "/.teti/best")
                copyProject(from: dir, to: dir + "/.teti/best")
            }
            // Se: over budget with no progress means the loop is about to stop, so skip Te's slow write-up (12-19 min on task 11)
            let doneForNow = loop > 1 && passed <= lastPassed && Date().timeIntervalSince(t0) / 60 > Self.timeBudgetMinutes
            feedback = doneForNow ? "(Se: over the time budget with no progress, Te's write-up skipped)" : await teVerdict(task: task, results: results)
            // Se passes what it saw on to the thinking functions (Ti next round, Ne if it branches)
            let sameFailure = seChanged && fails == lastFails && loop > 1
            let minsLeft = Self.timeBudgetMinutes - Date().timeIntervalSince(t0) / 60
            feedback = fiNote + circleNote + String(format: "SE: about %.0f minutes left on this task%@\n", max(0, minsLeft),
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

            // Ne: stuck on the same failures? try different paths in parallel sandboxes
            // A wall = no progress since last loop (same failures, or the score didn't go up).
            stuck = (loop > 1 && (fails == lastFails || passed <= lastPassed)) ? stuck + 1 : 0
            lastFails = fails; lastPassed = passed
            // the perception switch: when stuck, choose ONE way to look at the problem (Se or Ne), in one fast step
            if let pending = pendingSwitch { recordSwitch(kind: pending.kind, choice: pending.choice, progress: passed > pending.passed) ; pendingSwitch = nil }
            if stuck >= 1 && loop < maxLoops {
                let pick = await perceptionSwitch(task: task, results: results, seChange: seChange, codeChanged: seChanged)
                emit(.note("🔀 switch → \(pick.choice) (\(pick.why))"))
                pendingSwitch = (Self.failureKind(results.filter { !$0.ok }.map { $0.output }), pick.choice, passed)
                if pick.choice == "Se" {
                    // Se mode: re-look at the tests and setup instead of rewriting the program
                    feedback = "SE MODE: the failures look like they come from the tests or setup, not your logic. Read the failing output literally. If your program is right, say so plainly and don't rewrite it.\n\n" + feedback
                    stuck = 0
                }
            }
            if stuck >= 1 && loop < maxLoops {
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
        return finish(t0, solved: false, loops: maxLoops, passed: restoreBest(liveChecks, current: best.passed), total: best.total, approach: approach,
                      help: helpRequest(task: task, why: "Still failing after \(maxLoops) Te⇄Ti loops.", checks: checks, feedback: feedback))
    }

    // MARK: Te

    func teFrame(task: String, knowledge: String) async -> [Check] {
        let prompt = """
        TASK from the owner:
        \(task)

        Files already in the folder: \(listing(dir))

        Define what "done" means as 2-6 shell checks that PROVE the task works when run in the project folder.
        Each check runs with the project folder as its current directory: name project files plainly (tool.py), never ../tool.py. FE SAYS: think like the real user, and test each requirement more than one way, including the cases people actually hit (signs, empty or bad input, repeats).
        Each check is a zsh command that exits 0 only if that part works. Checks run IN ORDER, together, on a fresh
        copy of the project folder; if the program stores data, the FIRST check should start by deleting that data file.
        INDEPENDENCE: when a check needs input data, the check must create its OWN test input inline (for example
        printf 'line1\nline2\n' > te_input.txt && ./prog te_input.txt) and compare against the answer YOU worked out.
        Never rely on sample files Ti writes; Ti must not be able to shape the exam.
        EXIT CODES: a check passes only if its command exits 0. If the task REQUIRES a non-zero exit (errors), write the
        check as: out=$(./prog bad 2>&1); test $? -eq 1 && echo "$out" | grep -q "error"   (never let the expected
        error exit fail your check). Use plain grep -q "text" (no unusual flags). Optionally add expect="text" when the
        output must contain specific text. Test real behavior (run the program, compare output), not just that a file exists.
        Reply with exactly:
        <goal>one sentence</goal>
        <checks>
        <check name="short-name">command</check>
        <check name="short-name" expect="text that must appear">command</check>
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
            if !cs.isEmpty { return cs }
        }
        return []
    }

    func teVerdict(task: String, results: [(check: Check, ok: Bool, output: String)]) async -> String {
        let report = results.map { r in
            "[\(r.ok ? "PASS" : "FAIL")] \(r.check.name): \(r.check.command)" + (r.check.expect.map { " (expect: \($0))" } ?? "") +
            (r.ok ? "" : "\n" + String(r.output.suffix(1200)))
        }.joined(separator: "\n\n")
        let reply = await ask([.init(role: .system, content: Self.tePersona),
                               .init(role: .user, content: "TASK: \(task)\n\nCHECK RESULTS (real output):\n\(report)\n\n" +
                                     "Tell Ti exactly what is wrong and what to fix, most important first. Max 8 lines. No code.")],
                              phase: "te-verdict", maxTokens: 700)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
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
    func fiJudge(task: String, flagged: [(check: Check, ok: Bool, output: String)]) async -> (fixes: [Check], upheld: String) {
        emit(.phase("Fi: is Ti right that a check contradicts the task?", loop: 0))
        let report = flagged.map { r in
            "[\(r.check.name)] \(r.check.command)" + (r.check.expect.map { " (expect: \($0))" } ?? "") +
            "\nTI SAYS: \(String((tiFlags[r.check.name] ?? "").prefix(500)))\nREAL OUTPUT:\n\(String(r.output.suffix(500)))"
        }.joined(separator: "\n\n")
        let reply = await ask([.init(role: .system, content: "You are Fi, the fairness judge of Code Smash TeTi. You side with the TASK text, not with Te or Ti."),
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
            """)], phase: "fi-judge", maxTokens: 1200)
        let names = Set(flagged.map { $0.check.name })
        fiJudged.formUnion(names)
        let fixes = parseChecks(reply).filter { names.contains($0.name) && Sandbox.run(dir, "zsh -n -c " + Self.shellQuote($0.command), timeout: 10).0 == 0 }
        let fair = allMatchPairs(#"<fair\s+name="([^"]+)"\s*>(.*?)</fair>"#, reply).filter { names.contains($0.0) && !fixes.map(\.name).contains($0.0) }
        let upheld = fair.map { "FI RULED check '\($0.0)' is FAIR to the task: \($0.1.trimmingCharacters(in: .whitespacesAndNewlines)) Fix the program, not the check." }.joined(separator: "\n")
        return (fixes, upheld)
    }

    /// Keep the best version (exam task 12, 11/10: the code scored 4/5 at 20:02 and ended at 3/5). On an unsolved finish,
    /// grade the saved best copy with today's checks; if it beats the current code, put it back.
    func restoreBest(_ checks: [Check], current: Int) -> Int {
        let b = dir + "/.teti/best"
        guard FileManager.default.fileExists(atPath: b) else { return current }
        let r = runChecks(checks, in: b, emitting: false)
        let p = r.filter { $0.ok }.count
        guard p > current else { return current }
        replaceProject(dir, with: b)
        lastOk = Dictionary(r.map { ($0.check.name, $0.ok) }, uniquingKeysWith: { a, _ in a })
        emit(.note("Se: the best version scores \(p)/\(checks.count) on the final checks vs \(current) for the last one, so the best version goes back"))
        return p
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
        let extra = Array(parseChecks(reply).filter { c in
            guard !names.contains(c.name), Sandbox.run(dir, "zsh -n -c " + Self.shellQuote(c.command), timeout: 10).0 == 0 else { return false }
            guard Self.citeInTask(cites[c.name], task) else { emit(.note("Fi: dropped Ne's '\(c.name)', its quote \"\(cites[c.name] ?? "none")\" isn't in the task")); return false }
            return true
        }.prefix(4))
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
        return parseChecks(reply).first.flatMap { c in checks.contains { $0.name == c.name } ? nil : c }
    }

    // MARK: Ti

    /// One Ti phase: build/fix with up to 8 inner rounds of writing files and running commands.
    func tiBuild(task: String, checks: [Check], feedback: String, knowledge: String, in where_: String, steer: String?) async -> String {
        let journal = await si.journal(project).briefing
        var msgs: [BrainMessage] = [
            // Only what stays the same for the whole task goes in the system message, so the engine's prompt memory can reuse
            // it across every loop and Ne path. The journal changes after each check, so it rides in the user message (11/10).
            .init(role: .system, content: Self.tiPersona + "\n" + Values.preamble + "\n\n" + Self.tiTools + "\n\n" + knowledge),
            .init(role: .user, content: """
            \(journal)

            TASK: \(task)

            Te will judge your work ONLY by these checks (you can't change them):
            \(checks.map { "- \($0.name): \($0.command)" + ($0.expect.map { "  → output must contain: \($0)" } ?? "") }.joined(separator: "\n"))

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
        return (out, notes)
    }

    func runChecks(_ checks: [Check], in where_: String, emitting: Bool) -> [(check: Check, ok: Bool, output: String)] {
        let fresh = dir + "/.teti/checkrun"
        try? FileManager.default.removeItem(atPath: fresh)
        copyProject(from: where_, to: fresh)
        let (seen, seNotes) = seGround(checks, standingIn: fresh)
        if emitting { for n in seNotes { emit(.note(n)) } }
        return seen.map { c in
            let (code, out) = Sandbox.run(fresh, c.command, timeout: 60)
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
            let exp = (g(2) ?? g(3)).flatMap { $0.isEmpty ? nil : $0 }
            return Check(name: name, command: Self.grepDash(cmd), expect: Self.fairExpect(exp, cmd))
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

    /// Check doctor (task 10, 11/10): `grep -q "-1"` reads -1 as an option and exits 2, so a correct program
    /// fails its own check. Put -e before a pattern that starts with a dash. Leaves -e, -qe and -- alone.
    nonisolated static func grepDash(_ cmd: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: #"(\bgrep(?:\s+-[A-Za-df-z]+)*)\s+(["'])-"#) else { return cmd }
        let fixed = rx.stringByReplacingMatches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd), withTemplate: "$1 -e $2-")
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

    nonisolated func parseRuns(_ s: String) -> [String] {
        allMatches(#"<run>(.*?)</run>"#, s).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    nonisolated func firstMatch(_ p: String, _ s: String) -> String? { allMatches(p, s).first }

    nonisolated func allMatches(_ p: String, _ s: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) else { return [] }
        return rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }
}
