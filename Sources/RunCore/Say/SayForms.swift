import Foundation

/// Every template the adapter can offer: the ones about the conversation itself, one or more for
/// each of the API's tools (its `say`: the sentences a person would use, each filling the tool's
/// arguments), and one for each script and flow in the folder, made from its header (its `#
/// Say:` lines, else its name and its `# Input:` lines). Nobody writes them by hand for a new
/// script: what the system already says about it is enough.
public enum SayForms {
    // MARK: about the conversation

    static let something = "{something you asked for}"

    public static let builtins: [SayForm] = [
        SayForm("What can you do", "what can you do", also: ["help", "what can I say", "what can I ask", "what can you do for me"],
                about: "what there is, in a few lines", kind: "builtin", action: .builtin(.whatCanYouDo)),
        SayForm("What happened", "what happened to \(something)", also: ["how is \(something) going", "is \(something) done", "what about \(something)"],
                about: "how something you asked for is going", kind: "builtin", action: .builtin(.whatHappened)),
        SayForm("What have I asked for", "what have I asked for [today | recently | since {a time}]",
                also: ["what did I ask for [today | recently | since {a time}]", "what have I asked for"],
                about: "your requests, numbered, and how each went", kind: "builtin", action: .builtin(.whatHaveIAsked)),
        SayForm("Show me", "show me \(something)", also: ["show \(something)"],
                about: "what something you asked for gave back, in full", kind: "builtin", action: .builtin(.showMe)),
        SayForm("More", "more", also: ["the rest", "go on", "continue", "next page"], about: "the rest of a long answer", kind: "builtin", action: .builtin(.more)),
        SayForm("Stop", "stop \(something)", also: ["cancel \(something)"],
                about: "stop something still waiting or running", changes: true, kind: "builtin", action: .builtin(.stop)),
        SayForm("Done with", "I'm done with \(something)", also: ["I am done with \(something)", "done with \(something)", "never mind \(something)"],
                about: "stop hearing about something", kind: "builtin", action: .builtin(.done)),
        SayForm("Yes", "yes", also: ["yes please", "go ahead", "do it", "ok", "okay", "sure"], kind: "builtin", action: .builtin(.yes)),
        SayForm("No", "no", also: ["no thanks", "don't", "do not"], kind: "builtin", action: .builtin(.no)),
        SayForm("Start over", "start over", also: ["start again", "new conversation"],
                about: "a fresh start: the numbers and what's pending are forgotten (what you asked for is kept)", kind: "builtin", action: .builtin(.startOver)),
    ]

    // MARK: the tools' own

    static let categories = Memory.defaultNames

    /// The days "this week", "this month" or "in the next N days" mean.
    static func days(_ f: SayFilled) -> Int {
        if let n = f["a number of"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) { return max(1, min(366, n)) }
        return f.chose.first == "this week" ? 7 : f.chose.first == "today" ? 1 : 31
    }

