import Foundation

/// `POST /api/say`: the template adapter, in front of the whole API. A client says what it wants
/// in words and gets words back: no tool names, routes, arguments, ids, polling or JSON. What
/// doesn't match a template yet is taken as a search, answered with the templates that would do
/// it; a filled-in template is recognized (the adapter wrote it, so it knows its fixed words),
/// the real route is called, the request kept in the client's log, and the answer said plainly.
/// Every reply starts with what changed since the client last spoke (the adapter follows its
/// requests itself), then the answer, then what it can say next. The person's consent stays
/// theirs: a run still waits for Run on the Mac, and the reply says so.
extension RunAPI {
    /// One reply, before it's put together: the answer, the templates that usually follow, and
    /// the requests it was about (their news isn't told twice).
    struct SayReply {
        var answer: String
        var next: [SayForm] = []
        var about: [Int] = []
        /// The pages "more" gives after this (nil: none; a long answer's own rest is added).
        var more: [String]? = nil
        /// Already a page: not cut again.
        var paged = false
    }

    /// Who's talking, and everything there is to say to them.
    struct SayContext {
        let client: String
        let req: HTTPRequest
        let settings: APISettings
        let forms: [SayForm]

        func form(_ title: String) -> SayForm? { forms.first { $0.title == title } }
        func forms(_ titles: [String]) -> [SayForm] { titles.compactMap(form) }
    }

    static func plainText(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", data: Data((s.hasSuffix("\n") ? s : s + "\n").utf8))
    }

