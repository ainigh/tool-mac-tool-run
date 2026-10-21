import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The environment scripts run in. An app opened from the Finder or the menu bar gets a bare
/// PATH (/usr/bin:/bin:/usr/sbin:/sbin), so Homebrew's python3, node and friends wouldn't be
/// found: this adds the PATH your login shell has, and the usual places programs live.
public final class ShellEnvironment: @unchecked Sendable {
    public static let shared = ShellEnvironment()

    private let condition = NSCondition()
    private var cached: [String: String]?
    private var probing = false

    /// The places tried after the login shell's PATH.
    public static let usualPlaces = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                                     "~/.local/bin", "~/.cargo/bin", "~/.deno/bin", "~/.bun/bin", "~/go/bin",
                                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// This process's environment, with the fuller PATH.
    ///
    /// The first time, it asks your login shell for its PATH (see `loginShellPath`), which takes
    /// as long as your shell's startup files do, and at most about 5 seconds; after that it's
    /// remembered. Whoever asks while that's going on waits for it (the shell is asked once), so
    /// call `prepare()` early, off the main thread, and the first run doesn't wait.
    public var environment: [String: String] {
        condition.lock()
        while probing { condition.wait() }
        if let cached {
            condition.unlock()
            return cached
        }
        probing = true
        condition.unlock()
        // The shell is asked without holding the lock (only the waiting above is guarded).
        let env = Self.build(login: Self.loginShellPath())
        condition.lock()
        cached = env
        probing = false
        condition.broadcast()
        condition.unlock()
        return env
    }

    /// The environment, if it's been worked out already (nil: not yet, nothing is waited for).
    public var environmentIfReady: [String: String]? {
        condition.lock()
        defer { condition.unlock() }
        return cached
    }

    /// Works the environment out in the background now, so it's ready when the first script runs.
    public func prepare() {
        DispatchQueue.global(qos: .utility).async { _ = self.environment }
    }

    static func build(login: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs: [String] = []
        func add(_ list: String) {
            for d in list.split(separator: ":").map(String.init) where !d.isEmpty {
                let path = d.hasPrefix("~") ? home + d.dropFirst() : d
                if !dirs.contains(path) { dirs.append(path) }
            }
        }
        if let login { add(login) }
        add(env["PATH"] ?? "")
        add(Self.usualPlaces.joined(separator: ":"))
        env["PATH"] = dirs.joined(separator: ":")
        // Python and others print as they go, not all at the end, when they can't see a terminal.
        env["PYTHONUNBUFFERED"] = "1"
        env["TMR"] = "1"
        return env
    }

    /// The PATH your shell has when you open a terminal: as an interactive login shell (so zsh
    /// reads .zshrc too, where nvm, pyenv and conda add theirs), else as a login shell only (if
    /// the interactive one fails or takes too long). Nil when neither gives one within the time.
    ///
    /// The shell writes its PATH to a file of its own; its output and input are /dev/null, so
    /// whatever the startup files print, and anything they leave running, can't hold it up. It's
    /// waited for at most `timeout` seconds in all, then it's ended (with all it started).
    ///
    /// The interactive one is only asked when this process has no terminal (an app opened from the
    /// Finder or the menu bar): an interactive shell would take over a terminal it can reach. In
    /// a terminal, this process's own PATH (added by `environment`) is the interactive one already.
    static func loginShellPath(shell: String? = nil, timeout: TimeInterval = 5) -> String? {
        let shell = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        if !hasTerminal, let path = probe(shell, flags: ["-i", "-l"], timeout: timeout * 0.6) { return path }
        return probe(shell, flags: ["-l"], timeout: max(0.5, deadline.timeIntervalSinceNow))
    }

    /// This process has a terminal it could be interrupted from.
    static var hasTerminal: Bool {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Asks `shell` (started with `flags`) for its PATH. Nil if it fails, gives none, or takes
    /// longer than `timeout` seconds.
    static func probe(_ shell: String, flags: [String], timeout: TimeInterval) -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tmr-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = flags + ["-c", "printf '%s' \"$PATH\" > \"$TMR_PATH_FILE\""]
        var env = ProcessInfo.processInfo.environment
        env["TMR_PATH_FILE"] = file.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Waited for by itself (not for its output to close, nor for what it left running).
        let deadline = Date().addingTimeInterval(timeout)
        var wait: useconds_t = 2_000
        while exitStatus(of: p) == nil {
            if Date() >= deadline {
                // It (or something its startup files run) is stuck: end it, and everything it started.
                let pid = p.processIdentifier
                if getpgid(pid) == pid { kill(-pid, SIGKILL) }
                kill(pid, SIGKILL)
                return nil
            }
            usleep(wait)
            wait = min(wait * 2, 50_000)
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
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

    /// Characters a word can have and still be typed bare, in bash and zsh alike.
    private static let bare = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")

    /// A word as it's typed in a shell: bare when it's only letters, digits and `-_./=:@%+,` (and
    /// doesn't start with `=`, which zsh would expand), else in single quotes.
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, !s.hasPrefix("="), s.allSatisfy({ bare.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Splits a line of arguments as a shell would: spaces separate, quotes keep together
    /// ("two words" or 'two words'), a backslash keeps the next character (in double quotes, only
    /// `$`, a backquote, `"`, `\` and a newline, as in bash: "C:\dir" stays `C:\dir`).
    public static func split(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var has = false
        var quote: Character?
        var escape = false
        for ch in line {
            if escape {
                if quote == "\"", !"$`\"\\\n".contains(ch) { current.append("\\") }
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
            } else if ch == " " || ch == "\t" || ch == "\n" || ch == "\r\n" || ch == "\r" {  // "\r\n" is one Character
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
