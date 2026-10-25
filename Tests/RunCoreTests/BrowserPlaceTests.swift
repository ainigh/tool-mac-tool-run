import Foundation
@testable import RunCore
import XCTest

/// Where a page is worked on: side by side (the default: a window of the app's own on the right
/// half of the screen, the person's on the left), on screen (the person's own tab) or in the
/// background (the app's own window, behind theirs). Each route works the same in all three.
final class BrowserPlaceTests: XCTestCase {
    /// Chrome, as far as its AppleScript goes: windows front to back, each with its bounds and
    /// its tabs; one or two screens.
    final class FakeChrome: @unchecked Sendable {
        struct Win {
            var id: Int
            var bounds: ChromePage.Bounds
            var minimized = false
            var tabs: [String]
            var active: Int
        }

        private let lock = NSLock()
        private var windows: [Win]
        private var next = 100
        private(set) var arranged = 0
        private(set) var activated = 0

        init(_ windows: [Win]) { self.windows = windows }

        var all: [Win] { lock.withLock { windows } }
        func window(_ id: Int) -> Win? { all.first { $0.id == id } }
        func closeByHand(_ id: Int) { lock.withLock { windows.removeAll { $0.id == id } } }

        var page: ChromePage { ChromePage { [self] script, args in lock.withLock { answer(script, args) } } }

        private func pick(_ args: [String]) -> Int? {
            let wid = args[args.count - 2], not = args[args.count - 1]
            if !wid.isEmpty { return windows.firstIndex { String($0.id) == wid } }
            return windows.firstIndex { String($0.id) != not }
        }

        private func answer(_ script: String, _ args: [String]) -> String {
            if script.hasPrefix("// JavaScript") {
                return #"[{"frame": {"left": 0, "top": 0, "right": 1440, "bottom": 900}, "visible": {"left": 0, "top": 25, "right": 1440, "bottom": 860}},"#
                    + #" {"frame": {"left": 1440, "top": 0, "right": 3360, "bottom": 1080}, "visible": {"left": 1440, "top": 0, "right": 3360, "bottom": 1050}}]"#
            }
            if script.contains("minimized of w") {
                if windows.isEmpty { return "TMR_NOT_RUNNING" }
                return windows.map { "\($0.id)\t\($0.bounds)\t\($0.minimized)" }.joined(separator: "\n")
            }
            if script.contains("on bounds4") {
                arranged += 1
                var k = windows.firstIndex { String($0.id) == args[0] }
                if k == nil {
                    next += 1
                    windows.insert(Win(id: next, bounds: .init(200, 200, 1000, 700), tabs: ["chrome://newtab/"], active: 0), at: 0)
                    k = 0
                }
                var own = windows[k!]
                if let b = ChromePage.Bounds(args[1]) { own.bounds = b }
                windows[k!] = own
                if let u = windows.firstIndex(where: { String($0.id) == args[2] }), let b = ChromePage.Bounds(args[3]) { windows[u].bounds = b }
                if args[4] == "1" { windows.removeAll { $0.id == own.id }; windows.append(own) }
                if args[5] == "1" {
                    activated += 1
                    windows.removeAll { $0.id == own.id }; windows.insert(own, at: 0)
                    if let u = windows.firstIndex(where: { String($0.id) == args[2] }) { let w = windows.remove(at: u); windows.insert(w, at: 0) }
                }
                return String(own.id)
            }
            if script.contains("to {(item 1 of parts) as integer") && !script.contains("on bounds4") {
                if let u = windows.firstIndex(where: { String($0.id) == args[0] }), let b = ChromePage.Bounds(args[1]) { windows[u].bounds = b }
                return ""
            }
            if script.contains("then close (first window") {
                windows.removeAll { String($0.id) == args[0] }
                return ""
            }
            if windows.isEmpty, !script.contains("make new tab") { return "TMR_NOT_RUNNING" }
            if script.contains("make new tab") {
                let url = args[0]
                var k = pick(args)
                if k == nil {
                    if !args[2].isEmpty { return "TMR_WINDOW_GONE" }
                    next += 1
                    windows.insert(Win(id: next, bounds: .init(0, 25, 800, 600), tabs: [url], active: 0), at: 0)
                    k = 0
                } else if args[1] == "new" {
                    windows[k!].tabs.append(url)
                    windows[k!].active = windows[k!].tabs.count - 1
                } else {
                    windows[k!].tabs[windows[k!].active] = url
                }
                if args[2].isEmpty { let w = windows.remove(at: k!); windows.insert(w, at: 0); k = 0 }
                return "Page at \(url)\n\(url)\nfalse\n\(windows[k!].active + 1)"
            }
            guard let k = pick(args) else { return args[args.count - 2].isEmpty ? "TMR_NO_WINDOW" : "TMR_WINDOW_GONE" }
            let w = windows[k], url = w.tabs[w.active]
            if script.contains("execute active tab of") {
                return #"{"title": "Page at \#(url)", "url": "\#(url)", "text": "window \#(w.id): \#(url)", "present": true, "count": 1, "found": [], "highlighted": true}"#
            }
            if script.contains("tabs of win") {
                return w.tabs.enumerated().map { "1\t\($0.offset + 1)\t\($0.offset == w.active ? 1 : 0)\tPage at \($0.element)\t\($0.element)" }.joined(separator: "\n")
            }
            return "Page at \(url)\n\(url)\nfalse\n\(w.active + 1)"
        }
    }

