import Foundation

/// Straw scripts (`.straw`): Chrome driven by what's on the page, one plain line a step (`open
/// news.ycombinator.com`, `click "More"`, `read all css ".titleline > a"`). They're scripts like
/// any other (a cell, a run, `run "hacker-news"` in a flow, the API); what runs them is
/// `straw.py`, kept in the browser folder beside `browser.sh`, which does the driving. The
/// language is docs/STRAW-GUIDE.md.
public enum Straw {
    /// The runner's file name.
    public static let runnerName = "straw.py"

    /// What puts the runner back when it's missing.
    public static let fixMissingRunner = "Open the Browser grid and click Add the Examples: it puts straw.py (and browser.sh, which it drives Chrome with) back, changing nothing else."

    /// The straw.py that runs `script`: beside it, else in a browser folder beside it or above it
    /// (a .straw at the top of the scripts folder uses the one in its browser folder).
    public static func runner(for script: URL) -> URL? {
        let fm = FileManager.default
        var folder = script.deletingLastPathComponent()
        for _ in 0..<4 {
            for candidate in [folder.appendingPathComponent(runnerName),
                              folder.appendingPathComponent("browser", isDirectory: true).appendingPathComponent(runnerName)]
            where fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            let up = folder.deletingLastPathComponent()
            if up.path == folder.path { break }
            folder = up
        }
        return nil
    }
}
