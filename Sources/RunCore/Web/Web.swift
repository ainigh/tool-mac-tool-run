import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The web, read from this Mac without Chrome: a search (the results' titles, addresses and
/// words), and any address fetched and made readable (a page's title, its text and its links; a
/// JSON API's answer; plain text). It only ever reads: GET, nothing sent but the address, no
/// cookies, nothing of this Mac's own or its local network. It's what a model finds things out
/// with by itself, the way a person would: search, open the best result, read, follow a link or
/// the API a page points to.
public struct Web: Sendable {
    /// What came back from an address: its bytes, status, media type and final address.
    public struct Fetched: Sendable {
        public var data: Data
        public var status: Int
        public var contentType: String
        public var url: URL

        public init(data: Data, status: Int, contentType: String, url: URL) {
            self.data = data
            self.status = status
            self.contentType = contentType
            self.url = url
        }
    }

    /// Fetches one address (GET); throws `WebError`.
    public typealias Fetcher = @Sendable (URL) async throws -> Fetched

    let fetcher: Fetcher

    public init(fetch: @escaping Fetcher = Web.live) {
        fetcher = fetch
    }

    /// The most read of an answer (bigger ones are cut there).
    public static let maxBytes = 4 * 1024 * 1024

    /// A browser's way of asking, so sites answer as they would a person.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36 ToolMacToolRun"

    // MARK: fetching

    /// An address, checked: http or https, somewhere on the internet (never this Mac or its network).
    public static func address(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw WebError(.badURL, "Say which address: \"url\" (https://example.com).") }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? s),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty
        else { throw WebError(.badURL, "\(raw) isn't a web address: give one like https://example.com/page.") }
        if isLocal(host) {
            throw WebError(.local, "\(host) is this Mac or its local network, which the web tools never reach.",
                           fix: "Give an address on the internet. (Tool Mac Tool Run's own API, and this Mac's files, have routes of their own.)")
        }
        return url
    }

    /// This Mac, its local network, or a name only it knows (localhost, 192.168.x.x, printer.local…).
    public static func isLocal(_ host: String) -> Bool {
        var h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") { return true }
        if h.contains(":") {
            // IPv6: loopback, unspecified, unique local (fc00::/7), link local (fe80::/10), IPv4 mapped.
            return h == "::1" || h == "::" || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")
                || h.hasPrefix("::ffff:")
        }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if parts.count == 4, parts.allSatisfy({ $0 != nil && $0! >= 0 && $0! <= 255 }) {
            let a = parts[0]!, b = parts[1]!
            return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b))
        }
        // A bare number (http://2130706433) is an address too.
        return Int(h) != nil
    }

    /// The real fetch: GET, a browser's User-Agent, 20 seconds, redirects followed only to the internet.
    public static let live: Fetcher = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        let guardian = Redirects()
        let session = URLSession(configuration: .ephemeral, delegate: guardian, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            session.dataTask(with: request) { data, response, error in
                if let refused = guardian.refused {
                    c.resume(throwing: WebError(.local, "\(url.host ?? "It") sent the request on to \(refused), on this Mac or its local network, which the web tools never reach."))
                } else if let error {
                    let e = error as NSError
                    let timedOut = e.code == NSURLErrorTimedOut
                    c.resume(throwing: WebError(timedOut ? .timedOut : .unreachable,
                                                timedOut ? "\(url.host ?? "The site") didn't answer in 20 seconds." : "Couldn't reach \(url.host ?? "it"): \(e.localizedDescription)",
                                                fix: "Check the address, or try another site; is this Mac on the internet?"))
                } else if let http = response as? HTTPURLResponse {
                    var d = data ?? Data()
                    if d.count > maxBytes { d = d.prefix(maxBytes) }
                    c.resume(returning: Fetched(data: d, status: http.statusCode, contentType: (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
                                                url: http.url ?? url))
                } else {
                    c.resume(throwing: WebError(.unreachable, "\(url.host ?? "The site") gave back nothing."))
                }
            }.resume()
        }
    }

    /// Follows a redirect only to the internet.
    final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var refused: String?

        // The SDK's handler is @Sendable on a Mac (a signature that differs is never called there).
        #if canImport(Darwin)
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(follow(request))
        }
        #else
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(follow(request))
        }
        #endif

        /// The request, or nil (it isn't followed) when it goes to this Mac or its network.
        func follow(_ request: URLRequest) -> URLRequest? {
            guard let host = request.url?.host, !Web.isLocal(host), ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "") else {
                refused = request.url?.host ?? request.url?.absoluteString ?? "somewhere else"
                return nil
            }
            return request
        }
    }

    // MARK: reading an address

    /// An address read: a page's title, description, text and links; a JSON answer; or text.
    /// `max`: characters of text at most. `find`: words, for the lines that have them.
    public func read(_ raw: String, max: Int = 8000, find: String? = nil, links: Int = 40) async throws -> [String: Any] {
        let url = try Self.address(raw)
        let got = try await fetcher(url)
        let text = Self.decode(got.data, contentType: got.contentType)
        var out: [String: Any] = ["url": got.url.absoluteString, "status": got.status, "type": got.contentType.split(separator: ";").first.map(String.init) ?? ""]
        if got.url != url { out["asked"] = url.absoluteString }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: String
        if got.contentType.contains("json") || ((trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && !got.contentType.contains("html")),
           let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
            out["kind"] = "json"
            let pretty = (try? JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
                .map { String(decoding: $0, as: UTF8.self) } ?? trimmed
            if pretty.count <= max { out["json"] = parsed }
            body = pretty
        } else if got.contentType.contains("html") || trimmed.prefix(600).lowercased().contains("<html") || trimmed.prefix(600).lowercased().contains("<!doctype html") {
            let page = Readable(html: text, base: got.url)
            out["kind"] = "page"
            out["title"] = page.title
            if !page.description.isEmpty { out["description"] = page.description }
            let shown = page.links.prefix(links)
            out["links"] = shown.map { ["text": $0.text, "url": $0.url] }
            if page.links.count > shown.count { out["more_links"] = page.links.count - shown.count }
            body = page.text
        } else if got.contentType.hasPrefix("image/") || got.contentType.hasPrefix("video/") || got.contentType.hasPrefix("audio/") || got.contentType.contains("pdf") || got.contentType.contains("octet-stream") {
            out["kind"] = "file"
            out["bytes"] = got.data.count
            out["note"] = "It's a \(out["type"] ?? "file"), not text: there's nothing here to read."
            body = ""
        } else {
            out["kind"] = "text"
            body = text
        }
        out["chars"] = body.count
        out["text"] = String(body.prefix(max))
        out["truncated"] = body.count > max
        if body.count > max { out["more"] = "\(body.count - max) more characters: ask with \"find\" (words) for the lines that have them, or a larger \"max\"" }
        if let find, !find.trimmingCharacters(in: .whitespaces).isEmpty {
            let lines = Self.lines(of: body, with: find)
            out["find"] = find
            out["lines"] = lines
            if lines.isEmpty { out["found"] = false }
        }
        if got.status >= 400 { out["problem"] = "The site answered \(got.status)\(got.status == 404 ? " (no such page)" : got.status == 403 || got.status == 429 ? " (it turned the request away)" : "")." }
        return out
    }

    /// The lines that have any of the words (the most of them first), at most 25.
    static func lines(of text: String, with words: String) -> [String] {
        let wanted = APISearch.query(words)
        guard !wanted.isEmpty else { return [] }
        var scored: [(Int, Int, String)] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let have = Set(APISearch.words(line))
            let n = wanted.filter { w in have.contains(w) || have.contains { $0.hasPrefix(w) } }.count
            if n > 0 { scored.append((n, i, String(line.prefix(400)))) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.prefix(25).sorted { $0.1 < $1.1 }.map(\.2)
    }

    /// Bytes as text, by the charset the answer or the page says (UTF-8 otherwise, Latin-1 last).
    static func decode(_ data: Data, contentType: String) -> String {
        var charset = contentType.components(separatedBy: "charset=").dropFirst().first?.split(separator: ";").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased() }
        if charset == nil, let head = String(data: data.prefix(2048), encoding: .isoLatin1)?.lowercased(), let r = head.range(of: "charset=") {
            charset = String(head[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
        switch charset {
        case "iso-8859-1", "latin1", "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        default:
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: searching

    /// A web search: the results, each its title, address and the words under it. DuckDuckGo
    /// first, Bing if it gives nothing.
    public func search(_ q: String, limit: Int = 8) async throws -> [String: Any] {
        let words = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw WebError(.badRequest, "Say what to search for: \"q\" (a few words).") }
        let encoded = words.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? words
        var tried: [String] = []
        for engine in ["duckduckgo", "bing"] {
            let url = URL(string: engine == "duckduckgo" ? "https://html.duckduckgo.com/html/?q=\(encoded)" : "https://www.bing.com/search?q=\(encoded)&setlang=en")!
            do {
                let got = try await fetcher(url)
                let html = Self.decode(got.data, contentType: got.contentType)
                let results = engine == "duckduckgo" ? Self.duckDuckGo(html) : Self.bing(html)
                if !results.isEmpty {
                    let shown = results.prefix(Swift.max(1, Swift.min(20, limit)))
                    return ["q": words, "engine": engine, "count": shown.count,
                            "results": shown.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet] },
                            "lines": shown.enumerated().map { "\($0.offset + 1). \($0.element.title) — \($0.element.url)\($0.element.snippet.isEmpty ? "" : "\n   \($0.element.snippet)")" }]
                }
                tried.append("\(engine) gave no results (\(got.status))")
            } catch let e as WebError {
                tried.append("\(engine): \(e.message)")
            }
        }
        throw WebError(.searchFailed, "The web search found nothing (\(tried.joined(separator: "; "))).",
                       fix: "Try other words; or fetch a site's own search page, such as https://en.wikipedia.org/w/index.php?search=\(encoded)")
    }

    public struct Result: Equatable, Sendable {
        public var title: String
        public var url: String
        public var snippet: String
    }

    /// DuckDuckGo's HTML results: each result's link (its address in `uddg`), title and snippet; no ads.
    static func duckDuckGo(_ html: String) -> [Result] {
        var out: [Result] = []
        for m in Readable.matches(#"<a\b([^>]*)>(.*?)</a>"#, in: html) {
            let attrs = m[1], inner = m[2]
            if attrs.contains("result__a") {
                guard var href = Readable.attribute("href", in: attrs) else { continue }
                if href.contains("duckduckgo.com/y.js") || href.contains("ad_domain") { continue }
                if let r = href.range(of: "uddg=") {
                    let v = href[r.upperBound...].prefix { $0 != "&" }
                    href = String(v).removingPercentEncoding ?? String(v)
                }
                if href.hasPrefix("//") { href = "https:" + href }
                guard href.hasPrefix("http") else { continue }
                out.append(Result(title: Readable.inline(inner), url: href, snippet: ""))
            } else if attrs.contains("result__snippet"), !out.isEmpty, out[out.count - 1].snippet.isEmpty {
                out[out.count - 1].snippet = Readable.inline(inner)
            }
        }
        var seen: Set<String> = []
        return out.filter { !$0.title.isEmpty && seen.insert($0.url).inserted }
    }

    /// Bing's results: each `li.b_algo`'s heading link and first paragraph.
    static func bing(_ html: String) -> [Result] {
        var out: [Result] = []
        for block in html.components(separatedBy: "class=\"b_algo\"").dropFirst() {
            let item = block.components(separatedBy: "</li>").first ?? block
            guard let link = Readable.matches(#"<h2[^>]*>.*?<a\b([^>]*)>(.*?)</a>"#, in: item).first, var href = Readable.attribute("href", in: link[1]) else { continue }
            // Bing's own redirect: the address is in u=a1<base64>.
            if href.contains("bing.com/ck/a"), let r = href.range(of: "u=a1") {
                var b64 = String(href[r.upperBound...].prefix { $0 != "&" }).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                if let d = Data(base64Encoded: b64), let real = String(data: d, encoding: .utf8) { href = real }
            }
            guard href.hasPrefix("http") else { continue }
            let snippet = Readable.matches(#"<p\b[^>]*>(.*?)</p>"#, in: item).first.map { Readable.inline($0[1]) } ?? ""
            out.append(Result(title: Readable.inline(link[2]), url: href, snippet: snippet))
        }
        return out.filter { !$0.title.isEmpty }
    }
}

/// What went wrong on the web, in words, with the fix.
public struct WebError: Error, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case badURL = "bad_url"
        case local = "local_address"
        case unreachable
        case timedOut = "timed_out"
        case searchFailed = "search_failed"
        case badRequest = "bad_request"
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
        case .badURL, .badRequest: 400
        case .local: 403
        case .unreachable, .searchFailed: 502
        case .timedOut: 504
        }
    }
}

/// A page made readable: its title, description, the text a person reads (scripts, styles and
/// the like left out; its main part, when it marks one), and its links with whole addresses.
public struct Readable {
    public var title = ""
    public var description = ""
    public var text = ""
    public var links: [(text: String, url: String)] = []

    public init(html: String, base: URL) {
        var h = Self.replace(#"<!--.*?-->"#, in: html, with: " ")
        title = Self.matches(#"<title\b[^>]*>(.*?)</title>"#, in: h).first.map { Self.inline($0[1]) } ?? ""
        for m in Self.matches(#"<meta\b([^>]*)>"#, in: h) {
            let attrs = m[1].lowercased()
            if attrs.contains("name=\"description\"") || attrs.contains("property=\"og:description\"") || attrs.contains("name='description'"),
               let content = Self.attribute("content", in: m[1]) {
                description = Self.inline(content)
                break
            }
        }
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "head", "object", "canvas"] {
            h = Self.replace("<\(tag)\\b[^>]*>.*?</\(tag)>", in: h, with: " ")
        }
        // Menus aren't what a page says: its navigation and footer, and lists that are only links
        // (a site's menu, a page's 150 languages).
        for tag in ["nav", "footer"] { h = Self.replace("<\(tag)\\b[^>]*>.*?</\(tag)>", in: h, with: " ") }
        h = Self.dropLinkLists(h)
        // Its main part, when the page marks one with enough in it; else the whole of it.
        var part = h
        for pattern in [#"<main\b[^>]*>(.*)</main>"#, #"<article\b[^>]*>(.*)</article>"#, #"<[a-z]+\b[^>]*role=["']main["'][^>]*>(.*)"#] {
            if let m = Self.matches(pattern, in: h).first, Self.inline(m[1]).count > 400 {
                part = m[1]
                break
            }
        }
        var seen: Set<String> = []
        for m in Self.matches(#"<a\b([^>]*)>(.*?)</a>"#, in: part) {
            guard let href = Self.attribute("href", in: m[1]), !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:"), !href.lowercased().hasPrefix("mailto:"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme ?? "") else { continue }
            var words = Self.inline(m[2])
            if words.isEmpty { words = Self.attribute("aria-label", in: m[1]).map(Self.inline) ?? Self.attribute("title", in: m[1]).map(Self.inline) ?? "" }
            guard !words.isEmpty, seen.insert(url.absoluteString).inserted else { continue }
            links.append((String(words.prefix(100)), url.absoluteString))
        }
        text = Self.text(part)
    }

    /// The lists (innermost first) whose items are each a link and nothing else, when there are
    /// many: menus, not what the page says.
    static func dropLinkLists(_ html: String) -> String {
        guard let re = regex(#"<(ul|ol)\b[^>]*>((?:(?!<(?:ul|ol)\b).)*?)</\1>"#) else { return html }
        let ns = html as NSString
        var out = ""
        var at = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 2))
            let items = matches(#"<li\b[^>]*>(.*?)(?=<li\b|$)"#, in: inner).map { $0[1] }
            let linksOnly = items.filter { item in
                let rest = replace(#"<a\b[^>]*>.*?</a>"#, in: item, with: "")
                return item.range(of: "<a ", options: .caseInsensitive) != nil && inline(rest).count <= 3
            }
            guard items.count >= 8, linksOnly.count * 10 >= items.count * 8 else { continue }
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at)) + " "
            at = m.range.location + m.range.length
        }
        return out + ns.substring(from: at)
    }

    /// HTML as lines of text: a line for each block, "- " for a list item, cells apart with " | ".
    static func text(_ html: String) -> String {
        var t = replace(#"<li\b[^>]*>"#, in: html, with: "\n- ")
        t = replace(#"<(br|hr)\b[^>]*>"#, in: t, with: "\n")
        t = replace(#"</?(p|div|section|article|header|footer|nav|aside|main|h[1-6]|ul|ol|table|tr|thead|tbody|form|fieldset|dl|dt|dd|blockquote|pre|figure|figcaption|details|summary|address)\b[^>]*>"#, in: t, with: "\n")
        t = replace(#"</t[dh]>"#, in: t, with: " | ")
        t = replace(#"<[^>]+>"#, in: t, with: "")
        t = entities(t)
        var lines: [String] = []
        for raw in t.components(separatedBy: "\n") {
            var line = raw.replacingOccurrences(of: "\u{00A0}", with: " ").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
            while line.hasSuffix(" |") { line = String(line.dropLast(2)).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty, line != "-", line != "|" else { continue }
            if lines.last != line { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// A bit of HTML as one line of text.
    static func inline(_ html: String) -> String {
        entities(replace(#"<[^>]+>"#, in: html, with: " ")).replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…",
        "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "middot": "·",
        "bull": "•", "times": "×", "euro": "€", "pound": "£", "yen": "¥", "laquo": "«", "raquo": "»", "frac12": "½", "shy": "",
    ]

    /// &amp; &#39; &#x27; and the common named ones, as the characters they are.
    static func entities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var value: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { value = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else if name.hasPrefix("#") { value = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else { value = named[name.lowercased()] }
                if let value {
                    out += value
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    /// A pattern compiled, its tags' insides read as a browser does: a quoted attribute may hold
    /// a ">" (`data-x='{"a": "<b>"}'`) without ending the tag.
    static func regex(_ pattern: String) -> NSRegularExpression? {
        let quoted = #"(?:[^>"']|"[^"]*"|'[^']*')"#
        let p = pattern.replacingOccurrences(of: "[^>]*>", with: quoted + "*>").replacingOccurrences(of: "<[^>]+>", with: "<" + quoted + "+>")
            .replacingOccurrences(of: "([^>]*)>", with: "(" + quoted + "*)>")
        return try? NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    /// Every match, each as its groups (0: the whole of it).
    static func matches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = regex(pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { k in Range(m.range(at: k), in: s).map { String(s[$0]) } ?? "" }
        }
    }

    static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = regex(pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    /// An attribute's value in a tag's attributes (quoted either way, or not at all).
    static func attribute(_ name: String, in attrs: String) -> String? {
        guard let m = matches(#"(?:^|\s)"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, in: attrs).first else { return nil }
        let v = m[1].isEmpty ? (m[2].isEmpty ? m[3] : m[2]) : m[1]
        return entities(v)
    }
}
