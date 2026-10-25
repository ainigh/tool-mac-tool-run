import Foundation

/// The translator, in the conversation: asked only when the words don't settle it (nothing
/// matched closely, two templates fit about as well, or the closest fit only loosely). What it
/// filled in is read back through the adapter's own matcher, so only real templates, with values
/// it can take, come of it. A reading it's sure of is done (a read at once, a run asked for on
/// the Mac, anything else that changes something asked about first: "Did you mean …?"), and the
/// reply says how it was taken, so the client learns the template. A reading it isn't sure of is
/// offered, numbered, filled in as far as it could be. Nothing from it: the adapter answers as
/// it does without one.
///
/// `POST /api/say/translate` is the same call alone, for trying models (BENCH.md): what was
/// said in, the prompt the model saw, what it answered and what the adapter made of it, out.
/// `GET` and `POST /api/say/translator` are its settings.
extension RunAPI {
    /// One suggestion of the model's, read back: its template, what it filled, and whether that's all it needs.
    struct SayReading {
        let form: SayForm
        let filled: SayFilled
        /// As the model filled it (blanks it couldn't fill left as they were).
        let say: String
        let confidence: Double
        /// Every value it needs is there.
        let complete: Bool
    }

    /// The templates the model is given, and how many of them are the closest: the ones the
    /// words were between, the ones search finds; then the tools', the conversation's own and the
    /// folder's (never yes or no).
    static func translatorForms(_ text: String, _ why: SayTranslator.Why, _ forms: [SayForm], used: [String: Int]) -> (forms: [SayForm], closest: Int) {
        var first: [String] = []
        switch why {
        case let .between(t): first = t
        case let .weak(t): first = [t]
        case .nothing: break
        }
        first += SayForms.search(text, in: forms, used: used, limit: 10).map(\.title)
        var seen = Set<String>()
        var out: [SayForm] = []
        func add(_ f: SayForm) {
            guard !seen.contains(f.title), !["Yes", "No"].contains(f.title) else { return }
            seen.insert(f.title)
            out.append(f)
        }
        for t in first { if let f = forms.first(where: { $0.title == t }) { add(f) } }
        let closest = out.count
        forms.filter { $0.kind == "tool" }.forEach(add)
        forms.filter { $0.kind == "builtin" }.forEach(add)
        forms.forEach(add)
        return (out, closest)
    }

    /// A value that's still a blank: "{a place}".
    static func isBlank(_ v: String) -> Bool {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || (t.hasPrefix("{") && t.hasSuffix("}") && !t.dropFirst().contains("{"))
    }

    /// Whether a filled template has every value it needs.
    static func complete(_ form: SayForm, _ filled: SayFilled) -> Bool {
        if filled.values.values.contains(where: { isBlank($0) && !$0.isEmpty }) { return false }
        if form.isInline {
            // Its values, or a way of saying it that takes none ("what's the weather").
            return !filled.ordered.isEmpty || form.variants.contains { v in !v.pieces.contains { if case .blank = $0 { return true }; return false } }
        }
        return form.fields.allSatisfy { $0.optional || !isBlank(filled.values[$0.label] ?? "") }
    }

    /// A filled template as a client would say it back: an inline sentence with its values in
    /// place, or the labeled lines with theirs.
    static func filledIn(_ form: SayForm, _ filled: SayFilled) -> String {
        guard let sentence = form.sentences.first else { return template(form, with: filled) }
        var out = ""
        var values = filled.ordered.makeIterator()
        var s = Substring(sentence)
        while let open = s.firstIndex(of: "{"), let close = s[open...].firstIndex(of: "}") {
            out += s[..<open]
            let v = values.next() ?? ""
            out += v.isEmpty ? String(s[open...close]) : v
            s = s[s.index(after: close)...]
        }
        return out + s
    }

