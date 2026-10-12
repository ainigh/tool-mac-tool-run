import Foundation

/// EPA (Enter-Price Automation, github.com/ainigh/ENTER-PRICE-AUTOMATION): the kit for shipping on
/// Cloudflare and the services around it (Resend, SendGrid, SES, MailUp, Microsoft 365, Google,
/// Freshdesk), through its one command, `epa`. Flows run it with `epa [...]` and `attemptEpa [...]`
/// and the block editor's EPA steps.
///
/// It's run as `epa … --ask-json`: every line it prints is an event carrying the words a terminal
/// would show (`text`), so a run here reads exactly as it does in a terminal; and each go-ahead or
/// secret it needs is an `{"type":"ask"}` line, asked in this app's own question window (with the
/// consequence EPA names, and "can't be undone" when it can't), answered on its input.
public enum EPA {
    /// The command, on the scripts' PATH (the setup script links it into ~/.local/bin).
    public static let program = "epa"
    /// The script that installs (and updates) it, put in the folder by Add the EPA Recipes.
    public static let setupScript = "setup-epa.sh"
    /// The file EPA reads its keys from, in the scripts folder (EPA runs there).
    public static let keysFile = ".env"
    public static let repository = "ainigh/ENTER-PRICE-AUTOMATION"

    /// Whether a flow runs EPA (an `epa [...]` or `attemptEpa [...]` in it).
    public static func isUsed(in flow: String) -> Bool {
        flow.range(of: #"(^|[^A-Za-z0-9_'])(epa|attemptEpa)\s*\["#, options: .regularExpression) != nil
    }

    /// Where `epa` is on this PATH, or nil.
    public static func find(path: String) -> String? { ShellEnvironment.find(program, path: path) }

    /// What a flow says when there's no `epa` to run.
    static let notSetUp = "EPA isn't set up on this Mac yet, so there's no `epa` command to run."
    public static let setupFix = "Run setup-epa on the Scripts grid (Add the EPA Recipes puts it there), then run this again."

    // MARK: what it can do

    /// One thing `epa` does, as the block editor's library and the guide offer it.
    public struct Command: Identifiable, Sendable, Equatable {
        /// What it's called in the library (unique).
        public var id: String { title }
        public let title: String
        /// The `epa` command (`connect`, `secure`…).
        public let name: String
        /// The words after it, ready to change (an example).
        public let args: [String]
        public let summary: String
        /// It can change something (EPA asks before it does).
        public let changes: Bool

        public var symbol: String {
            switch name {
            case "doctor": "stethoscope"
            case "connect": "link"
            case "secure": "lock.shield"
            case "gmail": "envelope"
            case "see", "person": "magnifyingglass"
            case "onboard": "person.badge.plus"
            case "offboard": "person.badge.minus"
            case "sweep": "trash.slash"
            case "lists": "list.bullet.rectangle"
            case "atlas": "map"
            default: "bolt"
            }
        }
    }

    /// Everything the library offers, most used first. `epa help` has every option.
    public static let commands: [Command] = [
        Command(title: "Check Connections", name: "doctor", args: [],
                summary: "Checks every service EPA can reach (read-only: one harmless question each) and says the one next step.", changes: false),
        Command(title: "Connect a Service", name: "connect", args: ["resend"],
                summary: "Connects a service (cloudflare, cloudflare-email, resend, sendgrid, ses, mailup, microsoft, google, freshdesk) and proves it works. Safe to run again.", changes: true),
        Command(title: "Connect a Sending Domain", name: "connect", args: ["resend", "--domain", "example.com", "--test-to", "you@example.com"],
                summary: "Sets up a domain to send email from: the vendor, its DNS records on Cloudflare, verification, then a test email.", changes: true),
        Command(title: "Secure a Site", name: "secure", args: ["www.example.com"],
                summary: "Puts email sign-in in front of a site on Cloudflare; members-only parts are marked data-epa-protected.", changes: true),
        Command(title: "Your Domain in Gmail", name: "gmail", args: ["you@yourdomain.com", "--gmail", "you@gmail.com"],
                summary: "Use you@yourdomain.com from a free Gmail: mail arrives through Cloudflare Email Routing, and Gmail sends through Cloudflare.", changes: true),
        Command(title: "Look Up a Person", name: "person", args: ["jane@acme.com"],
                summary: "Everything every connected service knows about one address (read-only).", changes: false),
        Command(title: "Onboard a Joiner", name: "onboard", args: ["jane@acme.com", "--name", "Jane Doe"],
                summary: "A joiner in one go-ahead: the Microsoft 365 account, licence, groups and manager, and a note on the request's ticket.", changes: true),
        Command(title: "Offboard a Leaver", name: "offboard", args: ["jane@acme.com", "--hand-to", "sam@acme.com"],
                summary: "A leaver everywhere at once: sign-in blocked, out-of-office on, tickets and mail handed over. One go-ahead.", changes: true),
        Command(title: "Sweep a Phishing Email", name: "sweep", args: ["from:@phish.example newer_than:2d", "--mailbox", "all"],
                summary: "Finds one email in every mailbox, counts it, then (after asking) moves it to the Trash everywhere.", changes: true),
        Command(title: "See in a Provider", name: "see", args: ["resend", "domains"],
                summary: "Reads one thing from a provider (read-only). With only the provider, lists every read with an example.", changes: false),
        Command(title: "Do at a Provider", name: "do", args: ["microsoft", "block-sign-in", "jane@acme.com"],
                summary: "Makes one change at a provider: says exactly what, and asks first. With only the provider, lists every action.", changes: true),
        Command(title: "Import a MailUp List", name: "lists", args: ["import-mailup", "--mailup-list", "1"],
                summary: "Moves a MailUp list to mailing lists on Cloudflare, keeping every state and the consent evidence.", changes: true),
        Command(title: "Open the Atlas", name: "atlas", args: [],
                summary: "A local page with every provider's reads and actions, try-it buttons, recipes and costs. It runs until you press Stop.", changes: false),
    ]

    /// Every command `epa` knows (what a flow is checked against).
    public static let commandNames: [String] = ["doctor", "connect", "secure", "gmail", "lists", "see", "do", "person",
                                                "offboard", "onboard", "sweep", "atlas", "help", "version"]

    /// The library entry for a step running `name` with `args`: of those with the same command,
    /// the one sharing most of its options (and first word), else the plainest.
    public static func command(named name: String, args: [String] = []) -> Command? {
        func score(_ c: Command) -> Int {
            let options = c.args.filter { $0.hasPrefix("--") && args.contains($0) }.count
            return options * 2 + (c.args.first.map { args.first == $0 } == true ? 1 : 0)
        }
        return commands.filter { $0.name == name }.enumerated().max { a, b in
            score(a.element) != score(b.element) ? score(a.element) < score(b.element) : a.offset > b.offset
        }?.element
    }

    // MARK: how it's run

    /// The words after `epa` for a run from here.
    static func arguments(_ words: [String]) -> [String] { words + ["--ask-json"] }

    /// What a person would type in a terminal to do the same (shown in Runs, and copied by
    /// Copy Command): `cd` into the folder, then `epa` and the words.
    public static func commandLine(_ words: [String], folder: URL) -> String {
        "cd \(ShellEnvironment.quote(folder.path)) && " + ([program] + words).map(ShellEnvironment.quote).joined(separator: " ")
    }

    /// How a run of `epa` went.
    public struct Outcome: Sendable, Equatable {
        /// What it showed, as a terminal would.
        public var text: String
        public var code: Int32
        /// EPA's own sentence for what failed (the last failure), and its one next step.
        public var failure: String?
        public var next: String?
        /// The person answered Stop to one of its questions.
        public var stoppedByPerson = false
        public var ok: Bool { code == 0 && failure == nil }
    }

    /// Reads what `epa --ask-json` prints, line by line: shows each event's words, asks its
    /// questions, and keeps what failed and the next step. Fed from any thread, one piece at a time.
    public final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private var shown: [String] = []
        private(set) var failure: String?
        private(set) var next: String?
        private(set) var stoppedByPerson = false
        private let ask: (FlowQuestion) -> FlowAnswer
        private let send: (String) -> Void
        private let closeInput: () -> Void
        private let show: (String) -> Void
        private let line: Int

        /// `ask`: asks the person (and waits). `send`: types into epa's input. `closeInput`: ends
        /// it (no answer is coming). `show`: a line for the run's output, as it comes.
        public init(line: Int = 0, ask: @escaping (FlowQuestion) -> FlowAnswer, send: @escaping (String) -> Void,
                    closeInput: @escaping () -> Void = {}, show: @escaping (String) -> Void) {
            self.line = line
            self.ask = ask
            self.send = send
            self.closeInput = closeInput
            self.show = show
        }

        /// A piece of what it printed.
        public func feed(_ text: String) {
            lock.lock()
            pending += text
            var lines: [String] = []
            while let nl = pending.firstIndex(of: "\n") {
                lines.append(String(pending[..<nl]))
                pending = String(pending[pending.index(after: nl)...])
            }
            lock.unlock()
            lines.forEach(handle)
        }

        /// It ended: what's left of its last line.
        public func finish() {
            lock.lock()
            let rest = pending
            pending = ""
            lock.unlock()
            if !rest.isEmpty { handle(rest) }
        }

        public func outcome(code: Int32) -> Outcome {
            lock.lock()
            defer { lock.unlock() }
            var failure = self.failure
            // A failure EPA didn't put in words (it crashed, or isn't the version that speaks JSON).
            if code != 0, failure == nil, !stoppedByPerson {
                failure = "epa ended with exit code \(code)."
            }
            return Outcome(text: shown.joined(separator: "\n"), code: code, failure: failure, next: next, stoppedByPerson: stoppedByPerson)
        }

        private func say(_ text: String) {
            lock.lock()
            shown.append(text)
            lock.unlock()
            show(text + "\n")
        }

        private func handle(_ raw: String) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else {
                // Not an event (a listing, Node's own warning): shown as it is.
                say(line)
                return
            }
            switch type {
            case "ask":
                answer(event)
                return
            case "reveal":
                let label = event["label"] as? String ?? "Secret"
                let value = event["value"] as? String ?? ""
                say("\n  \(label):\n\n      \(value)\n\n  (Copy it now: EPA keeps it out of its own log.)\n")
                return
            case "summary":
                lock.lock()
                next = (event["next"] as? String) ?? next
                lock.unlock()
            case "step" where event["status"] as? String == "failed":
                let error = event["error"] as? [String: Any]
                lock.lock()
                failure = (error?["human"] as? String) ?? (event["message"] as? String) ?? failure
                next = (error?["next"] as? String) ?? next
                lock.unlock()
            case "error":
                lock.lock()
                failure = (event["human"] as? String) ?? failure
                next = (event["next"] as? String) ?? next
                lock.unlock()
                if event["text"] == nil {
                    say("✗ \(event["human"] as? String ?? "It stopped.")" + ((event["next"] as? String).map { "\nNext: \($0)" } ?? ""))
                    return
                }
            default:
                break
            }
            if let text = event["text"] as? String, !text.isEmpty { say(text) }
        }

