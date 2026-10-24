import Foundation

/// The page in front of Google Chrome, as another app can ask about it: its title and address
/// (these need nothing switched on), its text, whether some words are on it, where a thing named
/// on it is (in view, above, below, or inside a menu that's closed), an outline of it, and a
/// highlight that shows the person where to look; and it opens an address in a new tab (Chrome
/// too, if it's closed), for the person to see and to read. It never clicks or types (Straw does
/// that, after asking); only `open` starts Chrome: every read, with Chrome closed, says so.
///
/// It talks to Chrome through AppleScript (`osascript`): macOS asks once whether the app may
/// control Chrome, and reading inside the page needs Chrome's View > Developer > Allow JavaScript
/// from Apple Events, as the browser scripts do.
public struct ChromePage: Sendable {
    /// Runs AppleScript (given as its input) with these arguments: what it printed, or the error.
    public typealias Runner = @Sendable (_ script: String, _ args: [String]) throws -> String

    let run: Runner

    public init(run: @escaping Runner = ChromePage.osascript) {
        self.run = run
    }

    public static let bundleID = "com.google.Chrome"

    // MARK: what's in front

    public struct Tab: Sendable, Equatable {
        public var title: String
        public var url: String
        public var loading: Bool
        public var window: Int
        public var index: Int
        public var active: Bool
    }

    /// The tab in front: its title and address (no JavaScript needed).
    public func front() throws -> Tab {
        let out = try call(Self.frontScript, [])
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 3 else { throw ChromeError(.failed, "Chrome gave back something unexpected: \(out)") }
        return Tab(title: parts[0], url: parts[1], loading: parts[2] == "true", window: 1, index: Int(parts.count > 3 ? parts[3] : "") ?? 1, active: true)
    }

    /// Every tab (of the front window; `all`: of every window).
    public func tabs(all: Bool = false) throws -> [Tab] {
        let out = try call(Self.tabsScript, [all ? "all" : "front"])
        return out.components(separatedBy: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5 else { return nil }
            return Tab(title: f[3], url: f.count > 4 ? f[4...].joined(separator: "\t") : "", loading: false, window: Int(f[0]) ?? 1, index: Int(f[1]) ?? 1, active: f[2] == "1")
        }
    }

    /// The page's JavaScript answer (a JSON object), from the tab in front.
    public func js(_ code: String) throws -> [String: Any] {
        let wrapped = "(() => { try { return JSON.stringify((() => { \(code) })()); } catch (e) { return JSON.stringify({__error: String(e)}); } })()"
        let out = try call(Self.jsScript, [wrapped])
        guard let obj = JSON.object(Data(out.utf8)) else { throw ChromeError(.failed, "The page gave back something that isn't JSON: \(out.prefix(200))") }
        if let e = obj["__error"] as? String { throw ChromeError(.pageError, "The page's JavaScript failed: \(e)") }
        return obj
    }

    /// The page: title, address, its text (at most `max` characters), what's selected, how far down it is.
    public func page(max: Int = 20000, outline: Bool = false) throws -> [String: Any] {
        var out = try js(Self.pageJS(max: max))
        if outline { out["outline"] = try js(Self.outlineJS) }
        return out
    }

    /// Whether some words are on the page (in what's shown; and how many times in what's hidden),
    /// with the lines they're on.
    public func has(_ text: String, caseSensitive: Bool = false, wholeWords: Bool = false) throws -> [String: Any] {
        try js(Self.hasJS(text, caseSensitive: caseSensitive, wholeWords: wholeWords))
    }

    /// Where things named so are on the page: each with what it is, whether it can be clicked,
    /// whether it's in view (or above, below, or inside something closed), and what it's in.
    public func find(_ text: String, limit: Int = 10) throws -> [String: Any] {
        try js(Self.findJS(text, limit: limit, highlight: nil))
    }

    /// Shows the person where it is: scrolls it into view and rings it for a few seconds (or
    /// rings the closed menu it's inside, to open first). Changes nothing on the page.
    public func highlight(_ text: String, seconds: Double = 4) throws -> [String: Any] {
        try js(Self.findJS(text, limit: 5, highlight: max(1, min(30, seconds))))
    }