    public static let tools: [SayForm] = [
        // The web
        SayForm("Search the web", "search the web for {what to look for}", also: ["look up {what to look for} online", "google {what to look for}"],
                words: "internet online google find out lookup question fact price news", about: "a web search, at once",
                next: ["Read a web page", "Open a page in Chrome"], action: .tool("web_search") { f in ["q": f.at(0) ?? ""] }),
        SayForm("Read a web page", "read the page at {a web address}", also: ["read {a web address}"],
                words: "fetch website site url link address api json", about: "what a page says, at once",
                next: ["Find words on a web page", "Open a page in Chrome"], action: .tool("web_fetch") { f in ["url": f.at(0) ?? ""] }),
        SayForm("Find words on a web page", fields: [.init("address", "a web address"), .init("words", "what to look for on it")],
                words: "fetch find lines page website", about: "only the lines of a page that have some words",
                action: .tool("web_fetch") { f in ["url": f["address"] ?? "", "find": f["words"] ?? ""] }),
        // Chrome
        SayForm("Open a page in Chrome", "open {a web address} in Chrome", also: ["open {a web address}", "go to {a web address}"],
                words: "browser tab navigate visit show website", about: "a page opened for the person, in a new tab", changes: true,
                next: ["Find something on the page", "Point something out on the page"], action: .tool("browser") { f in ["op": "open", "url": f.at(0) ?? ""] }),
        SayForm("Read the page in Chrome", "read the page in front of me", also: ["what's on the page", "read the page in Chrome", "what does the page say"],
                words: "browser chrome current front tab text", about: "the page the person is looking at",
                next: ["Find something on the page"], action: .tool("browser") { _ in ["op": "page"] }),
        SayForm("Find something on the page", "where is {words on the page} on the page", also: ["find {words on the page} on the page"],
                words: "browser chrome locate button link where", about: "where a thing is on the page in front",
                next: ["Point something out on the page"], action: .tool("browser") { f in ["op": "find", "text": f.at(0) ?? ""] }),
        SayForm("Point something out on the page", "point to {words on the page} on the page", also: ["ring {words on the page} in red", "highlight {words on the page}"],
                words: "browser chrome highlight ring show where guide", about: "a red ring around a thing on the page, for the person",
                action: .tool("browser") { f in ["op": "highlight", "text": f.at(0) ?? ""] }),
        SayForm("The tabs in Chrome", "what tabs are open", also: ["which tabs are open", "list the tabs"], words: "browser chrome tabs windows",
                about: "the tabs of the window in front", action: .tool("browser") { _ in ["op": "tabs"] }),
        SayForm("Do steps in Chrome", fields: [.init("steps", "Straw lines, one a step: open example.com / click \"Sign in\" / type \"Search\" \"cats\"", multiline: true)],
                words: "straw click type fill press submit form automate browser drive", about: "clicking and typing in Chrome (it waits for Run on the Mac)",
                changes: true, asks: true, action: .tool("straw") { f in ["source": f["steps"] ?? ""] }),
        // MEMORY and the mind
        SayForm("Remember something", fields: [.init("category", choices: categories), .init("about", "who or what it's about"),
                                               .init("fact", "what to remember"), .init("date", "a day, like 2026-11-03, or 03-14 for every year", optional: true)],
                words: "remember memory save keep person people birthday date event fact preference", about: "something the person told you, kept",
                changes: true, next: ["What's coming up", "Recall something"], action: .tool("remember") { f in
                    var a: [String: Any] = ["category": f["category"] ?? "OTHERS", "about": f["about"] ?? ""]
                    if let fact = f["fact"] { a["text"] = fact }
                    if let date = f["date"] {
                        // A day with no year, about a person, is a birthday; any other is a date, with what it's about.
                        let yearly = date.range(of: #"^\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil
                        let birthday = f["category"] == "BIRTHDAYS" || (yearly && f["category"] == "PEOPLE")
                        a["notes"] = [birthday ? "birthday \(date)" : "date \(date) \(f["about"] ?? "")"]
                    }
                    return a
                }),
        SayForm("Recall something", "what do you know about {a name}", also: ["recall {a name}", "what do I know about {a name}", "who is {a name}"],
                words: "recall memory know who person birthday", about: "what's remembered about a name",
                next: ["Remember something"], action: .tool("recall") { f in ["name": f.at(0) ?? ""] }),
        SayForm("What's coming up", "what's coming up [this week | this month | today | in the next {a number of} days]",
                also: ["what's coming up"], words: "upcoming soon calendar birthday date event agenda reminder week month",
                about: "the days coming up: birthdays, events, dated notes", next: ["Remember something"],
                action: .tool("memory") { f in ["op": "upcoming", "days": days(f)] }),
        SayForm("What's filed under a kind", "what's filed under {a kind, like PEOPLE}", also: ["who is under {a kind, like PEOPLE}"],
                words: "memory members category people organizations list", about: "who or what MEMORY files under PEOPLE, LOCATIONS…",
                action: .tool("memory") { f in ["op": "members", "name": (f.at(0) ?? "").uppercased()] }),
        SayForm("Link two things", fields: [.init("from", "who or what"), .init("link", "a short verb, like works at"), .init("to", "who or what")],
                words: "mind link relate connect relationship graph", about: "a link in the mind: Ada works at Acme", changes: true,
                next: ["How two things connect"], action: .tool("mind") { f in ["op": "add", "from": f["from"] ?? "", "label": f["link"] ?? "", "to": f["to"] ?? ""] }),
        SayForm("How two things connect", fields: [.init("from", "who or what"), .init("to", "who or what")],
                words: "mind path between connected relationship", about: "the way from one thing to another in the mind",
                action: .tool("mind") { f in ["op": "path", "from": f["from"] ?? "", "to": f["to"] ?? ""] }),
        SayForm("Add a note to something", fields: [.init("about", "who or what"), .init("note", "the note, like todo call back Friday")],
                words: "mind note todo annotate", about: "a short note on a thing in the mind", changes: true,
                action: .tool("mind") { f in ["op": "note", "name": f["about"] ?? "", "note": f["note"] ?? ""] }),
        // Notes
        SayForm("Read a note", "read the note {its name}", also: ["read my note {its name}", "open the note {its name}"],
                words: "library note notes read open", about: "one of the person's notes", next: ["Add to a note", "Write a note"],
                action: .tool("library") { f in ["op": "read", "name": f.at(0) ?? ""] }),
        SayForm("Write a note", fields: [.init("name", "its name"), .init("text", "what it says (it replaces what was there)", multiline: true)],
                words: "library note notes write save create new list", about: "a note written (or rewritten)", changes: true,
                next: ["Read a note", "Add to a note"], action: .tool("library") { f in ["op": "write", "name": f["name"] ?? "", "text": f["text"] ?? ""] }),
        SayForm("Add to a note", fields: [.init("name", "its name"), .init("text", "what to add at its end", multiline: true)],
                words: "library note notes append add line journal log list", about: "a line added at the end of a note", changes: true,
                next: ["Read a note"], action: .tool("library") { f in ["op": "append", "name": f["name"] ?? "", "text": f["text"] ?? ""] }),
        SayForm("Find a note", "find the note about {a few words}", also: ["find a note about {a few words}", "which note has {a few words}"],
                words: "library note notes find which name", about: "notes by words in their names and text, the best first",
                next: ["Read a note"], action: .tool("library") { f in ["op": "find", "q": f.at(0) ?? ""] }),
        SayForm("Search my notes", "search my notes for {words}", also: ["search the notes for {words}"],
                words: "library note notes search text lines grep", about: "the lines of the notes that have some words",
                next: ["Read a note"], action: .tool("library") { f in ["op": "search", "q": f.at(0) ?? ""] }),
        SayForm("My notes", "what notes do I have", also: ["list my notes", "my notes", "what are my notes"],
                words: "library notes list all recent", about: "the notes, the latest changed first",
                next: ["Read a note"], action: .tool("library") { _ in ["op": "recent"] }),
        SayForm("Rename a note", fields: [.init("name", "its name now"), .init("new name", "what to call it")],
                words: "library note rename name move", about: "a note called something else", changes: true,
                action: .tool("library") { f in ["op": "rename", "name": f["name"] ?? "", "to": f["new name"] ?? ""] }),
        SayForm("Delete a note", "delete the note {its name}", also: ["remove the note {its name}", "throw away the note {its name}"],
                words: "library note delete remove trash", about: "a note moved to the library's Trash (it can be brought back)", changes: true,
                next: ["Bring a note back"], action: .tool("library") { f in ["op": "delete", "name": f.at(0) ?? ""] }),
        SayForm("Bring a note back", "bring back the note {its name}", also: ["restore the note {its name}", "undelete the note {its name}"],
                words: "library note restore undelete trash", about: "a deleted note, back from the Trash", changes: true,
                action: .tool("library") { f in ["op": "restore", "name": f.at(0) ?? ""] }),
        // Showing and copying
        SayForm("Show the person something", fields: [.init("title", "a title"), .init("text", "what to show (Markdown)", multiline: true)],
                words: "show display window present screen", about: "a window in front of everything on the Mac, with copy buttons", changes: true,
                action: .tool("show") { f in ["title": f["title"] ?? "", "text": f["text"] ?? ""] }),
        SayForm("Copy something", fields: [.init("text", "what to put on the clipboard", multiline: true)],
                words: "copy clipboard paste", about: "text on the person's clipboard, to paste", changes: true,
                action: .tool("copy") { f in ["text": f["text"] ?? ""] }),
        // How it works
        SayForm("Read a guide", "read the guide {its name}", also: ["read the guide about {its name}"],
                words: "docs guide help manual how", about: "one of the guides to this app",
                action: .tool("docs") { f in ["op": "read", "name": f.at(0) ?? ""] }),
        SayForm("Search the guides", "search the guides for {words}", words: "docs guide help manual how", about: "the guides' lines that have some words",
                next: ["Read a guide"], action: .tool("docs") { f in ["op": "search", "q": f.at(0) ?? ""] }),
        SayForm("The guides", "what guides are there", also: ["list the guides"], words: "docs guides help manual",
                about: "the guides there are", next: ["Read a guide"], action: .tool("docs") { _ in ["op": "list"] }),
        // Runs and Flow code
        SayForm("The latest runs", "what has run lately", also: ["what ran lately", "the latest runs", "what's running"],
                words: "runs history output status", about: "the latest runs on the Mac, and how each went",
                action: .tool("runs") { _ in ["op": "list"] }),
        SayForm("Run Flow code", fields: [.init("code", "Flow code, like run \"utilities/weather.py\" [\"Paris\"]", multiline: true)],
                words: "flow code program chain compose", about: "Flow code run on the Mac (it waits for Run)", changes: true, asks: true,
                action: .tool("run_flow_code") { f in ["source": f["code"] ?? "", "name": "Flow code"] }),
        SayForm("Check Flow code", fields: [.init("code", "Flow code", multiline: true)], words: "flow code check validate lint",
                about: "Flow code checked for mistakes, nothing run", next: ["Run Flow code"],
                action: .tool("check_flow") { f in ["source": f["code"] ?? ""] }),
        // Automation
        SayForm("Run something by itself", fields: [.init("what", "a script or flow, by its title"), .init("when", choices: AutomationTag.allCases.filter { $0 != .afterItem }.map { $0.title.lowercased() })],
                words: "automation automate schedule every morning daily trigger recurring", about: "a script or flow tagged to run on a schedule (it waits for Allow on the Mac)",
                changes: true, asks: true, action: .automation),
    ]

    // MARK: the folder's own

    /// How the examples that ship with the app are said (their files can't change without
    /// making them look edited); a script's own `# Say:` lines come first.
    static let exampleSay: [String: [String]] = [
        "utilities/weather.py": ["what's the weather in {a place}", "what's the weather"],
        "utilities/news.py": ["what's in the news about {a topic}", "what's in the news"],
        "utilities/timer.sh": ["set a timer for {how many minutes} minutes"],
        "utilities/alarm.sh": ["set an alarm for {when, like 7am or 20 minutes}"],
        "utilities/wikipedia.py": ["what does Wikipedia say about {a topic}"],
        "utilities/define.py": ["what does {a word} mean", "define {a word}"],
        "utilities/currency.py": ["convert money {an amount and two currencies, like 100 USD to EUR}", "how much is {an amount and two currencies, like 100 USD in EUR}"],
        "utilities/calc.py": ["work out {a sum, like 15% of 80}", "calculate {a sum, like 15% of 80}"],
        "utilities/convert.py": ["convert {what to convert, like 5 km to miles}"],
        "utilities/world-clock.py": ["what time is it in {a city}"],
        "utilities/speak.sh": ["say out loud {what to say}"],
        "utilities/password.py": ["make a password"],
        "utilities/battery.sh": ["how's the battery"],
        "utilities/public-ip.py": ["what's my public address"],
        "browser/google.sh": ["ask Google {a question}"],
        "browser/youtube-music.sh": ["play {a song, artist or album} on YouTube Music", "play some music"],
        "browser/youtube.sh": ["search YouTube for {what to look for}"],
        "translate.flow": ["translate {what to translate}"],
        "morning-briefing.flow": ["give me the morning briefing"],
    ]

    /// "nightly-backup" → "nightly backup".
    static func spoken(_ title: String) -> String {
        title.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
    }

    /// An input's prompt as a label: short, lowercase, no question mark.
    static func label(_ prompt: String) -> String {
        var p = prompt.trimmingCharacters(in: .whitespaces)
        // "A place (where you are unless set)": the words before the brackets.
        if let paren = p.firstIndex(of: "("), paren > p.startIndex { p = String(p[..<paren]).trimmingCharacters(in: .whitespaces) }
        if let colon = p.firstIndex(of: ":"), colon > p.startIndex { p = String(p[..<colon]) }
        p = p.trimmingCharacters(in: CharacterSet(charactersIn: "?.!: "))
        let words = p.split(separator: " ")
        if words.count > 6 { p = words.prefix(6).joined(separator: " ") }
        guard let first = p.first else { return "value" }
        return first.lowercased() + p.dropFirst()
    }

    /// A script's or a flow's template: its `# Say:` sentences (or the examples'), else one made
    /// from its name: inline for nothing or one value, labeled for more (or text it reads).
    static func form(_ item: ScriptItem, title: String) -> SayForm {
        let flow = item.grid.isFlow
        let name = spoken(item.title)
        let inputs = item.inputs
        let summary = item.summary ?? ""
        let words = ([name, summary] + item.tags + [APISearch.exampleTags[item.id] ?? ""]).joined(separator: " ")
        let action: SayForm.Action = flow ? .flow(item) : .script(item)
        let next = ["What happened"]
        let said = item.say.isEmpty ? exampleSay[item.id] ?? [] : item.say
        if !said.isEmpty {
            return SayForm(title, said[0], also: Array(said.dropFirst()) + ["run the \(name)", "run \(name)"], words: words, about: summary,
                           changes: true, asks: true, next: next, kind: flow ? "flow" : "script", action: action)
        }
        if inputs.isEmpty {
            return SayForm(title, "run the \(name)", also: ["run \(name)", name], words: words, about: summary,
                           changes: true, asks: true, next: next, kind: flow ? "flow" : "script", action: action)
        }
        if inputs.count == 1, inputs[0].kind == .argument {
            let blank = "{\(label(inputs[0].prompt))}"
            return SayForm(title, "\(name): \(blank)", also: ["run the \(name) with \(blank)", "run \(name) \(blank)"] + (inputs[0].optional ? ["run the \(name)", "run \(name)"] : []),
                           words: words, about: summary, changes: true, asks: true, next: next, kind: flow ? "flow" : "script", action: action)
        }
        var labels: [String] = []
        let fields = inputs.map { input -> SayForm.Field in
            var l = label(input.prompt)
            while labels.contains(l) { l += " again" }
            labels.append(l)
            return .init(l, input.why.map { "\(label(input.prompt)): \($0)" } ?? input.prompt, optional: input.optional, multiline: input.kind == .text)
        }
        return SayForm(title, fields: fields, words: words, about: summary, changes: true, asks: true, next: next, kind: flow ? "flow" : "script", action: action)
    }

    /// The folder's scripts and flows, a template each, every title its own ("Translate", and
    /// "Translate (a flow)" beside it).
    static func folder(_ c: Catalog) -> [SayForm] {
        var used: Set<String> = []
        var out: [SayForm] = []
        for item in c.scripts + c.flows {
            let name = spoken(item.title)
            var title = (name.first.map { String($0).uppercased() } ?? "") + name.dropFirst()
            if used.contains(title.lowercased()) {
                title += item.grid.isFlow ? " (a flow)" : item.grid == .browser ? " (in Chrome)" : " (\(item.grid.rawValue))"
            }
            while used.contains(title.lowercased()) { title += " again" }
            used.insert(title.lowercased())
            out.append(form(item, title: title))
        }
        return out
    }

    static let sayStopWords: Set<String> = ["know", "tell", "let", "like", "wonder", "if", "whether", "itll", "im", "id", "ive", "able", "help", "find", "out", "something", "thing", "thank", "thanks", "hi", "hello"]

    /// The templates that fit some words, the best first (the conversation's own aside): found by
    /// their titles and wording, then what they're for, then their blanks, a rare word counting
    /// for more than a common one. Of two as good, the one the client has used more comes first.
    static func search(_ q: String, in forms: [SayForm], used: [String: Int] = [:], limit: Int = 8) -> [SayForm] {
        let all = APISearch.query(q)
        // How a request is put ("I need to know if", "tell me whether") says nothing of what it's for.
        let kept = all.filter { !sayStopWords.contains($0) }
        let terms = kept.isEmpty ? all : kept
        guard !terms.isEmpty else { return [] }
        let candidates = forms.filter { $0.kind != "builtin" }
        let docs = candidates.map { f in
            APISearch.Doc(fields: [
                (APISearch.set([f.title] + f.formerly + f.sentences + f.fields.map(\.label)), 4),
                (APISearch.set([f.words, f.about]), 3),
                (APISearch.set(f.fields.compactMap(\.blank) + f.fields.flatMap(\.choices)), 1),
            ])
        }
        let scores = docs.map { d in terms.map(d.score) }
        let rarity: [Double] = terms.indices.map { k in
            let having = scores.filter { $0[k] > 0 }.count
            return 1 + log(Double(max(candidates.count, 1)) / Double(max(having, 1)))
        }
        var hits: [(form: SayForm, strong: Int, score: Double, order: Int)] = []
        for (k, f) in candidates.enumerated() where scores[k].contains(where: { $0 > 0 }) {
            let strong = scores[k].filter { $0 >= 2 }.count
            let score = zip(scores[k], rarity).reduce(0) { $0 + Double($1.0) * $1.1 }
            hits.append((f, strong, score, k))
        }
        let most = hits.map(\.strong).max() ?? 0
        let floor = max(most > 0 ? 1 : 0, most - (terms.count >= 3 ? 1 : 0))
        return hits.filter { $0.strong >= floor }.sorted { a, b in
            if a.strong != b.strong { return a.strong > b.strong }
            if abs(a.score - b.score) > 0.001 { return a.score > b.score }
            let ua = used[a.form.title] ?? 0, ub = used[b.form.title] ?? 0
            if ua != ub { return ua > ub }
            return a.order < b.order
        }.prefix(limit).map(\.form)
    }

    /// Every template there is now: the conversation's, the tools' that are switched on, and the
    /// folder's (when listing it is on).
    static func all(catalog: Catalog?, settings: APISettings) -> [SayForm] {
        let tools = self.tools.filter { form in
            guard case let .tool(name, _) = form.action else { return settings.isOn(.run) || settings.isOn(.compose) }
            guard let t = Tools.named(name)?.tool else { return false }
            return t.endpoint.map(settings.isOn) ?? true
        }
        let folder = settings.isOn(.catalog) ? catalog.map(folder) ?? [] : []
        return builtins + tools + folder
    }
}
