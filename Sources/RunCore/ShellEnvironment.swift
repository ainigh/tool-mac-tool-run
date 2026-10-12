import Foundation

/// The environment scripts run in. An app opened from the Finder or the menu bar gets a bare
/// PATH (/usr/bin:/bin:/usr/sbin:/sbin), so Homebrew's python3, node and friends wouldn't be
/// found: this adds the PATH your login shell has, and the usual places programs live.
public final class ShellEnvironment: @unchecked Sendable {
    public static let shared = ShellEnvironment()

    private let lock = NSLock()
    private var cached: [String: String]?

    /// The places tried after the login shell's PATH.
    public static let usualPlaces = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                                     "~/.local/bin", "~/.cargo/bin", "~/.deno/bin", "~/.bun/bin", "~/go/bin",
                                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// This process's environment, with the fuller PATH.
    public var environment: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs: [String] = []
        func add(_ list: String) {
            for d in list.split(separator: ":").map(String.init) where !d.isEmpty {
                let path = d.hasPrefix("~") ? home + d.dropFirst() : d
                if !dirs.contains(path) { dirs.append(path) }
            }
        }
        if let login = Self.loginShellPath() { add(login) }
        add(env["PATH"] ?? "")
        add(Self.usualPlaces.joined(separator: ":"))
        env["PATH"] = dirs.joined(separator: ":")
        // Python and others print as they go, not all at the end, when they can't see a terminal.
        env["PYTHONUNBUFFERED"] = "1"
        env["TMR"] = "1"
        cached = env
        return env
    }

    /// The PATH an interactive login shell has (where Homebrew and version managers add theirs).
    /// Nil when it can't be read within a few seconds.
    static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf '%s' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Where `program` is on `path`, if it's there.
    public static func find(_ program: String, path: String) -> String? {
        if program.contains("/") { return FileManager.default.isExecutableFile(atPath: program) ? program : nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(program)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Where `program` is, on the scripts' PATH.
    public func find(_ program: String) -> String? {
        Self.find(program, path: environment["PATH"] ?? "")
    }

    /// A word as it's typed in a shell: quoted when it has to be.
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Splits a line of arguments as a shell would: spaces separate, quotes keep together
    /// ("two words" or 'two words'), a backslash keeps the next character.
    public static func split(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var has = false
        var quote: Character?
        var escape = false
        for ch in line {
            if escape {
                current.append(ch)
                escape = false
                has = true
            } else if ch == "\\" && quote != "'" {
                escape = true
            } else if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                has = true
            } else if ch == " " || ch == "\t" || ch == "\n" {
                if has { args.append(current) }
                current = ""
                has = false
            } else {
                current.append(ch)
                has = true
            }
        }
        if has { args.append(current) }
        return args
    }
}
