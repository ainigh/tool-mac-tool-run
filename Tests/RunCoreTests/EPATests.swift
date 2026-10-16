import XCTest
@testable import RunCore

/// A host whose `epa` is pretend: what it "prints" is given, and goes through the same
/// `EPA.Session` the real one uses, answering its questions with `answers`.
final class EPAHost: FlowHost, @unchecked Sendable {
    var printed: [String] = []
    var code: Int32 = 0
    var answers: [FlowAnswer] = []
    var asked: [FlowQuestion] = []
    var sent: [String] = []
    var shown = ""
    var words: [[String]] = []
    var isCancelled: Bool { false }
    var environment: [String: String] { [:] }

    func runScript(_ name: String, args: [String], stdin: String?, pos: Pos) throws -> RunResult {
        throw FlowError(.run, pos, "no scripts here")
    }
    func runShell(_ command: String, stdin: String?, pos: Pos) throws -> RunResult {
        RunResult(code: 0, out: "", err: "", seconds: 0)
    }
    func say(_ text: String) {}
    func notify(_ text: String) {}
    func ask(_ question: FlowQuestion) -> FlowAnswer {
        asked.append(question)
        return answers.isEmpty ? .unavailable : answers.removeFirst()
    }
    func runEPA(_ words: [String], pos: Pos) throws -> EPA.Outcome {
        self.words.append(words)
        let session = EPA.Session(line: pos.line, ask: { self.ask($0) }, send: { self.sent.append($0) }, show: { self.shown += $0 })
        // In pieces that split lines, as a pipe gives them.
        let all = printed.joined(separator: "\n") + "\n"
        var rest = Substring(all)
        while !rest.isEmpty {
            session.feed(String(rest.prefix(17)))
            rest = rest.dropFirst(17)
        }
        session.finish()
        return session.outcome(code: code)
    }
}

final class EPATests: XCTestCase {
    private func json(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }

    private let failed: [String: Any] = [
        "type": "step", "phase": "end", "id": "do", "title": "epa do", "status": "failed",
        "error": ["human": "Microsoft 365 isn't connected yet.", "next": "Put MS_TENANT_ID in .env."],
        "text": "  ✗ epa do — Microsoft 365 isn't connected yet.\n    Next: Put MS_TENANT_ID in .env.",
    ]

    func testItShowsEPAsOwnWordsAndGivesThemBack() throws {
        let host = EPAHost()
        host.printed = [
            json(["type": "hello", "version": "0.23.0", "text": "epa v0.23.0"]),
            json(["type": "step", "phase": "start", "id": "a", "title": "Resend", "text": "  → Resend…"]),
            json(["type": "next", "message": "x", "text": ""]),
            "Not JSON: a listing line",
            json(["type": "step", "phase": "end", "id": "a", "title": "Resend", "status": "reused", "text": "  ↺ Resend — already in place"]),
        ]
        let out = try Flow.run("epa [\"connect\"; \"resend\"]", host: host)
        XCTAssertEqual(out.string, ("epa v0.23.0\n  → Resend…\nNot JSON: a listing line\n  ↺ Resend — already in place"))
        XCTAssertEqual(host.words, [["connect", "resend"]])
        XCTAssertEqual(host.shown, "epa v0.23.0\n  → Resend…\nNot JSON: a listing line\n  ↺ Resend — already in place\n")
    }

    func testALineEndingInCRLFDoesntHideTheQuestionAfterIt() throws {
        // Node prints its warnings with \r\n on some systems; the question after one must be asked.
        let asked = Box<[FlowQuestion]>([])
        let session = EPA.Session(ask: { asked.value.append($0); return .yes }, send: { _ in }, show: { _ in })
        session.feed("(node:1) Warning: x\r")
        session.feed("\n" + json(["type": "ask", "kind": "consent", "consequence": "Delete it"]) + "\r\n")
        session.feed("done\r\n")
        session.finish()
        XCTAssertEqual(asked.value.count, 1)
        XCTAssertEqual(session.outcome(code: 0).text, "(node:1) Warning: x\n  ❓ Delete it → Go ahead\ndone")
    }