    var settings = APISettings()
    var chrome: FakeChrome!
    var api: RunAPI!
    var folder: URL!

    /// The person's window, on the main screen.
    let theirs = ChromePage.Bounds(100, 100, 1300, 800)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("place-\(UUID().uuidString)", isDirectory: true)
        try Library(root: folder).ensure()
        chrome = FakeChrome([.init(id: 1, bounds: theirs, tabs: ["https://mine.example/", "https://mail.example/"], active: 0)])
        api = RunAPI(host: FakeRunHost(folder: folder, scripts: [], flows: []), version: "0.1.0", chrome: chrome.page) { [unowned self] in self.settings }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func get(_ target: String) async -> (Int, [String: Any]) {
        let (r, d) = await api.send("GET", target)
        return (r.status, json(d))
    }

    func post(_ target: String, _ body: String) async -> (Int, [String: Any]) {
        let (r, d) = await api.post(target, body)
        return (r.status, json(d))
    }

    func testSideBySideIsTheDefault() async throws {
        let (s, o) = await post("/api/browser/open", #"{"url": "example.com"}"#)
        XCTAssertEqual(s, 200, "\(o)")
        XCTAssertEqual(o["where"] as? String, "side_by_side")
        XCTAssertEqual(o["text"] as? String, "window 101: https://example.com", "read from its own window")
        let own = try XCTUnwrap(chrome.window(101))
        XCTAssertEqual(own.bounds, .init(720, 25, 1440, 860), "its own on the right half of the screen (without the menu bar and the Dock)")
        XCTAssertEqual(own.tabs, ["https://example.com"], "its own window's tab went to the page: no tab left blank")
        XCTAssertEqual(chrome.window(1)?.bounds, .init(0, 25, 720, 860), "the person's on the left half")
        XCTAssertEqual(chrome.all.first?.id, 1, "the person's window in front, theirs to work in")
        XCTAssertEqual(chrome.window(1)?.tabs.count, 2, "nothing opened in theirs")

        // A read with no where reads its own window; on_screen, the person's.
        let (_, page) = await get("/api/browser/page")
        XCTAssertEqual(page["text"] as? String, "window 101: https://example.com")
        XCTAssertEqual(page["where"] as? String, "side_by_side")
        let (_, mine) = await get("/api/browser/page?where=on_screen")
        XCTAssertEqual(mine["text"] as? String, "window 1: https://mine.example/", "the person's own tab, though theirs isn't the window in front")
        XCTAssertEqual(mine["where"] as? String, "on_screen")
        for route in ["/api/browser/url", "/api/browser/tabs", "/api/browser/has?text=x", "/api/browser/find?text=x", "/api/browser/outline"] {
            let (st, d) = await get(route)
            XCTAssertEqual(st, 200, "\(route): \(d)")
            XCTAssertEqual(d["where"] as? String, "side_by_side", route)
        }
        let (hs, hd) = await post("/api/browser/highlight", #"{"text": "More", "where": "on screen"}"#)
        XCTAssertEqual(hs, 200, "\(hd)")
        XCTAssertEqual(hd["where"] as? String, "on_screen")

        // Opened again: the same window, where it is (what the person has moved since stays moved).
        _ = await post("/api/browser/open", #"{"url": "example.org"}"#)
        XCTAssertEqual(chrome.arranged, 1)
        XCTAssertEqual(chrome.window(101)?.tabs, ["https://example.org"])
        let (_, status) = await get("/api/browser")
        XCTAssertEqual((status["its_window"] as? [String: Any])?["where"] as? String, "side_by_side")

        // Done: its window closed, the person's put back where it was.
        let (cs, closed) = await post("/api/browser/close", "{}")
        XCTAssertEqual(cs, 200, "\(closed)")
        XCTAssertEqual(closed["restored"] as? Bool, true)
        XCTAssertNil(chrome.window(101))
        XCTAssertEqual(chrome.window(1)?.bounds, theirs)
        let (_, after) = await get("/api/browser/page")
        XCTAssertEqual(after["where"] as? String, "on_screen", "with no window of its own, a read reads the person's")
    }

    func testOnScreenIsThePersonsOwnTab() async throws {
        let (s, o) = await post("/api/browser/open", #"{"url": "example.com", "where": "on_screen"}"#)
        XCTAssertEqual(s, 200, "\(o)")
        XCTAssertEqual(o["where"] as? String, "on_screen")
        XCTAssertEqual(o["new_tab"] as? Bool, true)
        XCTAssertEqual(chrome.all.count, 1, "no window of its own")
        XCTAssertEqual(chrome.window(1)?.tabs.last, "https://example.com")
        XCTAssertEqual(chrome.window(1)?.bounds, theirs, "nothing moved")
        // Asked for its own window when there's none: said, with how to open one.
        let (ns, nd) = await get("/api/browser/page?where=side_by_side")
        XCTAssertEqual(ns, 409)
        XCTAssertEqual(nd["code"] as? String, "no_window_of_its_own")
    }

    func testTheBackgroundIsItsOwnWindowBehindThePersons() async throws {
        let (s, o) = await post("/api/browser/open", #"{"url": "example.com", "where": "in the background"}"#)
        XCTAssertEqual(s, 200, "\(o)")
        XCTAssertEqual(o["where"] as? String, "background")
        XCTAssertEqual(chrome.all.map(\.id), [1, 101], "behind the person's")
        XCTAssertEqual(chrome.window(1)?.bounds, theirs, "the person's not moved")
        XCTAssertEqual(chrome.activated, 0, "nothing brought forward")
        let (_, page) = await get("/api/browser/page")
        XCTAssertEqual(page["text"] as? String, "window 101: https://example.com")
        XCTAssertEqual(page["where"] as? String, "background")
        // Opened again with nothing said: where its window is.
        let (_, again) = await post("/api/browser/open", #"{"url": "example.org"}"#)
        XCTAssertEqual(again["where"] as? String, "background")

        // Moved beside the person, then back behind: the person's window goes left, then back.
        let (ps, placed) = await post("/api/browser/place", #"{"where": "side by side"}"#)
        XCTAssertEqual(ps, 200, "\(placed)")
        XCTAssertEqual(chrome.window(101)?.bounds, .init(720, 25, 1440, 860))
        XCTAssertEqual(chrome.window(1)?.bounds, .init(0, 25, 720, 860))
        _ = await post("/api/browser/place", #"{"where": "background"}"#)
        XCTAssertEqual(chrome.window(1)?.bounds, theirs)
        XCTAssertEqual(chrome.all.last?.id, 101)
        // On screen, as a place: its own window closed.
        let (_, gone) = await post("/api/browser/place", #"{"where": "on_screen"}"#)
        XCTAssertEqual(gone["closed"] as? Bool, true)
        XCTAssertEqual(chrome.all.map(\.id), [1])
    }

    func testItsOwnWindowClosedByThePersonIsForgotten() async throws {
        _ = await post("/api/browser/open", #"{"url": "example.com"}"#)
        chrome.closeByHand(101)
        let (s, d) = await get("/api/browser/page")
        XCTAssertEqual(s, 200, "\(d)")
        XCTAssertEqual(d["where"] as? String, "on_screen", "nothing asked: the person's")
        let (s2, d2) = await get("/api/browser/page?where=side_by_side")
        XCTAssertEqual(s2, 409, "\(d2)")
        // Opened again: a new one, side by side.
        let (_, o) = await post("/api/browser/open", #"{"url": "example.org"}"#)
        XCTAssertEqual(o["where"] as? String, "side_by_side")
        XCTAssertEqual(chrome.window(102)?.bounds, .init(720, 25, 1440, 860))
    }

    func testSideBySideIsOnTheScreenThePersonsWindowIsOn() {
        let screens = [ChromePage.Screen(frame: .init(0, 0, 1440, 900), visible: .init(0, 25, 1440, 860)),
                       ChromePage.Screen(frame: .init(1440, 0, 3360, 1080), visible: .init(1440, 0, 3360, 1050))]
        let (l, r) = try! XCTUnwrap(ChromePage.sideBySide(around: .init(1600, 100, 2600, 900), on: screens))
        XCTAssertEqual(l, .init(1440, 0, 2400, 1050))
        XCTAssertEqual(r, .init(2400, 0, 3360, 1050))
        XCTAssertEqual(ChromePage.sideBySide(around: nil, on: screens)?.right, .init(720, 25, 1440, 860), "no window of theirs: the main screen")
    }

    func testWhereIsSaidInWords() async {
        for (said, place) in [("side by side", ChromePage.Place.sideBySide), ("beside me", .sideBySide), ("SIDE_BY_SIDE", .sideBySide), ("on screen", .onScreen),
                              ("on my screen", .onScreen), ("mine", .onScreen), ("background", .background), ("in the background", .background)] {
            XCTAssertEqual(ChromePage.Place(said: said), place, said)
        }
        let (s, d) = await get("/api/browser/page?where=upside%20down")
        XCTAssertEqual(s, 400)
        XCTAssertEqual(d["code"] as? String, "bad_where")
        XCTAssertTrue((d["error"] as? String ?? "").contains("side_by_side"), "\(d)")
    }
}
