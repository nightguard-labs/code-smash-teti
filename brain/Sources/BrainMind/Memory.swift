import Foundation
import BrainCore

// MARK: - Si: working memory (one journal per project)

/// Remembers where a long project stands, so it survives context limits and restarts.
/// Te writes to it after every check; Ti reads it before every build step.
public struct ProjectJournal: Codable, Sendable {
    public var project: String
    public var goal = ""
    public var plan: [String] = []
    public var done: [String] = []
    public var openProblems: [String] = []
    public var decisions: [String] = []       // "decision — why"
    public var files: [String: String] = [:]  // path → what it does
    public var updated = Date()
    public init(project: String) { self.project = project }

    /// Short summary that goes into the prompt (keeps the context small).
    public var briefing: String {
        var s = "PROJECT MEMORY (\(project))\n"
        if !goal.isEmpty { s += "Goal: \(goal)\n" }
        if !plan.isEmpty { s += "Plan:\n" + plan.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !done.isEmpty { s += "Done:\n" + done.suffix(15).map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !openProblems.isEmpty { s += "Open problems:\n" + openProblems.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !decisions.isEmpty { s += "Decisions:\n" + decisions.suffix(10).map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !files.isEmpty { s += "Files:\n" + files.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }.joined(separator: "\n") + "\n" }
        return s
    }
}

public actor WorkingMemory {
    private let dir = BrainPaths.memory.appendingPathComponent("si")
    public init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    private func url(_ project: String) -> URL {
        let safe = project.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return dir.appendingPathComponent(safe + ".json")
    }

    public func journal(_ project: String) -> ProjectJournal {
        guard let d = try? Data(contentsOf: url(project)),
              let j = try? JSONDecoder().decode(ProjectJournal.self, from: d) else { return ProjectJournal(project: project) }
        return j
    }

    public func save(_ j: ProjectJournal) throws {
        var j = j; j.updated = Date()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(j).write(to: url(j.project), options: .atomic)
    }

    public func allProjects() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
    }
    public func archive(_ project: String) {
        let a = dir.appendingPathComponent("archive"); try? FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: url(project), to: a.appendingPathComponent(url(project).lastPathComponent))
    }

    public func update(_ project: String, _ change: (inout ProjectJournal) -> Void) throws {
        var j = journal(project); change(&j); try save(j)
    }
}

// MARK: - Ni: verified knowledge bank with reinforcement

/// Something the brain has learned and verified. Strength rises with every success and falls with failures
/// (reinforcement); strong entries are recalled first; entries unused for a long time get consolidated/retired
/// (plasticity).
public struct Insight: Codable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var tags: [String]
    public var strength: Double
    public var successes: Int
    public var failures: Int
    public var lastUsed: Date
    public var verifiedBy: String   // how Te proved it (test name, command, result)
    public var kind: String?        // "do" = proven to work · "avoid" = proven to FAIL (remembered like pain)
    public var isAvoid: Bool { kind == "avoid" }
    public var isNever: Bool { kind == "never" }
}