    func testAFailureStopsTheFlowWithEPAsSentenceAndNextStep() {
        let host = EPAHost()
        host.printed = [json(failed)]
        host.code = 1
        XCTAssertThrowsError(try Flow.run("epa [\"do\"; \"microsoft\"; \"block-sign-in\"; \"jane@acme.com\"]", host: host)) { e in
            let e = e as! FlowError
            XCTAssertEqual(e.message, "EPA: Microsoft 365 isn't connected yet.")
            XCTAssertEqual(e.fix, "Put MS_TENANT_ID in .env.")
        }
    }

    func testAttemptEpaKeepsGoing() throws {
        let host = EPAHost()
        host.printed = [json(failed)]
        host.code = 1
        let v = try Flow.run("let r = attemptEpa [\"doctor\"]\n$\"{r.ok} {r.code} {r.err}\"", host: host)
        XCTAssertEqual(v.string, ("false 1 Microsoft 365 isn't connected yet.\nNext: Put MS_TENANT_ID in .env."))
        // An exit code with no words still fails, saying so.
        host.printed = ["boom"]
        XCTAssertEqual(try Flow.run("(attemptEpa [\"doctor\"]).err", host: host).string, ("epa ended with exit code 1."))
    }

    func testItsGoAheadIsAskedHereAndTheAnswerTypedIntoIt() throws {
        let host = EPAHost()
        let ask: [String: Any] = ["type": "ask", "id": 1, "kind": "consent", "cost": "mutating", "title": "Block", "consequence": "Blocks jane@acme.com from signing in"]
        host.printed = [json(ask)]
        host.answers = [.yes]
        _ = try Flow.run("epa [\"do\"; \"microsoft\"; \"block-sign-in\"; \"jane@acme.com\"]", host: host)
        XCTAssertEqual(host.asked.first?.prompt, "Blocks jane@acme.com from signing in")
        XCTAssertEqual(host.asked.first?.destructive, false)
        XCTAssertEqual(host.asked.first?.line, 1)
        XCTAssertEqual(host.sent, ["yes\n"])
        XCTAssertTrue(host.shown.contains("→ Go ahead"))

        // What can't be undone: said so, and the typed word EPA wants is what's sent.
        host.sent = []
        host.asked = []
        host.printed = [json(["type": "ask", "id": 1, "kind": "consent", "cost": "destructive", "title": "Replace", "consequence": "Replaces the MX records", "typed": "REPLACE"])]
        host.answers = [.yes]
        _ = try Flow.run("epa [\"gmail\"; \"me@acme.com\"]", host: host)
        XCTAssertEqual(host.asked.first?.destructive, true)
        XCTAssertTrue(host.asked.first?.prompt.contains("can't be undone") == true)
        XCTAssertEqual(host.sent, ["REPLACE\n"])

        // No one to ask: EPA is told no (it then says which flag would say yes).
        host.sent = []
        host.answers = []
        _ = try Flow.run("epa [\"gmail\"; \"me@acme.com\"]", host: host)
        XCTAssertEqual(host.sent, ["no\n"])
    }

    func testStopAtItsQuestionStopsTheFlow() {
        let host = EPAHost()
        host.printed = [json(["type": "ask", "id": 1, "kind": "consent", "consequence": "Creates a database"])]
        host.answers = [.stop]
        XCTAssertThrowsError(try Flow.run("epa [\"secure\"; \"acme.com\"]\nprint \"after\"", host: host)) { e in
            XCTAssertEqual((e as! FlowError).stage, .stopped)
        }
        XCTAssertEqual(host.sent, ["no\n"])
    }

    func testASecretIsAskedAsOneAndNeverShown() throws {
        let host = EPAHost()
        host.printed = [json(["type": "ask", "id": 1, "kind": "secret", "question": "Paste the SMTP token"]),
                        json(["type": "reveal", "label": "Temporary password", "value": "pa55"])]
        host.answers = [.text("t0ken")]
        _ = try Flow.run("epa [\"gmail\"; \"me@acme.com\"]", host: host)
        XCTAssertEqual(host.asked.first?.secret, true)
        XCTAssertEqual(host.sent, ["t0ken\n"])
        XCTAssertFalse(host.shown.contains("t0ken"))
        XCTAssertTrue(host.shown.contains("Temporary password:\n\n      pa55"))
    }