    /// The page's outline: headings, landmarks, links, buttons and fields, by name.
    public func outline() throws -> [String: Any] {
        try js(Self.outlineJS)
    }

    /// Opens an address in a new tab of the front window (a window of its own when there's none;
    /// Chrome itself when it's closed), brings Chrome forward, and waits up to 15 seconds for it to
    /// load: the tab it's in. `newTab: false` opens it in the tab in front instead.
    public func open(_ url: String, newTab: Bool = true) throws -> Tab {
        let out = try call(Self.openScript, [url, newTab ? "new" : "front"])
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 3 else { throw ChromeError(.failed, "Chrome gave back something unexpected: \(out)") }
        return Tab(title: parts[0], url: parts[1], loading: parts[2] == "true", window: 1, index: Int(parts.count > 3 ? parts[3] : "") ?? 1, active: true)
    }

    // MARK: talking to Chrome

    func call(_ script: String, _ args: [String]) throws -> String {
        let out = try run(script, args)
        let t = out.trimmingCharacters(in: .newlines)
        switch t {
        case "TMR_NOT_RUNNING": throw ChromeError(.notRunning, "Google Chrome isn't open.", fix: "Open Chrome and the page (POST /api/browser/open {\"url\"} does), then ask again.")
        case "TMR_NO_WINDOW": throw ChromeError(.noWindow, "Chrome has no window open.", fix: "Open a page in Chrome, then ask again.")
        default: return t
        }
    }