    /// /api/say, /api/say/forms, /api/say/log, /api/say/stop, /api/say/reset.
    func sayRoute(_ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        let method = req.method == "HEAD" ? "GET" : req.method
        var fields: [String: Any] = req.query
        if req.contentType.hasPrefix("application/json"), !req.body.isEmpty {
            guard let o = JSON.object(req.body) else { throw HTTPError(status: 400, code: "bad_request", message: "send what you want to say as text (Content-Type: text/plain), or {\"text\": \"…\"}") }
            fields.merge(o) { _, b in b }
        }
        let client = Self.client(req, fields)
        switch path {
        case "/api/say":
            if method == "GET" { return Self.plainText(Self.sayHowTo) }
            guard method == "POST" else { throw HTTPError(status: 405, code: "bad_request", message: "/api/say takes POST (what you want, as text) or GET (how to use it)") }
            // Where to tell it how its runs went, without waiting to be asked.
            if let url = try Self.replyAddress(req, fields) { await sayLog.with(client) { $0.replyTo = url } }
            let text: String
            if req.contentType.hasPrefix("application/json") {
                text = Self.text(fields["text"]) ?? Self.text(fields["say"]) ?? Self.text(fields["message"]) ?? Self.text(fields["q"]) ?? ""
            } else {
                text = req.body.isEmpty ? (req.query["text"] ?? req.query["q"] ?? "") : String(decoding: req.body, as: UTF8.self)
            }
            let reply = await say(text, client: client, req, s)
            if await sayLog.needsWatch(client) { sayWatch(client) }
            return Self.plainText(reply)
        case "/api/say/stop":
            guard method == "POST" else { throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes POST") }
            return try await sayStopRoute(fields, client: client, req, s)
        case "/api/say/forms":
            guard method == "GET" else { throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes GET") }
            let forms = SayForms.all(catalog: s.isOn(.catalog) ? await host.catalog() : nil, settings: s)
            let q = (req.query["q"] ?? "").trimmingCharacters(in: .whitespaces)
            let used = await sayLog.with(client) { $0.used }
            let picked = q.isEmpty ? forms : SayForms.search(q, in: forms, used: used, limit: 20)
            if req.query["format"]?.lowercased() == "json" {
                return JSON.response(["ok": true, "count": picked.count, "q": q, "forms": picked.map(\.json),
                                      "note": "What POST /api/say offers and takes. Say a template back with its blanks filled; the title stays the same from version to version."])
            }
            let text = picked.isEmpty ? "No template matches \"\(q)\"." : picked.map(\.template).joined(separator: "\n\n")
            return Self.plainText(text)
        case "/api/say/log":
            guard method == "GET" else { throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes GET") }
            _ = await sayNews(SayContext(client: client, req: req, settings: s, forms: []), tell: false)
            let entries = await sayLog.entries(client)
            return JSON.response(["ok": true, "client": client, "count": entries.count, "entries": entries.reversed().map(Self.sayEntryJSON),
                                  "note": "What this client asked POST /api/say for, newest first (kept a week, the latest 200). A conversation starts again after six hours without a word."])
        case "/api/say/reset":
            guard method == "POST" else { throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes POST") }
            let forget = Self.flag(Self.text(fields["forget"]))
            await sayLog.reset(client, log: forget)
            return JSON.response(["ok": true, "client": client, "forgot_the_log": forget,
                                  "message": forget ? "A fresh start: the conversation and what was asked are forgotten." : "A fresh start: the numbers and anything pending are forgotten; what was asked is kept."])
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (POST /api/say, GET /api/say/forms, GET /api/say/log, POST /api/say/stop, POST /api/say/reset)")
        }
    }

    static func sayEntryJSON(_ e: SayLog.Entry) -> [String: Any] {
        var out: [String: Any] = ["number": e.number, "asked": JSON.date(e.asked), "said": e.said, "template": e.form, "what": e.what,
                                  "state": e.state.key, "shown": e.shown, "muted": e.muted, "waits_for_the_mac": e.asks]
        if let r = e.request { out["request"] = r.uuidString }
        if let ended = e.ended { out["ended"] = JSON.date(ended) }
        if let result = e.result { out["result"] = result }
        return out
    }

    /// What `GET /api/say` says: how to use it, for a person setting a client up.
    static let sayHowTo = """
    Talk to Tool Mac Tool Run in plain words.

    POST /api/say with what you want, as text (Content-Type: text/plain), and say who you are (?client=My App, or an X-Client header). The answer is text too.

    For a model's instructions, this is enough:
      To use the Mac's tools, use say. Say what you want; if it offers templates, fill one in and say it back.

    How it goes:
    - Say what you want. If that isn't one of its templates yet, it answers with a few that would do it, each with blanks: {…} is a blank to fill, [a | b] a choice of one, (optional) a line that may be left out.
    - Copy one, fill the blanks, and say it back. It's done at once, or (a run) put to the person at the Mac, who clicks Run.
    - Every answer starts with what changed since you last spoke ("Meanwhile: the nightly backup finished"). You never poll, keep ids, or read JSON.

    Always there:
      what can you do
      what happened to {something you asked for}
      what have I asked for [today | recently | since {a time}]
      show me {something you asked for}
      more
      stop {something you asked for}
      I'm done with {something you asked for}
      start over

    {something you asked for} is "the last one", a word from it ("the backup"), a time ("the one around 3"), or a number from the last list ("the second one").

    To be told how a run went the moment it's over, rather than in your next answer, say where (X-Reply-To: http://127.0.0.1:{port}/{path}, an address on this Mac): the news is POSTed there as JSON, {"client", "text": "Meanwhile: …", "entries": […]}.

    Also: GET /api/say/forms (every template; ?q=words for the ones that fit, ?format=json), GET /api/say/log (what this client asked for, as JSON), POST /api/say/stop ({"number": 3}: one of them called off), POST /api/say/reset (start over; {"forget": true} forgets the log too). The one tool for a model is "say" (POST /api/tools/say {"arguments": {"text": "…"}}).
    """

    // MARK: saying

    /// Everything a reply says: the news, the answer (its first page), and what can be said next.
    func say(_ text: String, client: String, _ req: HTTPRequest, _ s: APISettings) async -> String {
        let catalog = s.isOn(.catalog) ? await host.catalog() : nil
        let ctx = SayContext(client: client, req: req, settings: s, forms: SayForms.all(catalog: catalog, settings: s))
        var news = await sayNews(ctx, tell: true)
        let reply = await sayAnswer(text, ctx)
        news.removeAll { reply.about.contains($0.number) }
        // Long answers: the first page now, the rest for "more".
        let pages = reply.paged ? [reply.answer] : SayWords.pages(reply.answer)
        var answer = pages.first ?? reply.answer
        let rest = Array(pages.dropFirst())
        if !rest.isEmpty { answer += "\n" + SayWords.moreLine(rest) }
        let more = rest.isEmpty ? reply.more ?? [] : rest + (reply.more ?? [])
        await sayLog.with(client) { c in
            c.lastSpoke = Date()
            c.more = more
        }
        var parts: [String] = []
        if !news.isEmpty {
            let lines = news.map { Self.capitalized($0.line) }
            parts.append(lines.count == 1 ? "Meanwhile: " + lines[0] : "Meanwhile:\n" + lines.map { "- " + $0 }.joined(separator: "\n"))
        }
        parts.append(answer)
        let next = reply.next.prefix(2)
        if !next.isEmpty {
            if next.count == 1, let one = next.first {
                parts.append(one.isInline ? "You can also say: " + one.short : "You can also say:\n" + one.template)
            } else {
                parts.append("You can also say:\n" + next.map { $0.isInline ? "- " + $0.short : "- " + $0.template.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n"))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    static func capitalized(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + s.dropFirst()
    }

    /// The answer to what was said: a pick from what was offered, a yes, a filled template (the
    /// labeled shape, then the inline), a title alone, or else the templates that fit.
    func sayAnswer(_ raw: String, _ ctx: SayContext) async -> SayReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return await sayBuiltin(.whatCanYouDo, SayFilled(), said: text, ctx) }
        let conv = await sayLog.with(ctx.client) { $0 }

        // A number: one of the choices waiting, or one of the templates just offered.
        if let k = SayRefs.ordinal(text) {
            if let p = conv.pending, k <= p.choices.count {
                await sayLog.with(ctx.client) { $0.pending = nil }
                let choice = p.choices[k - 1]
                if let form = ctx.form(choice.form) { return await sayAct(form, choice.filled, said: choice.text, ctx) }
            }
            if conv.pending == nil, !conv.offered.isEmpty, k <= conv.offered.count, let form = ctx.form(conv.offered[k - 1]) {
                if Self.needsNothing(form) { return await sayAct(form, SayFilled(), said: form.short, ctx) }
                return SayReply(answer: "Fill in the blanks and say it back:\n\n" + form.template)
            }
        }

        // A yes or a no, to a match waiting for one.
        if let p = conv.pending {
            await sayLog.with(ctx.client) { $0.pending = nil }
            if Self.isBuiltin(text, .yes, ctx), let first = p.choices.first, let form = ctx.form(first.form) {
                return await sayAct(form, first.filled, said: first.text, ctx)
            }
            if Self.isBuiltin(text, .no, ctx) { return SayReply(answer: "All right: nothing was done.") }
        }

        // The labeled shape: a title, and a line for each value.
        if let lines = SayMatch.lines(text), let reply = await sayLabeled(lines, text, ctx) { return reply }

        // The inline shape: the closest sentence.
        var found: [(form: SayForm, filled: SayFilled, score: Double, fixed: Int)] = []
        for f in ctx.forms where f.isInline {
            if let (filled, score, fixed) = SayMatch.inlineWeighed(text, f), score >= SayMatch.floor { found.append((f, filled, score, fixed)) }
        }
        found.sort { a, b in
            if abs(a.score - b.score) > 0.001 { return a.score > b.score }
            if a.fixed != b.fixed { return a.fixed > b.fixed }
            return (conv.used[a.form.title] ?? 0) > (conv.used[b.form.title] ?? 0)
        }
        var unresolved: (SayForm, String)?
        var usable: [(form: SayForm, filled: SayFilled, score: Double)] = []
        for c in found {
            // One about a request it can't tell: not this one.
            if case let .builtin(b) = c.form.action, Self.takesRequest(b) {
                let phrase = c.filled.at(0) ?? ""
                if SayRefs.resolve(phrase, in: conv) == nil {
                    if unresolved == nil { unresolved = (c.form, phrase) }
                    continue
                }
            }
            if !usable.contains(where: { $0.form.title == c.form.title }) { usable.append((c.form, c.filled, c.score)) }
        }
        if let top = usable.first {
            // Two about as close, and one changes something: which?
            if usable.count > 1, usable[1].score >= top.score - 0.03, top.form.changes || usable[1].form.changes,
               found.first(where: { $0.form.title == usable[1].form.title })?.fixed == found.first?.fixed {
                let two = Array(usable.prefix(2))
                await sayLog.with(ctx.client) { $0.pending = SayLog.Pending(choices: two.map { ($0.form.title, $0.filled, text) }) }
                return SayReply(answer: "Did you mean:\n" + SayWords.numbered(two.map { Self.described($0.form, $0.filled) }) + "\nSay its number.")
            }
            if top.score < SayMatch.certain(top.form), top.form.changes, top.form.kind != "builtin" {
                return await sayConfirm(top.form, top.filled, text, ctx)
            }
            return await sayAct(top.form, top.filled, said: text, ctx)
        }
        if let (form, phrase) = unresolved, case let .builtin(b) = form.action, b != .showMe || !conv.entries.isEmpty {
            return SayReply(answer: conv.entries.isEmpty
                            ? "You haven't asked me for anything yet."
                            : "I can't tell which request \"\(phrase)\" is. Say \"what have I asked for today\" for the list, then pick one by its number.",
                            next: ctx.forms(["What have I asked for"]))
        }

        // A title alone: the template, to fill (or, needing nothing, done).
        let titled = ctx.forms.filter { $0.kind != "builtin" }.map { ($0, SayMatch.titleScore(text, $0)) }.max { $0.1 < $1.1 }
        if let (form, score) = titled, score >= 0.85 {
            if Self.needsNothing(form) { return await sayAct(form, SayFilled(), said: text, ctx) }
            return SayReply(answer: "Fill in the blanks and say it back:\n\n" + form.template)
        }
        return await sayOffer(text, ctx)
    }

    /// The labeled shape: which template its title (or its labels) mean, and what it gave.
    func sayLabeled(_ l: SayMatch.Lines, _ text: String, _ ctx: SayContext) async -> SayReply? {
        let candidates = ctx.forms.filter { $0.kind != "builtin" }
        var target: (SayForm, Double)?
        if let title = l.title {
            let scored = candidates.map { ($0, SayMatch.titleScore(title, $0)) }.filter { $0.1 >= SayMatch.floor }.sorted { $0.1 > $1.1 }
            // Two titles about as close: the one all its lines belong to.
            if scored.count > 1, scored[1].1 >= scored[0].1 - 0.02 {
                target = scored.prefix(4).first { f in if case .filled = SayMatch.labeled(l, Self.labeledForm(f.0), titleScore: f.1) { return true }; return false } ?? scored[0]
            } else {
                target = scored.first
            }
            // A title it doesn't know, with lines: the lines say which.
            if target == nil, let byLabels = SayMatch.formByLabels(l, candidates.map(Self.labeledForm)) { target = byLabels }
        } else {
            target = SayMatch.formByLabels(l, candidates.map(Self.labeledForm))
        }
        guard let (found, titleScore) = target, let form = ctx.form(found.title) else { return nil }
        let shaped = Self.labeledForm(form)
        switch SayMatch.labeled(l, shaped, titleScore: titleScore) {
        case let .filled(filled, score):
            if score < SayMatch.certain(form), form.changes { return await sayConfirm(form, filled, text, ctx) }
            return await sayAct(form, filled, said: text, ctx)
        case let .incomplete(filled, missing, _):
            if filled.values.values.allSatisfy(\.isEmpty) { return SayReply(answer: "Fill in the blanks and say it back:\n\n" + form.template) }
            return SayReply(answer: "That needs \(Self.listed(missing.map(\.label))) too. Here it is to fill in:\n\n" + Self.template(shaped, with: filled))
        case let .badChoice(field, given, _):
            return SayReply(answer: "\(Self.capitalized(field.label)) is one of \(field.choices.joined(separator: ", ")); \"\(given)\" isn't one of them.\n\n" + form.template)
        case let .unknownLabel(label, _):
            return SayReply(answer: "\(form.title) has no line called \"\(label)\". Its lines:\n\n" + form.template)
        }
    }

    /// An inline form, as lines: a field for each blank of its first sentence (so a client can
    /// fill it either way). A labeled form as it is.
    static func labeledForm(_ form: SayForm) -> SayForm {
        guard form.fields.isEmpty, let v = form.variants.first else { return form }
        let blanks: [SayForm.Field] = v.pieces.compactMap { if case let .blank(b) = $0 { return .init(b, b) }; return nil }
        return SayForm(form.title, fields: blanks, formerly: form.formerly, words: form.words, about: form.about, changes: form.changes,
                       asks: form.asks, next: form.next, kind: form.kind, action: form.action)
    }

    /// A labeled template with what was given already in it.
    static func template(_ form: SayForm, with filled: SayFilled) -> String {
        ([form.title] + form.fields.map { f -> String in
            guard let v = filled[f.label] else { return f.shown }
            if f.multiline || v.contains("\n") { return "- \(f.label):\n```\n\(v)\n```" }
            return "- \(f.label): \(v)"
        }).joined(separator: "\n")
    }

    /// "a, b and c".
    static func listed(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// A filled template in a line: "Delete a note (shopping)".
    static func described(_ form: SayForm, _ filled: SayFilled) -> String {
        let values = (filled.ordered.isEmpty ? Array(filled.values.values) : filled.ordered).filter { !$0.isEmpty }
            .map { $0.count > 60 ? String($0.prefix(57)) + "…" : $0 }.map { $0.replacingOccurrences(of: "\n", with: " ") }
        return form.title + (values.isEmpty ? "" : " (\(values.joined(separator: ", ")))")
    }

    /// An uncertain match that would change something: asked about first.
    func sayConfirm(_ form: SayForm, _ filled: SayFilled, _ text: String, _ ctx: SayContext) async -> SayReply {
        await sayLog.with(ctx.client) { $0.pending = SayLog.Pending(choices: [(form.title, filled, text)]) }
        let corrected = filled.corrections.isEmpty ? "" : " (" + filled.corrections.joined(separator: "; ") + ")"
        return SayReply(answer: "Did you mean: \(Self.described(form, filled))\(corrected)? Say yes to go ahead, or no.")
    }

    /// It takes nothing: saying its title (or its number) does it.
    static func needsNothing(_ form: SayForm) -> Bool {
        // Its own sentence takes nothing (another way of saying it that takes nothing isn't enough).
        if let first = form.sentences.first { return !first.contains("{") }
        return form.fields.allSatisfy(\.optional)
    }

    static func takesRequest(_ b: SayBuiltin) -> Bool { [.whatHappened, .showMe, .stop, .done].contains(b) }

    static func isBuiltin(_ text: String, _ b: SayBuiltin, _ ctx: SayContext) -> Bool {
        guard let form = ctx.forms.first(where: { if case .builtin(b) = $0.action { return true }; return false }) else { return false }
        return (SayMatch.inline(text, form)?.1 ?? 0) >= SayMatch.clean
    }

    /// Nothing matched: the templates that would do it, numbered.
    func sayOffer(_ text: String, _ ctx: SayContext) async -> SayReply {
        let used = await sayLog.with(ctx.client) { $0.used }
        var picked = SayForms.search(text, in: ctx.forms, used: used, limit: 8)
        // The web answers most questions: offered second for a question (after the best fit, if
        // there's one), and last when little else fits.
        if let web = ctx.form("Search the web") {
            if Self.isQuestion(text) {
                picked.removeAll { $0.title == web.title }
                picked.insert(web, at: min(1, picked.count))
            } else if picked.count < 3, !picked.contains(where: { $0.title == web.title }) {
                picked.append(web)
            }
        }
        guard !picked.isEmpty else {
            return SayReply(answer: "I don't know how to do that yet.", next: ctx.forms(["What can you do"]))
        }
        let shown = Array(picked.prefix(3))
        let titles = picked.map(\.title)
        await sayLog.with(ctx.client) { $0.offered = titles }
        var answer = "These can do that:\n" + Self.offered(shown, from: 1) + "\nFill one in and say it back."
        var more: [String]?
        if picked.count > 3 {
            let rest = Array(picked.dropFirst(3))
            answer += " (\(rest.count) more: say \"more\".)"
            more = ["More that can do that:\n" + Self.offered(rest, from: 4)]
        }
        return SayReply(answer: answer, more: more)
    }

    /// A question about the world ("when does the louvre open?"), not a request to do something.
    static func isQuestion(_ text: String) -> Bool {
        let words = SayText.words(text)
        guard let first = words.first else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            || ["when", "where", "who", "whom", "whose", "why", "how", "which", "what", "whats", "is", "are", "was", "were", "does", "do", "did"].contains(first)
    }

    /// Templates in a numbered list, each indented under its number.
    static func offered(_ forms: [SayForm], from start: Int) -> String {
        forms.enumerated().map { k, f in
            let body = (f.isInline ? [f.short] : Array(f.template.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()).map(String.init))
            return "\(start + k). \(f.title)\n" + body.map { "     " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: doing it

    /// A filled template, done: the route it stands for called, the request logged, the answer said.
    func sayAct(_ form: SayForm, _ filled: SayFilled, said: String, _ ctx: SayContext) async -> SayReply {
        switch form.action {
        case let .builtin(b):
            return await sayBuiltin(b, filled, said: said, ctx)
        case let .tool(name, build):
            let args: [String: Any]
            do {
                args = try build(filled)
            } catch {
                return SayReply(answer: "\(error)", next: [form])
            }
            return await sayTool(name, args, form, filled, said: said, ctx)
        case let .script(item), let .flow(item):
            return await sayRun(item, form, filled, said: said, ctx)
        case .automation:
            return await sayAutomate(form, filled, said: said, ctx)
        }
    }

    /// Calls a tool as the client would have (its name, and why: what it said).
    func sayCall(_ tool: String, _ args: [String: Any], _ ctx: SayContext, said: String, async: Bool) async -> (Int, [String: Any]) {
        var body: [String: Any] = ["arguments": args, "client": ctx.client, "why": Self.sayWhy(ctx.client, said)]
        if async { body["async"] = true }
        let inner = HTTPRequest(method: "POST", target: "/api/tools/\(tool)?next=false", headers: ["content-type": "application/json", "user-agent": ctx.req.header("user-agent") ?? ""],
                                body: JSON.data(body), fromLoopback: ctx.req.fromLoopback, peer: ctx.req.peer)
        do {
            let r = try await route(inner, ctx.settings)
            return (r.status, r.bodyData.flatMap(JSON.object) ?? [:])
        } catch let e as HTTPError {
            return (e.status, ["ok": false, "code": e.code, "error": e.message])
        } catch {
            return (500, ["ok": false, "error": "\(error)"])
        }
    }

    /// What the card on the Mac shows as the reason: the client's own words.
    static func sayWhy(_ client: String, _ said: String) -> String {
        let first = said.split(whereSeparator: \.isNewline).first.map(String.init) ?? said
        return "\(client) asked in words: “\(clean(first, limit: 160))”"
    }

    /// What a request was, in words, for the log: the client's own sentence, or the template's
    /// title and its first value.
    static func what(_ form: SayForm, _ filled: SayFilled, said: String) -> String {
        let first = said.split(whereSeparator: \.isNewline).first.map(String.init) ?? said
        if form.isInline, SayMatch.lines(said) == nil { return clean(first, limit: 80) }
        let value = form.fields.first { $0.choices.isEmpty && filled[$0.label] != nil }.flatMap { filled[$0.label] }
            ?? filled.ordered.first { !$0.isEmpty } ?? ""
        let v = clean(value.replacingOccurrences(of: "\n", with: " "), limit: 50)
        return form.title.prefix(1).lowercased() + form.title.dropFirst() + (v.isEmpty ? "" : ": \(v)")
    }

    func sayTool(_ name: String, _ args: [String: Any], _ form: SayForm, _ filled: SayFilled, said: String, _ ctx: SayContext) async -> SayReply {
        let (status, json) = await sayCall(name, args, ctx, said: said, async: form.asks)
        let what = Self.what(form, filled, said: said)
        if form.asks {
            return await sayWaiting(status, json, form: form, what: what, short: what, said: said, dangers: [], ctx)
        }
        var text = SayWords.answer(tool: name, args: args, status: status, json: json)
        let ok = status < 400 && json["ok"] as? Bool != false
        if !filled.corrections.isEmpty { text = Self.capitalized(filled.corrections.joined(separator: "; ")) + ". " + text }
        let n = await sayLog.add(ctx.client, said: Self.firstLine(said), form: form.title, what: what, short: what,
                                 state: ok ? (form.changes ? .done : .answered) : .failed(text), result: text)
        return SayReply(answer: text, next: ok ? ctx.forms(form.next) : [form], about: [n])
    }

    static func firstLine(_ s: String) -> String { clean(s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s, limit: 200) }

    /// A run asked for: on the Mac now, waiting for the click.
    func sayWaiting(_ status: Int, _ json: [String: Any], form: SayForm, what: String, short: String, said: String, dangers: [String], _ ctx: SayContext) async -> SayReply {
        guard status == 202, let id = (json["request"] as? String).flatMap(UUID.init(uuidString:)) else {
            let text = SayWords.answer(tool: "", args: [:], status: max(status, 400), json: json)
            let n = await sayLog.add(ctx.client, said: Self.firstLine(said), form: form.title, what: what, short: short, state: .failed(text), result: text)
            return SayReply(answer: text, next: [form], about: [n])
        }
        let n = await sayLog.add(ctx.client, said: Self.firstLine(said), form: form.title, what: what, short: short, state: .waiting, asks: true, request: id)
        // The client needn't know it waits for an OK on the Mac (the card says what it does, dangers
        // and all): it's asked for, and how it goes comes as news, or when it asks.
        _ = dangers
        return SayReply(answer: "Asked for \(short). I'll tell you how it goes.", next: ctx.forms(["What happened"]), about: [n])
    }

    /// A script or a flow: its inputs from the values, in order, then asked for on the Mac.
    func sayRun(_ item: ScriptItem, _ form: SayForm, _ filled: SayFilled, said: String, _ ctx: SayContext) async -> SayReply {
        let answers: [String] = form.isInline && SayMatch.lines(said) == nil ? filled.ordered : form.fields.isEmpty ? filled.ordered : form.fields.map { filled[$0.label] ?? "" }
        if let missing = ScriptInput.missing(item.inputs, answers: answers) {
            return SayReply(answer: "That needs a value for \(missing.replacingOccurrences(of: " — this one is needed.", with: "")).\n\n" + form.template)
        }
        var (args, stdin) = ScriptInput.split(item.inputs, answers: answers)
        // A sentence with more blanks than the header has inputs: the rest are arguments too.
        if answers.count > item.inputs.count { args += answers.dropFirst(item.inputs.count).filter { !$0.isEmpty } }
        let flow = item.grid.isFlow
        var arguments: [String: Any] = [flow ? "flow" : "script": item.id, "args": args]
        if let stdin, !flow { arguments["stdin"] = stdin }
        let (status, json) = await sayCall(flow ? "run_flow" : "run_script", arguments, ctx, said: said, async: true)
        let short = "the " + SayForms.spoken(item.title)
        let what = form.isInline && SayMatch.lines(said) == nil ? Self.clean(Self.firstLine(said), limit: 80) : short + (args.isEmpty ? "" : " (\(Self.clean(args.joined(separator: ", "), limit: 50)))")
        return await sayWaiting(status, json, form: form, what: what, short: short, said: said, dangers: item.dangers, ctx)
    }

    /// Tagging a script or flow to run by itself: asked on the Mac (Allow), followed here.
    func sayAutomate(_ form: SayForm, _ filled: SayFilled, said: String, _ ctx: SayContext) async -> SayReply {
        let wanted = filled["what"] ?? ""
        let items = ctx.forms.filter { $0.kind == "script" || $0.kind == "flow" }
        let best = items.map { f in (f, max(SayMatch.near(f.title, wanted), SayMatch.titleScore(wanted, f))) }.max { $0.1 < $1.1 }
        guard let (target, score) = best, score >= SayMatch.floor else {
            return SayReply(answer: "There's no script or flow called \"\(wanted)\". Say what it does, and I'll find it.", next: [form])
        }
        guard let when = filled["when"], let tag = AutomationTag.allCases.first(where: { $0.title.lowercased() == when.lowercased() }) else {
            return SayReply(answer: "Say when it runs.\n\n" + form.template)
        }
        let item: ScriptItem
        switch target.action {
        case let .script(i), let .flow(i): item = i
        default: return SayReply(answer: "That can't run by itself.", next: [form])
        }
        let short = "the " + SayForms.spoken(item.title)
        let what = "\(SayForms.spoken(item.title)) to run \(when)"
        let n = await sayLog.add(ctx.client, said: Self.firstLine(said), form: form.title, what: what, short: short, state: .waiting, asks: true)
        let body: [String: Any] = [item.grid.isFlow ? "flow" : "script": item.id, "automation": [tag.rawValue], "client": ctx.client, "why": Self.sayWhy(ctx.client, said)]
        let inner = HTTPRequest(method: "POST", target: "/api/automation?next=false", headers: ["content-type": "application/json"], body: JSON.data(body),
                                fromLoopback: ctx.req.fromLoopback, peer: ctx.req.peer)
        let s = ctx.settings, client = ctx.client, log = sayLog
        // The card waits for Allow; the answer comes as news.
        Task { [self] in
            var status = 500
            var json: [String: Any] = [:]
            do {
                let r = try await self.route(inner, s)
                status = r.status
                json = r.bodyData.flatMap(JSON.object) ?? [:]
            } catch let e as HTTPError {
                status = e.status
                json = ["error": e.message, "code": e.code]
            } catch {}
            let code = json["code"] as? String
            let state: SayLog.State = status < 400 ? .done : code == "denied" ? .denied : code == "not_answered" ? .notAnswered : .failed(SayWords.failure(json))
            let result = status < 400 ? "\(short) runs \(when) now." : nil
            await log.update(client, n) { e in
                e.state = state
                e.result = result
                e.ended = Date()
            }
        }
        return SayReply(answer: "Asked for \(short) to run \(when). I'll tell you how it goes.", next: ctx.forms(["What happened"]), about: [n])
    }

    // MARK: the news

    /// What's changed in the client's requests since it last heard: each change told once. The
    /// adapter follows the system's requests itself, and collects a result once it's over (it's
    /// handed over to the adapter, so the system's open list no longer has it; the client hears
    /// of it here, and sees it in full when it asks).
    func sayNews(_ ctx: SayContext, tell: Bool) async -> [(number: Int, line: String)] {
        var out: [(Int, String)] = []
        for var e in await sayLog.entries(ctx.client) where e.asks {
            let followed = e.request != nil && e.state.open
            if followed, let id = e.request { await sayFollow(&e, id) }
            let key = e.state.key
            guard key != e.told else {
                // Only what was followed can have changed.
                if followed { await sayLog.update(ctx.client, e.number) { [e] x in x.state = e.state; x.result = e.result; x.ended = e.ended } }
                continue
            }
            let line = Self.newsLine(e)
            let told = tell ? key : e.told
            await sayLog.update(ctx.client, e.number) { [e] x in
                x.state = e.state
                x.result = e.result
                x.ended = e.ended
                x.told = told
            }
            if tell, !e.muted { out.append((e.number, line)) }
        }
        return out
    }

    /// Where a request of the system's is now, into the entry (its result collected once it's over).
    func sayFollow(_ e: inout SayLog.Entry, _ id: UUID) async {
        guard let le = await requests.entry(id) else {
            e.state = .couldNotStart("it was forgotten while the app ran on")
            return
        }
        switch le.outcome {
        case .waiting: e.state = .waiting
        case .denied: e.state = .denied
        case .notAnswered: e.state = .notAnswered
        case .withdrawn: e.state = .withdrawn
        case let .failed(err): e.state = .couldNotStart(SayWords.plain(err.message))
        case .automated, .stopped: e.state = .done
        case let .running(run):
            guard let r = await host.record(run) else {
                e.state = .couldNotStart("its run was cleared from the app's history")
                break
            }
            guard r.state.finished else { e.state = .running; return }
            e.state = r.state == .stopped ? .stopped : .finished(ok: r.state == .succeeded, code: r.code.map { Int($0) })
            var result = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.kind == .flow {
                let steps = await host.steps(of: run).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if result.isEmpty, !steps.isEmpty { result = steps.map { "\(SayWords.spokenName($0.name)):\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n\n") }
            }
            if let problem = r.problem { result = result.isEmpty ? problem : result + "\n" + problem }
            e.result = result
            e.ended = r.ended ?? Date()
        }
        if !e.state.open {
            if e.ended == nil { e.ended = Date() }
            // Collected by the adapter: handed over, so the system's open list is clear of it.
            await requests.clear(id, .collected)
        }
    }

    /// One change, in a sentence.
    static func newsLine(_ e: SayLog.Entry) -> String {
        let s = e.short
        switch e.state {
        case .running: return "\(s) has started."
        case let .finished(ok, code):
            let empty = (e.result ?? "").isEmpty
            if ok { return empty ? "\(s) finished (it worked, and printed nothing)." : "\(s) finished (it worked). Say \"show me \(s)\" to see what it printed." }
            return "\(s) finished, but it failed\(code.map { " (code \($0))" } ?? "").\(empty ? "" : " Say \"show me \(s)\" to see what it printed.")"
        case .denied: return "\(s) didn't run: it was turned down on the Mac."
        case .notAnswered: return "\(s) didn't run: no one OK'd it on the Mac in time. Say it again to try again."
        case .withdrawn: return "\(s) was taken back; nothing ran."
        case let .couldNotStart(why): return "\(s) couldn't start: \(why)"
        case .stopped: return "\(s) was stopped before it ended.\((e.result ?? "").isEmpty ? "" : " Say \"show me \(s)\" to see what it printed first.")"
        case .done: return e.result ?? "\(s) is done."
        case let .failed(why): return "\(s) didn't work: \(why)"
        case .waiting: return "\(s) hasn't started yet."
        case .answered: return "\(s) was answered."
        }
    }

    /// How a request is going, in a few words (for lists).
    static func status(_ e: SayLog.Entry) -> String {
        switch e.state {
        case .answered: return "answered"
        case .done: return "done"
        case .failed: return "it didn't work"
        case .waiting: return "not started yet: waiting to be OK'd on the Mac"
        case .running: return "running"
        case let .finished(ok, _):
            let word = ok ? "it worked" : "it failed"
            return e.shown || (e.result ?? "").isEmpty || e.muted ? word : "\(word); not shown yet: say \"show me \(e.short)\""
        case .denied: return "turned down on the Mac"
        case .notAnswered: return "not OK'd on the Mac in time"
        case .withdrawn: return "taken back"
        case .couldNotStart: return "it couldn't start"
        case .stopped: return "stopped"
        }
    }

    // MARK: about the conversation

    func sayBuiltin(_ b: SayBuiltin, _ filled: SayFilled, said: String, _ ctx: SayContext) async -> SayReply {
        let conv = await sayLog.with(ctx.client) { $0 }
        let entry = filled.at(0).flatMap { SayRefs.resolve($0, in: conv) }
        switch b {
        case .whatCanYouDo:
            return SayReply(answer: Self.sayOverview(ctx))
        case .whatHappened:
            guard let e = entry else { return SayReply(answer: "I can't tell which request that is.", next: ctx.forms(["What have I asked for"])) }
            return SayReply(answer: Self.sayStory(e), about: [e.number])
        case .whatHaveIAsked:
            let cal = Calendar.current
            let now = Date()
            let since: Date?
            var heading: String
            switch filled.chose.first {
            case "today", nil:
                since = cal.startOfDay(for: now); heading = "Today you asked for"
            case "recently":
                since = nil; heading = "Lately you asked for"
            default:
                let t = filled.at(0).flatMap { SayRefs.time($0, now: now) }
                since = t
                heading = t.map { "Since \(cal.isDateInToday($0) ? SayWords.time($0) : DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)) you asked for" } ?? "Lately you asked for"
            }
            var picked = conv.entries.filter { since == nil || $0.asked >= since! }
            if since == nil { picked = Array(picked.suffix(10)) }
            guard !picked.isEmpty else {
                return SayReply(answer: conv.entries.isEmpty ? "You haven't asked me for anything yet." : "Nothing then. Say \"what have I asked for recently\" for the latest.")
            }
            let numbers = picked.map(\.number)
            await sayLog.with(ctx.client) { $0.list = numbers }
            return SayReply(answer: heading + ":\n" + SayWords.numbered(picked.map { "\($0.what) (\(Self.status($0)))" }))
        case .showMe:
            guard let e = entry else { return SayReply(answer: "I can't tell which request that is.", next: ctx.forms(["What have I asked for"])) }
            if e.state.open { return SayReply(answer: Self.sayStory(e), about: [e.number]) }
            guard let result = e.result, !result.isEmpty else { return SayReply(answer: Self.capitalized(e.short) + " gave back nothing to show.", about: [e.number]) }
            await sayLog.update(ctx.client, e.number) { $0.shown = true }
            let head: String
            switch e.state {
            case let .finished(ok, _): head = "\(Self.capitalized(e.short)) \(ok ? "worked" : "failed")\(e.ended.map { " at \(SayWords.time($0))" } ?? ""). It printed:\n"
            case .stopped: head = "\(Self.capitalized(e.short)) was stopped. Before that it printed:\n"
            default: head = ""
            }
            return SayReply(answer: head + result, about: [e.number])
        case .more:
            let rest = conv.more
            guard let first = rest.first else { return SayReply(answer: "There's no more.") }
            let remaining = Array(rest.dropFirst())
            // The rest is already cut into pages: the next one, and how much is left.
            return SayReply(answer: remaining.isEmpty ? first : first + "\n" + SayWords.moreLine(remaining), more: remaining, paged: true)
        case .stop:
            guard let e = entry else { return SayReply(answer: "I can't tell which request that is.", next: ctx.forms(["What have I asked for"])) }
            return await sayStop(e, ctx)
        case .done:
            guard let e = entry else { return SayReply(answer: "I can't tell which request that is.", next: ctx.forms(["What have I asked for"])) }
            await sayLog.update(ctx.client, e.number) { $0.muted = true; $0.shown = true }
            if let id = e.request, !e.state.open { await requests.clear(id, .dismissed) }
            let more = e.state.open ? " It's still \(e.state == .waiting ? "waiting on the Mac" : "running"): say \"stop \(e.short)\" to stop it." : ""
            return SayReply(answer: "All right: I won't mention \(e.short) again.\(more)", about: [e.number])
        case .yes:
            return SayReply(answer: "There's nothing waiting for a yes.")
        case .no:
            return SayReply(answer: "All right.")
        case .startOver:
            await sayLog.reset(ctx.client)
            return SayReply(answer: "A fresh start. What you asked for before is still there: say \"what have I asked for today\".")
        case .pick:
            return SayReply(answer: "Say the number of one of the templates I offered.")
        }
    }

    /// Stopping a request: taken back while it waits for the click, stopped while it runs.
    func sayStop(_ e: SayLog.Entry, _ ctx: SayContext) async -> SayReply {
        guard let id = e.request else {
            if e.state == .waiting { return SayReply(answer: "\(Self.capitalized(e.short)) hasn't started, and can't be taken back from here: it can be turned down on the Mac.", about: [e.number]) }
            return SayReply(answer: "\(Self.capitalized(e.short)) is over already.", about: [e.number])
        }
        var now = e
        await sayFollow(&now, id)
        switch now.state {
        case .waiting:
            if await requests.withdraw(id) {
                await sayLog.update(ctx.client, e.number) { $0.state = .withdrawn; $0.told = "withdrawn"; $0.ended = Date() }
                return SayReply(answer: "Taken back: \(e.short) won't run.", about: [e.number])
            }
            return SayReply(answer: "\(Self.capitalized(e.short)) hasn't started, and can't be taken back right now.", about: [e.number])
        case .running:
            if let run = await requests.entry(id)?.runID, await host.stop(run) {
                await sayLog.update(ctx.client, e.number) { $0.told = "running" }
                return SayReply(answer: "Stopping \(e.short). I'll tell you when it has.", about: [e.number])
            }
            return SayReply(answer: "\(Self.capitalized(e.short)) couldn't be stopped: it may have just ended.", about: [e.number])
        default:
            await sayLog.update(ctx.client, e.number) { [now] x in x.state = now.state; x.result = now.result; x.ended = now.ended }
            return SayReply(answer: "\(Self.capitalized(e.short)) is over already (\(Self.status(now))).", about: [e.number])
        }
    }

    /// How a request has gone, in a sentence or two.
    static func sayStory(_ e: SayLog.Entry) -> String {
        let s = capitalized(e.short)
        let at = SayWords.time(e.asked)
        switch e.state {
        case .waiting: return "\(s) hasn't started yet: it's waiting for someone at the Mac to OK it (asked at \(at)). Nothing has run. I'll tell you when it starts."
        case .running: return "\(s) is running (asked at \(at)). I'll tell you when it's done."
        case let .finished(ok, code):
            var out = "\(s) finished\(e.ended.map { " at \(SayWords.time($0))" } ?? "") and \(ok ? "worked" : "failed\(code.map { " (code \($0))" } ?? "")")."
            if !(e.result ?? "").isEmpty { out += e.shown ? " Say \"show me \(e.short)\" to see what it printed again." : " Say \"show me \(e.short)\" to see what it printed." }
            return out
        case .answered, .done:
            let first = (e.result ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return "That was \(e.state == .done ? "done" : "answered") at \(at)\(first.isEmpty ? "." : ": \(first)")"
        case let .failed(why): return "That didn't work (at \(at)): \(why)"
        case .denied: return "\(s) didn't run: it was turned down on the Mac."
        case .notAnswered: return "\(s) didn't run: no one OK'd it on the Mac in time."
        case .withdrawn: return "\(s) was taken back before anyone answered; nothing ran."
        case let .couldNotStart(why): return "\(s) couldn't start: \(why)"
        case .stopped: return "\(s) was stopped before it ended."
        }
    }

    /// "what can you do": a few lines of what there is, each a template to say.
    static func sayOverview(_ ctx: SayContext) -> String {
        func line(_ title: String) -> String? { ctx.form(title).map { $0.isInline ? "- " + $0.short : "- " + $0.title.lowercased() + " (say it, and I'll show you its lines)" } }
        let tools = ["Search the web", "Open a page in Chrome", "Work side by side", "Remember something", "Recall something", "What's coming up", "Read a note"].compactMap(line)
        let folder = ctx.forms.filter { $0.kind == "script" || $0.kind == "flow" }
        var out = "Say what you want, in your own words. If I'm not sure, I'll answer with a few sentences to fill in and say back.\n\nSome of what you can say:\n" + tools.joined(separator: "\n")
        if !folder.isEmpty {
            let some = folder.prefix(3).map { "- " + $0.short }
            out += "\n\nThe Mac also has \(folder.count) script\(folder.count == 1 ? "" : "s") and flow\(folder.count == 1 ? "" : "s") , like:\n" + some.joined(separator: "\n")
        }
        out += "\n\nAnd about what you've asked for: what have I asked for today · what happened to {something you asked for} · show me {something you asked for} · stop {something you asked for} · more"
        return out
    }
}

extension SayForm {
    /// As `GET /api/say/forms?format=json` gives it.
    var json: [String: Any] {
        var out: [String: Any] = ["title": title, "template": template, "kind": kind, "shape": isInline ? "inline" : "labeled",
                                  "changes": changes, "waits_for_the_mac": asks]
        if !sentences.isEmpty { out["sentences"] = sentences }
        if !fields.isEmpty {
            out["fields"] = fields.map { f -> [String: Any] in
                var d: [String: Any] = ["label": f.label, "optional": f.optional, "multiline": f.multiline]
                if let b = f.blank { d["blank"] = b }
                if !f.choices.isEmpty { d["choices"] = f.choices }
                return d
            }
        }
        if !formerly.isEmpty { out["formerly"] = formerly }
        if !about.isEmpty { out["about"] = about }
        return out
    }
}