    func testSigningInAsksForAKeyWithItsPageAndAPlainValueInSight() throws {
        // `epa connect freshdesk` with nothing set: the address in plain sight, then the key
        // hidden, with the page it's made on and where EPA keeps it.
        let host = EPAHost()
        host.printed = [json(["type": "ask", "id": 1, "kind": "secret", "question": "FRESHDESK_DOMAIN:", "visible": true, "envName": "FRESHDESK_DOMAIN"]),
                        json(["type": "ask", "id": 2, "kind": "secret", "question": "FRESHDESK_API_KEY:", "url": "https://acme.freshdesk.com/", "envName": "FRESHDESK_API_KEY"])]
        host.answers = [.text("acme"), .text("k3y")]
        _ = try Flow.run("epa [\"connect\"; \"freshdesk\"]", host: host)
        XCTAssertEqual(host.asked.map(\.secret), [false, true])
        XCTAssertEqual(host.asked.last?.link, URL(string: "https://acme.freshdesk.com/"))
        XCTAssertEqual(host.asked.last?.savedAs, "FRESHDESK_API_KEY")
        XCTAssertEqual(host.sent, ["acme\n", "k3y\n"])
        XCTAssertTrue(host.shown.contains("FRESHDESK_DOMAIN: → acme"))
        XCTAssertFalse(host.shown.contains("k3y"))
    }

    func testAMistypedCommandIsCaughtBeforeAnythingRuns() {
        XCTAssertThrowsError(try Flow.check("epa [\"conect\"; \"resend\"]")) { e in
            let e = e as! FlowError
            XCTAssertEqual(e.message, "EPA has no command \"conect\".")
            XCTAssertTrue(e.fix?.hasPrefix("Did you mean \"connect\"?") == true)
        }
        XCTAssertNoThrow(try Flow.check("let w = \"doctor\"\nepa [w]"))
        XCTAssertThrowsError(try Flow.run("epa [\"--json\"]", host: EPAHost()))
    }

    func testTheBlockReadsBackAndRunsTheSameWords() throws {
        var doc = FlowDocument(summary: "EPA", blocks: [])
        let slot = BlockSlot(parent: nil, branch: .body, index: 0)
        var b = doc.newBlock(.epa, script: "Connect a Sending Domain", at: slot)
        XCTAssertEqual(b.script, "connect")
        XCTAssertEqual(b.args, ["resend", "--domain", "example.com", "--test-to", "you@example.com"])
        XCTAssertEqual(b.headline, "EPA: Connect a Sending Domain")
        b.args[2] = "{domain}"
        var ask = FlowBlock(.ask)
        ask.text = "Which domain?"
        ask.name = "domain"
        doc.blocks = [ask, b]
        var check = doc.newBlock(.epa, script: "doctor", at: BlockSlot(parent: nil, branch: .body, index: 2))
        check.keepGoing = true
        doc.blocks.append(check)
        let text = doc.written().text
        XCTAssertTrue(text.contains("let connect = epa [\"connect\"; \"resend\"; \"--domain\"; domain; \"--test-to\"; \"you@example.com\"]"), text)
        XCTAssertTrue(text.contains("let connections = attemptEpa [\"doctor\"]"), text)
        XCTAssertNoThrow(try Flow.check(text))
        let back = FlowDocument.read(text)
        XCTAssertEqual(back.blocks.map(\.type), [.ask, .epa, .epa])
        XCTAssertEqual(back.blocks[1].args, b.args)
        XCTAssertTrue(back.blocks[2].keepGoing)
        XCTAssertEqual(back.written().text, text)
        // Its result's kind follows Keep going (offering .ok tests to an If).
        XCTAssertEqual(back.variables(at: BlockSlot(parent: nil, branch: .body, index: 3)).last?.kind, .result)
    }