        /// One of its questions, asked here; the answer typed into it.
        private func answer(_ event: [String: Any]) {
            let kind = event["kind"] as? String ?? "consent"
            if kind == "secret" {
                let question = event["question"] as? String ?? "EPA needs a secret."
                let answer = ask(FlowQuestion(kind: .text, prompt: question, line: line, secret: true))
                switch answer {
                case let .text(value):
                    say("  ❓ \(question) → (typed, not shown)")
                    send(value + "\n")
                case .stop:
                    stop(question)
                    closeInput()
                default:
                    say("  ❓ \(question) → no answer")
                    closeInput()
                }
                return
            }
            let consequence = (event["consequence"] as? String) ?? (event["title"] as? String) ?? "Make this change"
            let destructive = (event["cost"] as? String) == "destructive"
            let word = event["typed"] as? String ?? "DELETE"
            let prompt = destructive ? "\(consequence)\n\nThis can't be undone." : consequence
            switch ask(FlowQuestion(kind: .proceed, prompt: prompt, line: line, destructive: destructive)) {
            case .yes, .text:
                say("  ❓ \(consequence) → Go ahead")
                send((destructive ? word : "yes") + "\n")
            case .stop:
                stop(consequence)
                send("no\n")
            case .no:
                say("  ❓ \(consequence) → No")
                send("no\n")
            case .unavailable:
                say("  ❓ \(consequence) → no one here to answer, so: no")
                send("no\n")
            }
        }

        private func stop(_ question: String) {
            lock.lock()
            stoppedByPerson = true
            lock.unlock()
            say("  ❓ \(question) → Stop")
        }
    }
}

/// The web links in a run's output (EPA's next steps name pages; the Atlas prints its address),
/// so the output can make them clickable.
public enum Links {
    private static let pattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`\])}]+"#)

    /// Each link: where it is in `text`, and the address.
    public static func find(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard text.contains("://") else { return [] }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard var r = Range(m.range, in: text) else { return nil }
            // A sentence's own full stop or comma isn't part of the address.
            while r.upperBound > r.lowerBound, let last = text[r].last, ".,;:!?".contains(last) {
                r = r.lowerBound..<text.index(before: r.upperBound)
            }
            guard let url = URL(string: String(text[r])), url.host != nil else { return nil }
            return (r, url)
        }
    }
}
