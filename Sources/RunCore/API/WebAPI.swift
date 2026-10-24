import Foundation

/// The web, read from this Mac (`/api/web…`): a search, and any address read as text (a page's
/// text and links, a JSON API's answer). Answered at once, without asking on the Mac: it only
/// reads, GET only, and never reaches this Mac or its local network.
extension RunAPI {
    static let webRoutes: [(method: String, path: String, summary: String, tags: String)] = [
        ("GET", "/api/web", "what the web routes do", "info how"),
        ("GET", "/api/web/search", "search the web: ?q=words (?limit=8): each result's title, address and words, answered at once",
         "search google web online internet look up lookup find question answer news price weather results duckduckgo bing"),
        ("GET", "/api/web/fetch", "read an address: ?url=https://… (?find=words: the lines that have them; ?max=8000 characters): a page's title, text and links, a JSON API's answer, or text; answered at once",
         "fetch read open get page url address website site link download api json http browse curl request weather"),
    ]

    func webRoute(_ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        try need(.web, s)
        let method = req.method == "HEAD" ? "GET" : req.method
        let f = LibraryAPI.Fields(values: try fields(req))
        let web = self.web
        switch path {
        case "/api/web":
            return JSON.response(["about": "The web, read from this Mac: search it, and read any address (a page's text and links, a JSON API's answer). It only reads (GET), sends nothing but the address, keeps no cookies, and never reaches this Mac or its local network. Answered at once.",
                                  "routes": Self.webRoutes.map { ["method": $0.method, "path": $0.path, "summary": $0.summary] }])
        case "/api/web/search":
            guard method == "GET" || method == "POST" else { throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes GET") }
            let q = f.text("q") ?? f.text("query") ?? f.text("text") ?? ""
            let limit = f.int("limit") ?? 8
            return await logged("web", "search", f, req) {
                let out = try await web.search(q, limit: limit)
                return .json(out, summary: "searched \"\(q)\": \(out["count"] ?? 0)")
            }
        case "/api/web/fetch", "/api/web/read", "/api/web/open":
            guard method == "GET" || method == "POST" else { throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes GET") }
            let url = f.text("url") ?? f.text("address") ?? f.text("link") ?? ""
            let max = Swift.max(200, Swift.min(100_000, f.int("max") ?? 8000))
            return await logged("web", "fetch", f, req) {
                let out = try await web.read(url, max: max, find: f.text("find") ?? f.text("q"))
                return .json(out, summary: "read \(out["url"] as? String ?? url)")
            }
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET /api/web lists the web's routes)")
        }
    }
}