public actor KnowledgeBank {
    private let file = BrainPaths.memory.appendingPathComponent("ni/bank.json")
    private var items: [Insight] = []

    public init() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: file), let v = try? JSONDecoder().decode([Insight].self, from: d) { items = v }
    }

    private func persist() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(items).write(to: file, options: .atomic)
    }

    public var count: Int { items.count }

    /// Only Te-verified knowledge goes in. `verifiedBy` must say how it was proven.
    @discardableResult
    public func learn(_ text: String, tags: [String], verifiedBy: String, kind: String = "do") -> UUID? {
        guard !verifiedBy.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // The same lesson with different numbers in it (minutes, counts, line numbers) is still the same lesson: strengthen it.
        let key = Self.sameLessonKey(text)
        if let i = items.firstIndex(where: { $0.text == text || ($0.kind == kind && Self.sameLessonKey($0.text) == key) }) {
            items[i].strength += 0.5; items[i].lastUsed = Date(); persist(); return items[i].id
        }
        let it = Insight(id: UUID(), text: text, tags: tags.map { $0.lowercased() }, strength: 1, successes: 1,
                         failures: 0, lastUsed: Date(), verifiedBy: verifiedBy, kind: kind)
        items.append(it); persist(); return it.id
    }

    /// Lowercase, numbers removed, spaces collapsed: "about 28 minutes left" and "about 27 minutes left" give the same key.
    nonisolated static func sameLessonKey(_ t: String) -> String {
        t.lowercased().replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Reinforcement: a path that worked gets stronger; one that failed gets weaker.
    public func reinforce(_ id: UUID, success: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if success { items[i].successes += 1; items[i].strength += 1 } else { items[i].failures += 1; items[i].strength -= 1.5 }
        items[i].lastUsed = Date(); persist()
    }

    /// Recall the strongest relevant knowledge for a task.
    public func recall(_ query: String, limit: Int = 5) -> [Insight] {
        let words = Set(query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
        let scored = items.compactMap { it -> (Insight, Double)? in
            let hay = Set((it.tags + it.text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)))
            let hits = Double(words.intersection(hay).count)
            guard hits > 0, it.strength > 0 else { return nil }
            return (it, hits * (1 + log(1 + max(0, it.strength))))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    /// Hard "NEVER X → INSTEAD Y" rules for a language. Shown to Ti first, before anything else.
    /// Each was earned by a real error that Ti then fixed and Te verified.
    public func neverRules(for languages: [String], limit: Int = 8) -> [Insight] {
        items.filter { $0.isNever && $0.strength > 0 && ($0.tags.contains { languages.contains($0) } || $0.tags.contains("any")) }
             .sorted { $0.strength > $1.strength }.prefix(limit).map { $0 }
    }

    // Sleep support: read everything, replace everything (consolidation), and natural forgetting.
    public func all() -> [Insight] { items }
    public func replaceAll(_ new: [Insight]) { items = new; persist() }
    /// Forgetting curve: knowledge unused for more than a week slowly fades (it can be re-strengthened by use).
    public func decay(perDay: Double = 0.03) -> Int {
        var n = 0
        for i in items.indices {
            let days = Date().timeIntervalSince(items[i].lastUsed) / 86400
            if days > 7 { items[i].strength -= perDay * min(days - 7, 30); n += 1 }
        }
        if n > 0 { persist() }
        return n
    }

    /// Plasticity: retire knowledge that went negative or sat unused for `days`, returning what was retired
    /// (a later step merges these into general rules before deleting).
    public func prune(unusedDays: Double = 60) -> [Insight] {
        let cutoff = Date().addingTimeInterval(-unusedDays * 86400)
        let gone = items.filter { ($0.strength <= 0 && $0.failures > $0.successes) || ($0.lastUsed < cutoff && $0.strength < 0.5) }  // retire only when evidence is really against it
        items.removeAll { g in gone.contains { $0.id == g.id } }
        if !gone.isEmpty { persist() }
        return gone
    }
}

// MARK: - Fi: values and safety

public enum Values {
    /// The moral compass shared with the other local AIs, plus hard rules.
    public static var preamble: String {
        let morals = (try? String(contentsOf: BrainPaths.morals, encoding: .utf8)) ?? ""
        return """
        You are Code Smash TeTi, the owner's coding workhorse brain, running fully on this Mac (Apple M1 Pro, macOS).
        Hard rules: nothing leaves this computer without the owner's permission; obey US law; explain the reason
        before any system-level change; never claim something works unless a tool result proved it.
        \(morals.isEmpty ? "" : "Moral compass:\n" + String(morals.prefix(1500)))
        """
    }
}


// MARK: - Track record (failure is bad, like in real life)

/// The brain's running record. Failed loops, unsolved tasks and false "it works" claims count against it, and it sees
/// its own record in every prompt, so failure has a real cost it wants to avoid.
public struct TrackRecord: Codable, Sendable {
    public var tasks = 0, solvedFirstTry = 0, solved = 0, unsolved = 0, failedLoops = 0, falseClaims = 0
    // Reward side (owner 11/05): doing something right earns points, failing costs them.
    public var points = 0, streak = 0, bestStreak = 0, breakthroughs = 0
    public init() {}
    public init(from d: Decoder) throws {   // tolerant of older files
        let c = try d.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: k)) ?? 0 }
        tasks = v(.tasks); solvedFirstTry = v(.solvedFirstTry); solved = v(.solved); unsolved = v(.unsolved)
        failedLoops = v(.failedLoops); falseClaims = v(.falseClaims); points = v(.points); streak = v(.streak)
        bestStreak = v(.bestStreak); breakthroughs = v(.breakthroughs)
    }
    public var line: String {
        guard tasks > 0 else { return "YOUR RECORD: no tasks yet. Start it right. Rewards: +10 solved first try, +5 solved, +3 breakthrough, streak bonus. Costs: -1 per failed loop, -5 unsolved, -10 false claim." }
        return "YOUR RECORD: \(points) points · streak \(streak) (best \(bestStreak)) · \(tasks) tasks · \(solvedFirstTry) solved first try · " +
            "\(solved) solved · \(breakthroughs) breakthroughs · \(unsolved) FAILED · \(failedLoops) failed loops · \(falseClaims) false claims.\n" +
            "Rewards: +10 solved first try, +5 solved, +3 breakthrough, + streak bonus. Costs: -1 per failed loop, -5 unsolved, -10 false claim."
    }
}

public actor TrackKeeper {
    private let file = BrainPaths.memory.appendingPathComponent("track.json")
    public private(set) var record = TrackRecord()
    public init() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: file), let r = try? JSONDecoder().decode(TrackRecord.self, from: d) { record = r }
    }
    public func update(_ f: (inout TrackRecord) -> Void) {
        f(&record)
        try? JSONEncoder().encode(record).write(to: file, options: .atomic)
    }
}
