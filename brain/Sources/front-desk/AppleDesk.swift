import Foundation
import AppKit
import FoundationModels

// Apple's built-in ~3B on-device model (runs mostly on the Neural Engine, leaving the GPU for the big brain).
// Its jobs: understand the owner in plain language, turn it into a precise job for the brain, and handle
// Apple-side actions directly with Apple's own tool system.

@available(macOS 26.0, *)
@Generable
enum RequestKind: String {
    case codingTask     // build, write, fix, change code or scripts
    case question       // wants an answer or explanation
    case appleAction    // do something on the Mac: open an app, check the system, run a Shortcut
    case chat           // casual talk
}

@available(macOS 26.0, *)
@Generable
struct Intake {
    @Guide(description: "What kind of request this is")
    var kind: RequestKind
    @Guide(description: "For a coding task: a precise, complete task description for a coding agent, keeping every detail the owner gave (names, formats, languages). Otherwise: the request restated clearly.")
    var task: String
    @Guide(description: "Short project folder name in lowercase-with-dashes for coding tasks, otherwise empty")
    var project: String
}

// MARK: Apple-side tools (local only, nothing leaves the Mac)

@available(macOS 26.0, *)
struct SystemStatusTool: Tool {
    let name = "systemStatus"
    let description = "Get this Mac's battery, free disk space, memory pressure and uptime"
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String { AppleDesk.systemStatus() }
}

@available(macOS 26.0, *)
struct OpenAppTool: Tool {
    let name = "openApp"
    let description = "Open an application on this Mac by its name, like Safari, Notes or Xcode"
    @Generable struct Arguments {
        @Guide(description: "The application's name") var appName: String
    }
    func call(arguments: Arguments) async throws -> String { AppleDesk.openApp(arguments.appName) }
}

@available(macOS 26.0, *)
struct RunShortcutTool: Tool {
    let name = "runShortcut"
    let description = "Run one of the owner's approved Apple Shortcuts by name (this reaches Apple's App Intents)"
    @Generable struct Arguments {
        @Guide(description: "The Shortcut's exact name") var shortcutName: String
    }
    func call(arguments: Arguments) async throws -> String { AppleDesk.runShortcut(arguments.shortcutName) }
}

enum AppleDesk {
    static var allowedShortcutsFile: String { NSHomeDirectory() + "/local-ai/brain-lab/memory/frontdesk-shortcuts.txt" }

    static func sh(_ exe: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func systemStatus() -> String {
        let batt = sh("/usr/bin/pmset", ["-g", "batt"]).split(separator: "\n").dropFirst().first.map(String.init) ?? "?"
        let disk = sh("/bin/df", ["-h", "/System/Volumes/Data"]).split(separator: "\n").last.map(String.init) ?? "?"
        let mem = sh("/usr/bin/memory_pressure", []).split(separator: "\n").last.map(String.init) ?? "?"
        return "battery: \(batt)\ndisk (size used free %): \(disk)\n\(mem)\nuptime: \(sh("/usr/bin/uptime", []))"
    }

    static func openApp(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: ".app", with: "")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: clean)
                ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
                    .map({ URL(fileURLWithPath: "\($0)/\(clean).app") }).first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return "No app named \(clean) found." }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        return "Opened \(clean)."
    }

    /// Only Shortcuts the owner listed in the allowlist file can run (one name per line). Empty by default.
    static func runShortcut(_ name: String) -> String {
        let allowed = ((try? String(contentsOfFile: allowedShortcutsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard allowed.contains(name) else {
            return "Shortcut \"\(name)\" is not on the owner's approved list (\(allowedShortcutsFile)). Not run."
        }
        let out = sh("/usr/bin/shortcuts", ["run", name])
        return "Ran Shortcut \"\(name)\"." + (out.isEmpty ? "" : " Output: \(out.prefix(500))")
    }

    // MARK: Apple's model

    @available(macOS 26.0, *)
    static var appleReady: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @available(macOS 26.0, *)
    static var appleStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "ready"
        case .unavailable(let why): return "not ready (\(why))"
        }
    }

    @available(macOS 26.0, *)
    static func intake(_ text: String) async throws -> (kind: String, task: String, project: String) {
        let s = LanguageModelSession(instructions: """
        You are the front desk of Code Smash TeTi, a coding brain on the owner's Mac. Classify the owner's message and
        restate it precisely for the brain. Keep every detail the owner gave. The owner types fast and casually, so
        fix spelling in your restatement but never change the meaning.
        """)
        let r = try await s.respond(to: text, generating: Intake.self)
        return (r.content.kind.rawValue, r.content.task, r.content.project)
    }

    @available(macOS 26.0, *)
    static func doAppleAction(_ text: String) async throws -> String {
        let s = LanguageModelSession(tools: [SystemStatusTool(), OpenAppTool(), RunShortcutTool()], instructions: """
        You are the front desk of Code Smash TeTi on the owner's Mac. Use your tools to do what the owner asks, then
        report what happened in one or two plain sentences. Never claim you did something a tool didn't confirm.
        """)
        return try await s.respond(to: text).content
    }
}
