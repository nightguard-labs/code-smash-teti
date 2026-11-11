import Foundation

/// Every command the brain runs goes through macOS sandbox-exec: writes only inside the project folder (plus temp),
/// no network at all, HOME = the project folder. Nothing can leave the Mac from here.
public enum Sandbox {
    static func profile(_ dir: String) -> String {
        let allow = [dir, "/private/var/folders", "/private/tmp"].map { "(subpath \"\($0)\")" }.joined(separator: " ")
        return "(version 1)(allow default)(deny network*)(allow network* (remote unix-socket))" +
            "(deny file-write* (require-not (require-any \(allow) (literal \"/dev/null\") " +
            "(literal \"/dev/tty\") (literal \"/dev/stdout\") (literal \"/dev/stderr\"))))"
    }

    /// SwiftPM sandboxes its own manifest build, and macOS refuses a sandbox inside ours ("sandbox_apply: Operation not
    /// permitted"), so every swift build failed in task 12 (11/10). Our outer sandbox still applies, so turn the inner one off.
    static let spmNoNest = "swift() { case $1 in build|run|test|package) local s=$1; shift; command swift $s --disable-sandbox \"$@\";; *) command swift \"$@\";; esac }; "

    /// Run a zsh command in `dir`. Returns (exit code, stdout+stderr), output capped.
    public static func run(_ dir: String, _ command: String, timeout: TimeInterval = 90, limit: Int = 6000) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile(dir), "/bin/zsh", "-c", "setopt NO_NOMATCH; " + spmNoNest + command]   // a bare ? or * stays literal, like sh
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = ["HOME": dir, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                         "LANG": "en_US.UTF-8", "TMPDIR": "/private/tmp", "TERM": "dumb"]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("teti-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        guard let h = try? FileHandle(forWritingTo: out) else { return (127, "could not open temp file") }
        p.standardOutput = h; p.standardError = h; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "\(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning { if Date() > deadline { p.terminate(); timedOut = true; break }; usleep(20_000) }
        p.waitUntilExit(); try? h.close()
        var text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        if text.count > limit { text = "…(trimmed)…\n" + String(text.suffix(limit)) }
        return (timedOut ? 124 : p.terminationStatus, timedOut ? text + "\n[timed out after \(Int(timeout))s]" : text)
    }

    /// Resolve a model-supplied path; nil if it would escape the project folder.
    public static func inside(_ dir: String, _ path: String) -> String? {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.hasPrefix("/") { p = dir + "/" + p }
        let real = URL(fileURLWithPath: p).standardizedFileURL.path
        let root = URL(fileURLWithPath: dir).standardizedFileURL.path
        return (real == root || real.hasPrefix(root + "/")) && !real.contains("/.teti/") ? real : nil
    }
}
