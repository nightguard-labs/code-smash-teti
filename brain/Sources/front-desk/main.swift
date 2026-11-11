import Foundation
import BrainCore
import BrainMind

// front-desk: the owner talks here. Apple's on-device model understands the request and routes it:
//   coding task  → the Te⇄Ti thinking loop (in ~/local-ai/brain-lab/projects/<name>)
//   question/chat → the brain answers
//   Apple action → Apple's model does it with Apple's tools (system status, open app, approved Shortcuts)
// If Apple's model isn't ready yet, a simple built-in reader does the routing instead, and Apple actions wait.
//
//   front-desk "what you want"
//   front-desk status

setvbuf(stdout, nil, _IOLBF, 0)
let argv = Array(CommandLine.arguments.dropFirst())

func get(_ url: String) async -> [String: Any]? {
    guard let u = URL(string: url), let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
}

/// The real Code Smash TeTi brain if it's loaded; otherwise the shared local model stands in.
func pickBrain() async -> (ModelClient, String) {
    let b = await BrainLink.best()
    return (b.client, b.name)
}

/// Backup reader for when Apple's model isn't available.
func simpleIntake(_ text: String) -> (kind: String, task: String, project: String) {
    let l = text.lowercased()
    let apple = ["open ", "launch ", "battery", "disk space", "system status", "run shortcut", "shortcut "]
    let code = ["build", "write", "make a", "create", "fix", "script", "program", "app", "function", "code", "refactor", "bug", "swift", "python"]
    if apple.contains(where: { l.contains($0) }) { return ("appleAction", text, "") }
    // Questions win over code words: "why do swift actors…?" is a question, not a build order.
    let asks = ["why ", "what ", "how does", "how do ", "how is", "explain", "is it ", "can you tell", "whats ", "what's "]
    let orders = ["build ", "write ", "make ", "create ", "fix ", "add ", "change ", "refactor "]
    if (l.hasSuffix("?") || asks.contains(where: { l.hasPrefix($0) })) && !orders.contains(where: { l.hasPrefix($0) }) {
        return ("question", text, "")
    }
    if code.contains(where: { l.contains($0) }) {
        let words = l.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 }.prefix(3)
        return ("codingTask", text, words.joined(separator: "-"))
    }
    return (l.hasSuffix("?") || l.hasPrefix("what") || l.hasPrefix("how") || l.hasPrefix("why")) ? ("question", text, "") : ("chat", text, "")
}

func status() async {
    if #available(macOS 26.0, *) { print("Apple on-device model: \(AppleDesk.appleStatus)") } else { print("Apple on-device model: needs macOS 26+") }
    let (_, name) = await pickBrain()
    print("Brain: \(name)")
    print("Approved Shortcuts file: \(AppleDesk.allowedShortcutsFile)")
}

guard let first = argv.first else { print("usage: front-desk \"what you want\" | front-desk status"); exit(2) }
if first == "status" { await status(); exit(0) }
let text = argv.joined(separator: " ")

// 1) understand
var intake = simpleIntake(text)
var reader = "built-in reader (Apple's model not ready yet)"
if #available(macOS 26.0, *), AppleDesk.appleReady {
    do { intake = try await AppleDesk.intake(text); reader = "Apple on-device model" }
    catch { print("(Apple model error: \(error.localizedDescription); using built-in reader)") }
}
print("🛎  front desk (\(reader)): \(intake.kind)")
if intake.task != text { print("   understood as: \(intake.task)") }

// 2) route
let (brain, brainName) = await pickBrain()
switch intake.kind {
case "codingTask":
    let name = intake.project.isEmpty ? "task-\(Int(Date().timeIntervalSince1970))" : intake.project
    let dir = BrainPaths.root.appendingPathComponent("projects/\(name)").path
    print("   → thinking loop with \(brainName)\n   project folder: \(dir)")
    let loop = ThinkingLoop(model: brain, dir: dir, project: name, si: WorkingMemory(), ni: KnowledgeBank()) { ev in
        switch ev {
        case .phase(let p, let n): print("── \(p)\(n > 0 ? " (loop \(n))" : "")")
        case .check(let c, let ok, _): print("   \(ok ? "✅" : "❌") \(c)")
        case .verdict(let p, let n, _): print("   Te: \(p)/\(n) checks pass")
        case .branch(let b): print("   🌿 \(b)")
        case .note(let s): print("   \(s)")
        case .finished(let r):
            print("\n\(r.solved ? "✅ Done" : "❌ Not solved") in \(r.loops) loop(s), \(r.checksPassed)/\(r.checksTotal) checks. Files: \(r.files.joined(separator: ", "))")
            if let h = r.helpRequest { print("Help request (not sent): \(h)") }
        }
    }
    _ = await loop.run(task: intake.task)
case "appleAction":
    if #available(macOS 26.0, *), AppleDesk.appleReady {
        do { print(try await AppleDesk.doAppleAction(intake.task)) } catch { print("Apple action failed: \(error.localizedDescription)") }
    } else {
        print("Apple actions need Apple's on-device model, which isn't ready yet (System Settings → Apple Intelligence & Siri).")
        if text.lowercased().contains("status") || text.lowercased().contains("battery") || text.lowercased().contains("disk") {
            print(AppleDesk.systemStatus())   // read-only status works without the model
        }
    }
default:
    do {
        let answer = try await brain.complete([BrainMessage(role: .system, content: Values.preamble + "\nAnswer clearly and briefly."),
                                               BrainMessage(role: .user, content: intake.task)], maxTokens: 1500, think: false)
        print((answer.components(separatedBy: "</think>").last ?? answer).trimmingCharacters(in: .whitespacesAndNewlines))
    } catch { print("brain error: \(error.localizedDescription)") }
}