    func testTheLibraryOffersOnlyRealCommands() {
        for c in EPA.commands {
            XCTAssertTrue(EPA.commandNames.contains(c.name), c.name)
            XCTAssertEqual(EPA.command(named: c.name, args: c.args)?.name, c.name)
        }
        XCTAssertEqual(Set(EPA.commands.map(\.id)).count, EPA.commands.count, "titles are unique")
        XCTAssertEqual(EPA.command(named: "connect", args: ["resend", "--domain", "a.com"])?.title, "Connect a Sending Domain")
        XCTAssertEqual(EPA.command(named: "connect", args: ["cloudflare"])?.title, "Connect a Service")
        XCTAssertEqual(EPA.commandLine(["connect", "a b"], folder: URL(fileURLWithPath: "/tmp/x")), "cd /tmp/x && epa connect 'a b'")
    }

    // MARK: the recipes

    func testEveryRecipeChecksAndOpensAsBlocksOnly() throws {
        let names = (Examples.scripts + Examples.epaScripts).map(\.0)
        for (name, source) in Examples.epaFlows {
            XCTAssertNoThrow(try Flow.check(source, scripts: names), name)
            let doc = FlowDocument.read(source)
            XCTAssertFalse(doc.summary.isEmpty, "\(name) says what it does on its cell")
            func all(_ bs: [FlowBlock]) -> [FlowBlock] { bs.flatMap { [$0] + all($0.children) + all($0.otherwise) } }
            XCTAssertFalse(all(doc.blocks).contains { $0.type == .code }, "\(name) is all blocks:\n\(source)")
            XCTAssertTrue(all(doc.blocks).contains { $0.type == .epa }, name)
            XCTAssertEqual(doc.written().text, source, "\(name) is written back unchanged")
        }
    }