    /// The model's suggestion read back against the template it names: nil when it names none there is.
    static func reading(_ s: SayTranslator.Suggestion, _ forms: [SayForm]) -> SayReading? {
        let candidates = forms.filter { !["Yes", "No"].contains($0.title) }
        let form = candidates.first { $0.title.lowercased() == s.title.lowercased() || $0.formerly.contains { $0.lowercased() == s.title.lowercased() } }
            ?? candidates.map { ($0, SayMatch.titleScore(s.title, $0)) }.filter { $0.1 >= 0.85 }.max { $0.1 < $1.1 }?.0
        guard let form else { return nil }
        let say = s.say.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing filled: the template as it is.
        guard !say.isEmpty, say.lowercased() != form.title.lowercased() else {
            return SayReading(form: form, filled: SayFilled(), say: form.short, confidence: s.confidence, complete: needsNothing(form))
        }
        // The labeled shape (or an inline template sent as lines).
        if let lines = SayMatch.lines(say) {
            switch SayMatch.labeled(lines, labeledForm(form), titleScore: 1) {
            case let .filled(filled, _):
                return SayReading(form: form, filled: filled, say: say, confidence: s.confidence, complete: complete(labeledForm(form), filled))
            case let .incomplete(filled, _, _):
                return SayReading(form: form, filled: filled, say: say, confidence: s.confidence, complete: false)
            case .badChoice, .unknownLabel:
                break
            }
        }
        // The inline shape: its own sentence, as closely as a client's would have to be.
        if form.isInline, let (filled, score) = SayMatch.inline(say, form), score >= SayMatch.clean {
            return SayReading(form: form, filled: filled, say: say, confidence: s.confidence, complete: complete(form, filled))
        }
        // A filling that isn't the template's: the template, to fill.
        return SayReading(form: form, filled: SayFilled(), say: form.short, confidence: min(s.confidence, 0.5), complete: false)
    }

    /// The model's readings, the best first, one a template.
    static func readings(_ t: SayTranslator.Translation, _ forms: [SayForm]) -> [SayReading] {
        var out: [SayReading] = []
        for s in t.suggestions {
            guard let r = reading(s, forms), !out.contains(where: { $0.form.title == r.form.title }) else { continue }
            out.append(r)
        }
        return out
    }

    /// What the translator makes of it, done or offered; nil when it has nothing to add (it's
    /// off or out of reach, or it found nothing). With `list` false, only a reading it's sure
    /// of counts (the adapter has a question of its own to fall back on).
    func sayTranslate(_ text: String, _ why: SayTranslator.Why, _ ctx: SayContext, list: Bool) async -> SayReply? {
        guard await translator.ready else { return nil }
        let used = await sayLog.with(ctx.client) { $0.used }
        let (forms, closest) = Self.translatorForms(text, why, ctx.forms, used: used)
        let t = await translator.translate(text, why: why, forms: forms, closest: closest)
        guard t.error == nil else { return nil }
        let readings = Self.readings(t, ctx.forms)
        let sure = await translator.settings.sure
        if let top = readings.first, top.complete, top.confidence >= sure {
            let taken = "Taken as: " + (top.say.contains("\n") ? "\n" + top.say : top.say)
            // Something that changes and doesn't wait for the Mac: asked about first.
            if top.form.changes, !top.form.asks, top.form.kind != "builtin" {
                return await sayConfirm(top.form, top.filled, text, ctx)
            }
            var reply = await sayAct(top.form, top.filled, said: text, ctx)
            reply.answer = taken + "\n\n" + reply.answer
            return reply
        }
        guard list, !readings.isEmpty else { return nil }
        let shown = Array(readings.prefix(3))
        await sayLog.with(ctx.client) { c in
            c.pending = SayLog.Pending(choices: shown.map { ($0.form.title, $0.filled, text) })
            c.offered = []
        }
        var answer = t.meaning.isEmpty ? "" : "It sounds like: \(t.meaning).\n"
        answer += "You might mean:\n" + shown.enumerated().map { k, r in
            let body = r.say.contains("\n") ? r.say.split(separator: "\n", omittingEmptySubsequences: false).map { "     " + $0 }.joined(separator: "\n") : "     " + r.say
            return "\(k + 1). \(r.form.title)\n" + body
        }.joined(separator: "\n")
        answer += "\nSay its number to do it, or say one back changed."
        if !t.question.isEmpty { answer += "\n" + t.question }
        return SayReply(answer: answer)
    }

    // MARK: the routes

