import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Telling a client how its runs went without waiting to be asked. A client says where to tell it
/// (`X-Reply-To`, or `reply_to`, with what it says to `POST /api/say`): an address on this Mac.
/// While it has something waiting or running, the adapter follows it, and the moment one is over
/// the news is POSTed there, as the next reply would have started with it ("Meanwhile: the
/// nightly backup finished (it worked)"), with the requests it's about as JSON. News is told once:
/// what was delivered there isn't told again; what couldn't be (the client wasn't listening) is
/// tried again for a while, and still comes first in its next reply.
extension RunAPI {
    /// The news to a client: `{"client", "text", "entries": [as /api/say/log has them]}`.
    public struct SayNews: Sendable {
        public let url: URL
        public let body: Data
    }

    /// How many times news that couldn't be delivered is tried again (a while apart) before it waits for the next reply.
    static let sayRetries = 40

    /// Where a client said to be told: an http address on this Mac, said from this Mac; nil when
    /// none was said. A refusal says what's wrong.
    static func replyAddress(_ req: HTTPRequest, _ fields: [String: Any]) throws -> URL? {
        guard let said = (req.header("x-reply-to") ?? text(fields["reply_to"]))?.trimmingCharacters(in: .whitespaces), !said.isEmpty else { return nil }
        guard req.fromLoopback else {
            throw HTTPError(status: 403, code: "forbidden", message: "reply_to is taken only from a client on this Mac")
        }
        guard let url = URL(string: said), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw HTTPError(status: 400, code: "bad_request", message: "reply_to is an http address on this Mac, like http://127.0.0.1:8769/api/peter")
        }
        return url
    }

    /// Delivers news: true once the client took it (a 2xx).
    static func deliver(_ news: SayNews) async -> Bool {
        var r = URLRequest(url: news.url, timeoutInterval: 5)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = news.body
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            URLSession.shared.dataTask(with: r) { _, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                done.resume(returning: error == nil && (200..<300).contains(status))
            }.resume()
        }
    }

    /// Follows a client's requests while it has somewhere to be told and something still going:
    /// one watch a client, ended when nothing is left to tell.
    func sayWatch(_ client: String) {
        Task { [self] in
            guard await sayLog.watch(client) else { return }
            var failed = 0
            while true {
                try? await Task.sleep(nanoseconds: sayEvery * (failed > 0 ? 30 : 1))
                guard let url = await sayLog.with(client, { $0.replyTo }) else { break }
                switch await sayPush(client, to: url) {
                case .failed:
                    failed += 1
                    if failed >= Self.sayRetries { await sayLog.unwatch(client); return }
                case .sent, .nothing:
                    failed = 0
                }
                if failed == 0, await sayLog.unwatchIfIdle(client) { return }
            }
            await sayLog.unwatch(client)
        }
    }

    enum SayPushed { case nothing, sent, failed }

    /// The news of the client's requests that are over and not told yet, delivered to `url`: told
    /// once it's taken (told before it's sent, so a reply meanwhile doesn't tell it too, and
    /// untold again when it couldn't be delivered).
    func sayPush(_ client: String, to url: URL) async -> SayPushed {
        var over: [SayLog.Entry] = []
        for var e in await sayLog.entries(client) where e.asks {
            if e.state.open, let id = e.request {
                await sayFollow(&e, id)
                await sayLog.update(client, e.number) { [e] x in x.state = e.state; x.result = e.result; x.ended = e.ended }
            }
            guard !e.state.open, e.state.key != e.told else { continue }
            if e.muted {
                await sayLog.update(client, e.number) { [key = e.state.key] x in x.told = key }
                continue
            }
            over.append(e)
        }
        guard !over.isEmpty else { return .nothing }
        let before = Dictionary(uniqueKeysWithValues: over.map { ($0.number, $0.told) })
        for e in over { await sayLog.update(client, e.number) { [key = e.state.key] x in x.told = key } }
        let lines = over.map { Self.capitalized(Self.newsLine($0)) }
        let text = lines.count == 1 ? "Meanwhile: " + lines[0] : "Meanwhile:\n" + lines.map { "- " + $0 }.joined(separator: "\n")
        let body = JSON.data(["client": client, "text": text, "entries": over.map(Self.sayEntryJSON)])
        if await sayDeliver(SayNews(url: url, body: body)) { return .sent }
        for e in over { await sayLog.update(client, e.number) { [told = before[e.number] ?? nil] x in x.told = told } }
        return .failed
    }

    /// `POST /api/say/stop {"number": 3}`: one of the client's requests called off by its number
    /// in the log (taken back while it waits for the OK, stopped while it runs), as "stop …" would.
    func sayStopRoute(_ fields: [String: Any], client: String, _ req: HTTPRequest, _ s: APISettings) async throws -> HTTPResponse {
        guard let n = Self.text(fields["number"]).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            throw HTTPError(status: 400, code: "bad_request", message: "say which request: {\"number\": 3}, its number in GET /api/say/log")
        }
        guard let e = await sayLog.entries(client).first(where: { $0.number == n }) else {
            throw HTTPError(status: 404, code: "not_found", message: "this client has no request numbered \(n) (GET /api/say/log lists them)")
        }
        let reply = await sayStop(e, SayContext(client: client, req: req, settings: s, forms: []))
        let now = await sayLog.entries(client).first { $0.number == n }
        return JSON.response(["ok": true, "client": client, "number": n, "message": reply.answer, "state": now?.state.key ?? e.state.key])
    }
}