    func testTheRecipesAreAddedOnceAndKeepWhatsThere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epa-recipes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = Library(root: root)
        XCTAssertFalse(lib.hasEPARecipes)
        try FileManager.default.createDirectory(at: lib.composerFolder, withIntermediateDirectories: true)
        try "// mine\n".write(to: lib.composerFolder.appendingPathComponent("epa-person.flow"), atomically: true, encoding: .utf8)
        let added = try lib.addEPARecipes()
        XCTAssertEqual(added.count, Examples.epaScripts.count + Examples.epaFlows.count - 1)
        XCTAssertEqual(try String(contentsOf: lib.composerFolder.appendingPathComponent("epa-person.flow"), encoding: .utf8), "// mine\n")
        XCTAssertTrue(lib.hasEPARecipes)
        XCTAssertEqual(try lib.addEPARecipes(), [])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(EPA.setupScript).path))
        // The scripts are scripts on the grid (with their first comment), the keys file isn't.
        let scripts = lib.scripts().map(\.id)
        XCTAssertTrue(scripts.contains(EPA.setupScript) && scripts.contains("epa-keys.sh"))
        XCTAssertEqual(lib.scripts().first { $0.id == EPA.setupScript }?.summary, "Installs EPA (or updates it): Node.js, the kit, and its epa command. Safe to run again.")
        // Check Setup speaks of EPA once it's in use, and of its keys.
        let lines = Doctor.epa(lib, flows: lib.flows(), path: "/nonexistent")
        XCTAssertEqual(lines.first?.status, .problem)
        XCTAssertTrue(lines.first?.title.hasPrefix("EPA isn't set up yet (9 flows use it)") == true, lines.first?.title ?? "")
        XCTAssertEqual(lines.first?.fix, EPA.setupFix)
        XCTAssertTrue(lines.last?.title.hasPrefix("No EPA keys yet") == true)
        try "# a comment\nRESEND_API_KEY=re_x\n\nFRESHDESK_DOMAIN=acme\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertTrue(Doctor.epa(lib, flows: lib.flows(), path: "/nonexistent").last?.title.hasPrefix("EPA keys: 2 in") == true)
        XCTAssertFalse(lib.scripts().map(\.id).contains(".env"))
        // Saved with Windows line endings: each line still counts.
        try "A=1\r\nB=2\r\nC=3\r\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertTrue(Doctor.epa(lib, flows: lib.flows(), path: "/nonexistent").last?.title.hasPrefix("EPA keys: 3 in") == true)
        // A folder with nothing of EPA's: nothing said.
        XCTAssertEqual(Doctor.epa(Library(root: root.appendingPathComponent("none")), flows: [], path: "/nonexistent"), [])
    }

    /// The installer runs scripts/setup-epa.sh; the app puts Examples.setupEPA in the folder:
    /// the same file.
    func testTheSetupScriptIsTheInstallersOne() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: repo.appendingPathComponent("scripts/setup-epa.sh"), encoding: .utf8)
        XCTAssertEqual(file, Examples.setupEPA, "scripts/setup-epa.sh and Examples.setupEPA must be the same (copy one onto the other)")
        XCTAssertEqual(Remedy.install("epa"), "Run setup-epa on the Scripts grid (Add the EPA Recipes puts it there), then run it again.")
    }

    func testLinksInOutputAreFoundWithoutTheirSentencesFullStop() {
        let text = "Next: get a key at https://resend.com/api-keys. Then open (http://127.0.0.1:4747/?key=ab12), or https://x.example/a,b"
        let found = Links.find(in: text).map { String(text[$0.range]) }
        XCTAssertEqual(found, ["https://resend.com/api-keys", "http://127.0.0.1:4747/?key=ab12", "https://x.example/a,b"])
        XCTAssertTrue(Links.find(in: "no links: file://nothing or https:// alone").isEmpty || Links.find(in: "no links: https:// alone").isEmpty)
        XCTAssertEqual(EPA.isUsed(in: "let x = epa [\"doctor\"]"), true)
        XCTAssertEqual(EPA.isUsed(in: "x |> attemptEpa[\"doctor\"]"), true)
        XCTAssertEqual(EPA.isUsed(in: "let sepa [1] // tepa"), false)
    }

    /// macOS's bash 3.2 reads a byte of "…" (or any non-ASCII) right after `$NAME` as part of the
    /// name: `"$KIT…"` was `KIT\xE2: unbound variable` under set -u. Every script we write says ${NAME}.
    func testNoScriptPutsNonASCIIRightAfterAVariable() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var scripts = (Examples.scripts + Examples.epaScripts).map { ($0.0, $0.1) }
        for file in ["install.sh", "scripts/setup-epa.sh", "scripts/build-app.sh"] {
            scripts.append((file, try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)))
        }
        let risky = try NSRegularExpression(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]"#)
        for (name, text) in scripts {
            let hits = risky.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            XCTAssertEqual(hits, [], "\(name): write ${NAME} before a non-ASCII character")
        }
    }

    func testARecipeStillAsAnEarlierVersionWroteItIsUpdatedAndAnEditedOneIsNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epa-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = Library(root: root)
        try lib.ensure()
        let setup = root.appendingPathComponent(EPA.setupScript)
        // Each earlier version really is an earlier one (its differences were all found).
        for old in Examples.earlierEPARecipes[EPA.setupScript] ?? [] { XCTAssertNotEqual(old, Examples.setupEPA) }
        XCTAssertEqual(Set(Examples.earlierEPARecipes[EPA.setupScript] ?? []).count, 2)
        let earlier = try XCTUnwrap(Examples.earlierEPARecipes[EPA.setupScript]?.first)
        XCTAssertTrue(earlier.contains("into $KIT…"))
        try earlier.write(to: setup, atomically: true, encoding: .utf8)
        XCTAssertEqual(lib.updateEPARecipes(), [setup])
        XCTAssertEqual(try String(contentsOf: setup, encoding: .utf8), Examples.setupEPA)
        XCTAssertEqual(lib.updateEPARecipes(), [])
        // Changed by someone: left as it is.
        try (earlier + "# mine\n").write(to: setup, atomically: true, encoding: .utf8)
        XCTAssertEqual(lib.updateEPARecipes(), [])
        XCTAssertTrue(try String(contentsOf: setup, encoding: .utf8).hasSuffix("# mine\n"))
    }
}