    /// What `osascript` said when it failed, as a mistake with its fix.
    public static func explain(_ err: String) -> ChromeError {
        if err.contains("JavaScript through AppleScript is turned off") || err.contains("Allow JavaScript from Apple Events") {
            return ChromeError(.javascriptOff, "Chrome doesn't let apps read inside its pages yet (the title and address still work).",
                               fix: "Once, in Chrome: View > Developer > Allow JavaScript from Apple Events.")
        }
        if err.contains("-1743") || err.contains("Not authorized") || err.contains("not allowed to send") {
            return ChromeError(.notAllowed, "macOS hasn't let Tool Mac Tool Run control Chrome.",
                               fix: "System Settings > Privacy & Security > Automation > Tool Mac Tool Run > turn on Google Chrome.")
        }
        if err.contains("-10814") || err.contains("-2700") || err.contains("Can’t get application id") || err.contains("Can't get application id") {
            return ChromeError(.noChrome, "Google Chrome isn't on this Mac.", fix: "brew install --cask google-chrome (or download it from google.com/chrome).")
        }
        if err.contains("-1712") || err.contains("timed out") {
            return ChromeError(.timedOut, "Chrome didn't answer in time.", fix: "If macOS is asking whether the app may control Chrome, answer it; then ask again.")
        }
        return ChromeError(.failed, "Chrome said: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// The real runner: `osascript -` with the script as its input, giving up after 30 seconds
    /// (the first time, macOS's question may be waiting for an answer).
    public static let osascript: Runner = { script, args in
        let tool = "/usr/bin/osascript"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw ChromeError(.notAvailable, "Reading Chrome's page needs macOS (osascript).")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-"] + args
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        // Read as it comes, so a long answer doesn't fill the pipe and stall it.
        let outBox = DataBox(), errBox = DataBox()
        let reading = DispatchGroup()
        for (pipe, box) in [(output, outBox), (errors, errBox)] {
            reading.enter()
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                reading.leave()
            }
        }
        if done.wait(timeout: .now() + 30) == .timedOut {
            p.terminate()
            throw ChromeError(.timedOut, "Chrome didn't answer in 30 seconds.", fix: "If macOS is asking whether the app may control Chrome, answer it; then ask again.")
        }
        reading.wait()
        let out = String(decoding: outBox.data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw explain(String(decoding: errBox.data, as: UTF8.self) + out) }
        return out
    }

    // MARK: the AppleScript

    static let frontScript = """
    on run argv
      if not (application id "com.google.Chrome" is running) then return "TMR_NOT_RUNNING"
      tell application id "com.google.Chrome"
        if (count of windows) = 0 then return "TMR_NO_WINDOW"
        set t to active tab of front window
        return (title of t) & linefeed & (URL of t) & linefeed & ((loading of t) as text) & linefeed & ((active tab index of front window) as text)
      end tell
    end run
    """

    static let openScript = """
    on run argv
      set u to item 1 of argv
      tell application id "com.google.Chrome"
        if (count of windows) = 0 then
          make new window
          set URL of active tab of front window to u
        else if item 2 of argv is "new" then
          tell front window to make new tab with properties {URL:u}
        else
          set URL of active tab of front window to u
        end if
        activate
        set t to active tab of front window
        repeat 60 times
          if not (loading of t) then exit repeat
          delay 0.25
        end repeat
        return (title of t) & linefeed & (URL of t) & linefeed & ((loading of t) as text) & linefeed & ((active tab index of front window) as text)
      end tell
    end run
    """

    static let tabsScript = """
    on run argv
      if not (application id "com.google.Chrome" is running) then return "TMR_NOT_RUNNING"
      tell application id "com.google.Chrome"
        if (count of windows) = 0 then return "TMR_NO_WINDOW"
        set rows to {}
        if item 1 of argv is "all" then
          set shown to windows
        else
          set shown to {front window}
        end if
        set w to 0
        repeat with win in shown
          set w to w + 1
          set k to 0
          set a to active tab index of win
          repeat with t in tabs of win
            set k to k + 1
            if k = a then
              set isActive to "1"
            else
              set isActive to "0"
            end if
            set end of rows to (w as text) & tab & (k as text) & tab & isActive & tab & (title of t) & tab & (URL of t)
          end repeat
        end repeat
      end tell
      set AppleScript's text item delimiters to linefeed
      return rows as text
    end run
    """

    static let jsScript = """
    on run argv
      if not (application id "com.google.Chrome" is running) then return "TMR_NOT_RUNNING"
      tell application id "com.google.Chrome"
        if (count of windows) = 0 then return "TMR_NO_WINDOW"
        return execute active tab of front window javascript (item 1 of argv)
      end tell
    end run
    """

    // MARK: the JavaScript

    /// A value as a JavaScript literal (JSON is one).
    static func literal(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])) ?? Data("[null]".utf8)
        let s = String(decoding: data, as: UTF8.self)
        return String(s.dropFirst().dropLast())
    }

    /// Shared helpers: clean text, an element's name (as a person would say it), whether it's shown.
    static let helpers = #"""
    const clean = s => (s || '').replace(/ /g, ' ').replace(/[ \t\r]+/g, ' ').replace(/\n\s*\n+/g, '\n').trim();
    const fold = s => clean(s).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
    const shown = el => { if (!el || !el.getClientRects || el.getClientRects().length === 0) return false; const st = getComputedStyle(el); return st.visibility !== 'hidden' && st.display !== 'none' && el.closest('[aria-hidden="true"]') === null; };
    const nameOf = el => clean(el.getAttribute && (el.getAttribute('aria-label') || '') || (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' ? (el.labels && el.labels[0] ? el.labels[0].innerText : '') || el.placeholder || el.value : '') || el.innerText || el.textContent || el.getAttribute('title') || el.getAttribute('alt') || '').slice(0, 200);
    const clickable = el => !!el.closest('a[href], button, [role=button], [role=link], [role=menuitem], [role=tab], [role=treeitem], [role=option], summary, label, input, select, textarea, [onclick], [tabindex]:not([tabindex="-1"])');
    const kindOf = el => { const r = el.getAttribute('role'); if (r) return r; const t = el.tagName.toLowerCase(); return ({a: 'link', button: 'button', input: (el.type || 'text') + ' field', textarea: 'text field', select: 'menu', summary: 'disclosure', h1: 'heading', h2: 'heading', h3: 'heading', h4: 'heading', h5: 'heading', h6: 'heading', li: 'list item', img: 'image', label: 'label'})[t] || t; };
    const landmark = el => { const names = []; for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) { const t = p.tagName.toLowerCase(); const r = p.getAttribute('role'); const lm = r && /^(navigation|banner|main|complementary|contentinfo|menu|menubar|dialog|tablist|tree|region|search)$/.test(r) ? r : ({nav: 'navigation', header: 'banner', main: 'main', aside: 'complementary', footer: 'contentinfo', dialog: 'dialog'})[t]; if (lm) { const label = clean(p.getAttribute('aria-label') || (p.querySelector('h1,h2,h3,h4') || {}).innerText || '').slice(0, 60); names.push(label ? lm + ' “' + label + '”' : lm); } } return names.slice(0, 3); };
    const where = el => { const r = el.getBoundingClientRect(); if (r.bottom < 0) return 'above (scroll up)'; if (r.top > innerHeight) return 'below (scroll down)'; if (r.right < 0 || r.left > innerWidth) return 'off to the side'; return 'in view'; };
    const side = el => { const r = el.getBoundingClientRect(); const x = (r.left + r.right) / 2, y = (r.top + r.bottom) / 2; const h = x < innerWidth / 3 ? 'left' : x > innerWidth * 2 / 3 ? 'right' : 'middle'; const v = y < innerHeight / 3 ? 'top' : y > innerHeight * 2 / 3 ? 'bottom' : 'middle'; return v === 'middle' && h === 'middle' ? 'the middle' : v === 'middle' ? 'the ' + h : h === 'middle' ? 'the ' + v : 'the ' + v + ' ' + h; };
    """#

    static func pageJS(max: Int) -> String {
        helpers + """
        const max = \(max);
        const body = document.body ? clean(document.body.innerText) : '';
        const sel = clean(String(getSelection() || ''));
        const desc = document.querySelector('meta[name=description]');
        const scope = document.querySelector('main, [role=main], article') || document.body;
        const links = [], seenLinks = new Set();
        for (const a of scope ? scope.querySelectorAll('a[href]') : []) { if (links.length >= 40) break; if (!shown(a) || !/^https?:/.test(a.href) || seenLinks.has(a.href)) continue; const t = nameOf(a).split('\\n')[0].slice(0, 80); if (!t) continue; seenLinks.add(a.href); links.push({text: t, url: a.href}); }
        return {title: document.title, url: location.href, host: location.host, text: body.slice(0, max), chars: body.length, truncated: body.length > max, links: links,
                language: document.documentElement.lang || '', description: desc ? clean(desc.content).slice(0, 300) : '', selection: sel.slice(0, 5000),
                scroll: {top: Math.round(scrollY), height: Math.round(document.documentElement.scrollHeight), viewport: innerHeight},
                focused: document.activeElement && document.activeElement !== document.body ? nameOf(document.activeElement).slice(0, 100) : ''};
        """
    }

    static func hasJS(_ text: String, caseSensitive: Bool, wholeWords: Bool) -> String {
        helpers + """
        const want = \(literal(text)), cs = \(caseSensitive), whole = \(wholeWords);
        const norm = s => cs ? clean(s).normalize('NFD').replace(/[\\u0300-\\u036f]/g, '') : fold(s);
        const esc = s => s.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
        const w = norm(want);
        const re = new RegExp((whole ? '(?<![\\\\p{L}\\\\p{N}_])' : '') + esc(w) + (whole ? '(?![\\\\p{L}\\\\p{N}_])' : ''), 'gu');
        const visible = document.body ? document.body.innerText : '';
        const all = document.body ? document.body.textContent : '';
        const count = s => (norm(s).match(re) || []).length;
        const shownCount = w ? count(visible) : 0;
        const lines = [];
        for (const line of visible.split('\\n')) { if (lines.length >= 5) break; if (w && norm(line).match(re)) lines.push(clean(line).slice(0, 240)); }
        const hidden = Math.max(0, (w ? count(all) : 0) - shownCount);
        return {text: want, present: shownCount > 0, count: shownCount, hidden: hidden, lines: lines, title: document.title, url: location.href};
        """
    }

    static func findJS(_ text: String, limit: Int, highlight: Double?) -> String {
        let hl = highlight.map { "\($0)" } ?? "0"
        return helpers + """
        const want = fold(\(literal(text))), limit = \(limit), seconds = \(hl);
        if (!want) return {text: '', count: 0, found: []};
        const owns = el => { for (const c of el.children) { if (fold(nameOf(c)).includes(want)) return false; } return true; };
        const seen = new Set(), hits = [];
        for (const el of document.body ? document.body.querySelectorAll('*') : []) {
          if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|SVG|PATH|HTML|BODY)$/i.test(el.tagName)) continue;
          const n = fold(nameOf(el));
          if (!n.includes(want) || !owns(el)) continue;
          let target = el;
          for (let p = el, k = 0; p && k < 4; p = p.parentElement, k++) { if (p.matches && p.matches('a[href], button, [role=button], [role=link], [role=menuitem], [role=tab], [role=treeitem], [role=option], summary, label, input, select, textarea')) { target = p; break; } }
          if (seen.has(target)) continue;
          seen.add(target);
          hits.push(target);
          if (hits.length > 200) break;
        }
        const closedAround = el => { for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) { if (p.tagName === 'DETAILS' && !p.open) return p.querySelector('summary') || p; } const id = el.closest('[id]') && el.closest('[id]').id; const ctl = id ? document.querySelector('[aria-controls="' + CSS.escape(id) + '"][aria-expanded="false"]') : null; if (ctl) return ctl; for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) { const prev = p.previousElementSibling; if (prev && prev.getAttribute && prev.getAttribute('aria-expanded') === 'false') return prev; } return null; };
        const items = hits.map(el => {
          const n = nameOf(el), f = fold(n), vis = shown(el), r = el.getBoundingClientRect();
          const closed = vis ? null : closedAround(el);
          return {el: el, closed: closed, info: {text: n, kind: kindOf(el), clickable: clickable(el), exact: f === want, starts: f.startsWith(want), shown: vis,
            where: vis ? where(el) : (closed ? 'inside “' + nameOf(closed).slice(0, 60) + '”, which is closed: open it first' : 'hidden'),
            side: vis ? side(el) : '', in: landmark(el), href: el.href || '', box: vis ? {x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height)} : null}};
        });
        items.sort((a, b) => (b.info.exact - a.info.exact) || (b.info.starts - a.info.starts) || (b.info.shown - a.info.shown) || ((b.info.where === 'in view') - (a.info.where === 'in view')) || (b.info.clickable - a.info.clickable) || (a.info.text.length - b.info.text.length));
        const out = {text: \(literal(text)), count: items.length, found: items.slice(0, limit).map(i => i.info), title: document.title, url: location.href};
        if (seconds > 0) {
          const best = items.find(i => i.info.shown) || items.find(i => i.closed);
          if (!best) { out.highlighted = false; out.said = 'It isn\\'t on this page.'; return out; }
          const el = best.info.shown ? best.el : best.closed;
          el.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'smooth'});
          const ring = document.createElement('div');
          const label = document.createElement('div');
          const place = () => { const r = el.getBoundingClientRect(); Object.assign(ring.style, {left: (r.left - 6) + 'px', top: (r.top - 6) + 'px', width: (r.width + 12) + 'px', height: (r.height + 12) + 'px'}); Object.assign(label.style, {left: Math.max(4, r.left - 6) + 'px', top: Math.max(4, r.top - 34) + 'px'}); };
          Object.assign(ring.style, {position: 'fixed', zIndex: 2147483647, pointerEvents: 'none', border: '3px solid #ff3b30', borderRadius: '10px', boxShadow: '0 0 0 4px rgba(255,59,48,.25), 0 0 24px rgba(255,59,48,.6)', transition: 'opacity .4s'});
          Object.assign(label.style, {position: 'fixed', zIndex: 2147483647, pointerEvents: 'none', background: '#ff3b30', color: '#fff', font: '600 13px -apple-system, system-ui, sans-serif', padding: '4px 8px', borderRadius: '6px', transition: 'opacity .4s'});
          label.textContent = best.info.shown ? 'Here: ' + best.info.text.slice(0, 60) : 'Open this first: ' + nameOf(el).slice(0, 60);
          document.documentElement.appendChild(ring); document.documentElement.appendChild(label);
          let tick = 0; const timer = setInterval(() => { place(); ring.style.opacity = (tick++ % 10 < 5) ? '1' : '0.55'; }, 100);
          place();
          setTimeout(() => { clearInterval(timer); ring.style.opacity = '0'; label.style.opacity = '0'; setTimeout(() => { ring.remove(); label.remove(); }, 500); }, seconds * 1000);
          out.highlighted = true;
          out.target = best.info.shown ? best.info : {text: nameOf(el), kind: kindOf(el), opens: best.info.text};
          out.said = best.info.shown ? 'It’s ringed in red on the page, ' + (best.info.where === 'in view' ? 'at ' + best.info.side : 'scrolled into view') + '.' : 'It’s inside “' + nameOf(el).slice(0, 60) + '”, which is closed: that’s ringed in red, to open first.';
        }
        return out;
        """
    }

    static let outlineJS = helpers + """
    const take = (sel, n, f) => { const out = []; for (const el of document.querySelectorAll(sel)) { if (out.length >= n) break; if (!shown(el)) continue; const v = f(el); if (v && !out.some(o => JSON.stringify(o) === JSON.stringify(v))) out.push(v); } return out; };
    return {
      title: document.title, url: location.href,
      headings: take('h1, h2, h3', 40, el => ({level: +el.tagName[1], text: nameOf(el).slice(0, 120)})),
      landmarks: take('nav, header, main, aside, footer, [role=navigation], [role=banner], [role=main], [role=complementary], [role=search], [role=menubar], [role=tablist]', 15, el => ({kind: kindOf(el) === 'nav' ? 'navigation' : kindOf(el), label: clean(el.getAttribute('aria-label') || (el.querySelector('h1,h2,h3,h4') || {}).innerText || '').slice(0, 60)})),
      navigation: take('nav a[href], [role=navigation] a[href], aside a[href], [role=menuitem], [role=tab], [role=treeitem]', 80, el => nameOf(el).split('\\n')[0].slice(0, 60)),
      buttons: take('button, [role=button], input[type=submit], input[type=button]', 60, el => nameOf(el).split('\\n')[0].slice(0, 60)),
      fields: take('input:not([type=hidden]):not([type=submit]):not([type=button]), textarea, select', 30, el => ({name: nameOf(el).slice(0, 60) || el.name || '', kind: kindOf(el)})),
      links: take('main a[href], [role=main] a[href]', 60, el => ({text: nameOf(el).split('\\n')[0].slice(0, 80), href: el.href}))
    };
    """
}

/// What went wrong reading Chrome's page, in words, with the fix.
public struct ChromeError: Error, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case notRunning = "chrome_not_open"
        case noWindow = "no_window"
        case javascriptOff = "javascript_off"
        case notAllowed = "not_allowed"
        case noChrome = "no_chrome"
        case notAvailable = "not_available"
        case timedOut = "timed_out"
        case pageError = "page_error"
        case failed
    }

    public var code: Code
    public var message: String
    public var fix: String?

    public init(_ code: Code, _ message: String, fix: String? = nil) {
        self.code = code
        self.message = message
        self.fix = fix
    }

    public var description: String { fix.map { "\(message) \($0)" } ?? message }

    public var status: Int {
        switch code {
        case .notRunning, .noWindow, .noChrome: 409
        case .javascriptOff, .notAllowed: 403
        case .notAvailable: 501
        case .timedOut: 504
        case .pageError, .failed: 502
        }
    }
}

/// Bytes read on another thread.
final class DataBox: @unchecked Sendable {
    var data = Data()
}
