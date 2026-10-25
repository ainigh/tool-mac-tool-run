import Foundation

/// Factory reset: the app back as it was installed. Everything it keeps that didn't come with it
/// goes to the Trash (so it can be had back): its own things (the runs, the grids' settings),
/// TOOL-MAC-RUN (SYSTEM-DOCS), and the scripts folder, unless that's a folder of the person's that
/// holds more than scripts (their home, the Desktop, Documents…). The library, MEMORY and the mind
/// stay: they're Storage Spaces' (its own Factory Reset takes them). Its settings are forgotten too. It's done once the app has quit (as it
/// quits, the app saves its runs and settings, which would only come back), then the app opens
/// again: it asks for a scripts folder, and the examples come with it.
public enum FactoryReset {
    public struct Plan: Sendable, Equatable {
        /// What goes to the Trash.
        public var trash: [URL]
        /// What's kept though it's the app's, and why ("~/Documents: it holds more than scripts").
        public var kept: [String]
    }

    /// What a factory reset takes away, the app's own first: what's there now.
    public static func plan(scripts: URL?, home: URL = Home.root, support: URL = AppPaths.support,
                            shelves: [URL] = Shelf.allCases.filter { !$0.inStorageSpaces }.map(\.root),
                            user: URL = FileManager.default.homeDirectoryForCurrentUser) -> Plan {
        let fm = FileManager.default
        var trash: [URL] = []
        var kept: [String] = []
        func add(_ url: URL) {
            let u = url.standardizedFileURL
            guard fm.fileExists(atPath: u.path), !trash.contains(where: { within(u, $0) }) else { return }
            trash.removeAll { within($0, u) }
            trash.append(u)
        }
        add(support)
        add(home)
        // A shelf put somewhere else (TMR_LIBRARY…) goes too, unless it's one of the person's own folders.
        for shelf in shelves where !within(shelf.standardizedFileURL, home.standardizedFileURL) {
            if mayRemove(shelf, user: user) { add(shelf) } else if fm.fileExists(atPath: shelf.path) { kept.append("\(short(shelf, user)): it holds more than the app's") }
        }
        if let scripts {
            if mayRemove(scripts, user: user) { add(scripts) } else { kept.append("\(short(scripts, user)), the scripts folder: it holds more than scripts") }
        }
        return Plan(trash: trash, kept: kept)
    }

    /// Whether a folder may go to the Trash whole: not the top of the disk, the person's home or
    /// anything holding it, nor one of the folders every Mac has (Desktop, Documents, Downloads…).
    public static func mayRemove(_ folder: URL, user: URL) -> Bool {
        let f = folder.standardizedFileURL.path, home = user.standardizedFileURL.path
        if f == "/" || f.isEmpty || within(user.standardizedFileURL, folder.standardizedFileURL) { return false }
        let mine = ["Desktop", "Documents", "Downloads", "Library", "Applications", "Movies", "Music", "Pictures", "Public", "Sites", "iCloud Drive"]
        if mine.contains(where: { f == home + "/" + $0 }) { return false }
        let system = ["/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/usr", "/bin", "/sbin", "/opt", "/etc", "/var", "/tmp"]
        if system.contains(f) || (f.hasPrefix("/Volumes/") && f.split(separator: "/").count <= 2) { return false }
        return true
    }

    /// Whether `inner` is `outer` or inside it.
    static func within(_ inner: URL, _ outer: URL) -> Bool {
        let i = inner.standardizedFileURL.path, o = outer.standardizedFileURL.path
        return i == o || i.hasPrefix(o.hasSuffix("/") ? o : o + "/")
    }

    static func short(_ url: URL, _ user: URL) -> String {
        let p = url.standardizedFileURL.path, h = user.standardizedFileURL.path
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }

    /// What does it, as `sh -c script factory-reset PID TRASH STAMP APP DOMAIN PATH…`: waits for
    /// the app (PID) to have quit, moves each PATH into TRASH as "NAME (reset STAMP)", forgets the
    /// settings kept under DOMAIN (none: ""), and opens APP again (none: "").
    public static let script = """
    pid="$1"; trash="$2"; stamp="$3"; app="$4"; domain="$5"; shift 5
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    mkdir -p "$trash"
    for p in "$@"; do
      [ -e "$p" ] || continue
      dest="$trash/$(basename "$p") (reset $stamp)"
      n=2
      while [ -e "$dest" ]; do dest="$trash/$(basename "$p") (reset $stamp $n)"; n=$((n + 1)); done
      mv "$p" "$dest"
    done
    if [ -n "$domain" ]; then /usr/bin/defaults delete "$domain" >/dev/null 2>&1; fi
    if [ -n "$app" ]; then /usr/bin/open "$app"; fi
    exit 0
    """

    /// The arguments `script` takes, after `-c script`.
    public static func arguments(pid: Int32, trash: URL, app: URL?, domain: String?, plan: Plan, at date: Date = Date()) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return ["factory-reset", String(pid), trash.path, f.string(from: date), app?.path ?? "", domain ?? ""] + plan.trash.map(\.path)
    }
}