    /// `POST /api/say/translate`: the translator alone, stateless: `{"text", "why"?: "nothing" |
    /// "between" | "weak", "between"?: [titles], "dry"?: true, and any setting to try instead
    /// ("model", "url", "api", "key", "format", "effort", "timeout")}`.
    func sayTranslateRoute(_ fields: [String: Any], client: String, _ req: HTTPRequest, _ s: APISettings) async throws -> HTTPResponse {
        let text = (Self.text(fields["text"]) ?? Self.text(fields["q"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HTTPError(status: 400, code: "missing_argument", message: "say what to translate: {\"text\": \"will it rain in Lagos tomorrow\"}") }
        let titles: [String] = (fields["between"] as? [String]) ?? Self.text(fields["between"]).map { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
        let why: SayTranslator.Why
        switch Self.text(fields["why"])?.lowercased() {
        case "between": why = .between(titles)
        case "weak": why = .weak(titles.first ?? "")
        default: why = .nothing
        }
        let catalog = s.isOn(.catalog) ? await host.catalog() : nil
        let all = SayForms.all(catalog: catalog, settings: s)
        let used = await sayLog.with(client) { $0.used }
        let (forms, closest) = Self.translatorForms(text, why, all, used: used)
        // Other settings to try, without keeping them (a request from this Mac only: it may carry a key).
        let trying = ["model", "url", "api", "key", "format", "effort", "timeout"].contains { fields[$0] != nil }
        if trying, !req.fromLoopback { throw HTTPError(status: 403, code: "forbidden", message: "other settings to try are taken only from a client on this Mac") }
        var using: SayTranslator.Settings?
        if trying {
            do {
                var o = try await translator.settings.changed(by: fields)
                o.on = true
                using = o
            } catch {
                throw HTTPError(status: 400, code: "bad_request", message: "\(error)")
            }
        }
        let dry = Self.flag(Self.text(fields["dry"]))
        let t = await translator.translate(text, why: why, forms: forms, closest: closest, using: using, dry: dry)
        let readings = Self.readings(t, all)
        var out: [String: Any] = [
            "ok": t.error == nil, "text": text, "why": why.key, "model": t.model, "seconds": JSON.round(t.seconds),
            "prompt": ["system": t.system, "user": t.user], "raw": t.raw, "meaning": t.meaning, "question": t.question,
            "suggestions": t.suggestions.map { s -> [String: Any] in
                var d: [String: Any] = ["title": s.title, "say": s.say, "confidence": s.confidence]
                if let r = Self.reading(s, all) {
                    d["template"] = r.form.title
                    d["complete"] = r.complete
                    d["taken"] = r.complete ? r.say : NSNull()
                } else {
                    d["template"] = NSNull()
                    d["complete"] = false
                }
                return d
            },
            "top": readings.first.map { $0.form.title } ?? NSNull(),
            "templates_given": forms.prefix(SayTranslator.maxForms).count,
        ]
        if dry { out["dry"] = true }
        if let e = t.error, !dry { out["error"] = e }
        return JSON.response(out)
    }

    /// `GET /api/say/translator`: its settings and the latest calls; `POST`: changed (from this Mac).
    func sayTranslatorRoute(_ method: String, _ fields: [String: Any], _ req: HTTPRequest) async throws -> HTTPResponse {
        if method == "POST" {
            guard req.fromLoopback else { throw HTTPError(status: 403, code: "forbidden", message: "the translator's settings are changed only from this Mac") }
            do {
                try await translator.change(fields)
            } catch {
                throw HTTPError(status: 400, code: "bad_request", message: "\(error)")
            }
        }
        let settings = await translator.settings
        let ready = await translator.ready
        let calls = await translator.calls.suffix(20).reversed().map { c -> [String: Any] in
            var d: [String: Any] = ["at": JSON.date(c.at), "text": c.text, "why": c.why, "model": c.translation.model,
                                    "seconds": JSON.round(c.translation.seconds), "meaning": c.translation.meaning,
                                    "suggestions": c.translation.suggestions.map { ["title": $0.title, "say": $0.say, "confidence": $0.confidence] }]
            if let e = c.translation.error { d["error"] = e }
            return d
        }
        return JSON.response(["ok": true, "settings": settings.json, "ready": ready, "calls": calls,
                              "note": "Asked only when what's said to POST /api/say doesn't settle on one template. Stateless: what was said, why, and the templates; nothing else. POST {\"api\", \"url\", \"model\", \"key\", \"sure\", \"on\"} here (from this Mac) to change it; POST /api/say/translate {\"text\"} to try it alone."])
    }
}
