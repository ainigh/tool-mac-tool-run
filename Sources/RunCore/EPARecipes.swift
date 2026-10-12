import Foundation

/// The EPA recipes: two scripts (set EPA up, open its keys) and flows for the jobs EPA is for, each
/// made only of blocks (so the block editor shows every step) and each asking for what it needs.
/// EPA asks before it changes anything, in the app's own window, so a recipe doesn't ask again.
extension Examples {
    public static let epaScripts: [(String, String)] = [
        (EPA.setupScript, setupEPA),
        ("epa-keys.sh", """
        #!/bin/bash
        # Opens .env, the file EPA reads its keys from (it's made the first time)
        set -eu

        if [ ! -f .env ]; then
          printf '%s\\n' \\
            "# Keys for EPA, one NAME=value per line (for example RESEND_API_KEY=re_...)." \\
            "# Check Connections (epa-check-connections on the Composer grid) says what each service needs." > .env
          echo "Made $(pwd)/.env"
        fi
        chmod 600 .env
        if command -v open >/dev/null 2>&1; then open -t .env; else "${EDITOR:-vi}" .env; fi
        echo "Opened $(pwd)/.env. EPA reads it on every run: a key saved there is used on the next one."
        """ + "\n"),
    ]

    /// Installs EPA, or updates it: Node.js, the kit (in ~/.local/share/epa), and the `epa` command
    /// (in ~/.local/bin). The installer runs the same file (scripts/setup-epa.sh, kept equal by a test).
    public static let setupEPA = """
    #!/bin/bash
    # Installs EPA (or updates it): Node.js, the kit, and its epa command. Safe to run again.
    set -euo pipefail

    REPO="ainigh/ENTER-PRICE-AUTOMATION"
    KIT="${EPA_HOME:-$HOME/.local/share/epa}"
    BIN="$HOME/.local/bin"

    # 1. Node.js 22 or newer (EPA is plain JavaScript, with no other dependencies).
    major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
    if ! command -v node >/dev/null 2>&1 || [ "$(major)" -lt 22 ]; then
      if command -v brew >/dev/null 2>&1; then
        echo "→ Installing Node.js with Homebrew (EPA needs version 22 or newer)…"
        brew install node || brew upgrade node
        hash -r
        # An older node earlier on PATH (nvm, a system one) still wins over Homebrew's.
        if [ "$(major)" -lt 22 ]; then
          echo "❌ The node on your PATH is still $(node --version) ($(command -v node)); EPA needs 22 or newer." >&2
          echo "Next: put $(brew --prefix)/bin before it in your PATH (or nvm install 22), then run this again." >&2
          exit 1
        fi
      else
        echo "❌ EPA needs Node.js 22 or newer, and there's no Homebrew here to install it with." >&2
        echo "Next: install Node.js (the LTS) from https://nodejs.org, then run this again." >&2
        exit 1
      fi
    fi
    echo "✅ Node.js $(node --version)"

    # 2. The kit: updated when it's here, fetched when it isn't (with gh when it's signed in).
    if [ -d "$KIT/.git" ]; then
      echo "→ Updating EPA in ${KIT}…"
      if ! git -C "$KIT" pull --ff-only --quiet; then
        echo "⚠️ Couldn't update $KIT (it has changes of its own), so the EPA there is kept as it is." >&2
        echo "   To start it fresh: move that folder to the Trash, then run this again." >&2
      fi
    else
      echo "→ Fetching EPA into ${KIT}…"
      mkdir -p "$(dirname "$KIT")"
      if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh repo clone "$REPO" "$KIT" -- --quiet
      elif ! git clone --quiet "https://github.com/$REPO.git" "$KIT"; then
        echo "❌ Couldn't fetch $REPO (it's private: GitHub needs to know it's you)." >&2
        echo "Next: brew install gh && gh auth login --web, then run this again." >&2
        exit 1
      fi
    fi
    echo "✅ EPA kit in $KIT ($(git -C "$KIT" log -1 --format='%h, %cr'))"

    # 3. Its packages (they're all its own: nothing is downloaded from npm).
    (cd "$KIT" && npm install --no-audit --no-fund --silent)

    # 4. The epa command, where the app (and your terminal) finds it.
    mkdir -p "$BIN"
    ln -sf "$KIT/packages/cli/bin/epa.js" "$BIN/epa"
    chmod +x "$KIT/packages/cli/bin/epa.js"
    echo "✅ $("$BIN/epa" --version), as $BIN/epa"
    case ":$PATH:" in *":$BIN:"*) ;; *) echo "   (Add $BIN to your PATH to type epa in a terminal: the app finds it either way.)";; esac
    echo "Next: run epa-check-connections on the Composer grid. It says what to connect first."
    """ + "\n"

    /// Earlier versions of the recipes this app wrote, by file name. A file that is still exactly
    /// one of them (nobody changed it) is brought up to date by `updateEPARecipes`.
    public static let earlierEPARecipes: [String: [String]] = [
        // 1st: "$KIT…" — macOS's bash 3.2 read the first byte of "…" as part of the name
        // (`KIT\xE2: unbound variable` under set -u). Fixed with ${KIT}.
        EPA.setupScript: [setupEPA.replacingOccurrences(of: "${KIT}…", with: "$KIT…")],
    ]

    public static let epaFlows: [(String, String)] = [
        ("epa-check-connections.flow", """
        // Checks every service EPA can reach (read-only) and says the one next step
        let connections = attemptEpa ["doctor"]

        if connections.ok then
            notify "EPA: every connected service answered"
        else
            notify "EPA needs something: the run's output says what to do next"
        """ + "\n"),
        ("epa-connect-service.flow", """
        // Connects a service to EPA and proves it works (safe to run again)
        let service = choose "Which service?" ["cloudflare"; "cloudflare-email"; "resend"; "sendgrid"; "ses"; "mailup"; "microsoft"; "google"; "freshdesk"]
        let connect = epa ["connect"; service]
        notify $"EPA: {service} is connected"
        """ + "\n"),
        ("epa-sending-domain.flow", """
        // Sets up a domain to send email from: the service, its DNS on Cloudflare, verification, a test email
        let service = choose "Send through which service?" ["resend"; "sendgrid"; "ses"; "mailup"; "cloudflare-email"]
        let domain = ask "Which domain will the email come from? (such as acme.com)"
        let testTo = ask "Where should the test email go? (your address)"
        let connect = epa ["connect"; service; "--domain"; domain; "--test-to"; testTo]
        notify $"EPA: {domain} sends through {service}"
        """ + "\n"),
        ("epa-secure-site.flow", """
        // Puts email sign-in in front of a site on Cloudflare (EPA shows its plan and asks first)
        let site = ask "Which site? (its hostname, such as members.acme.com)"
        let testTo = ask "Your email address, for a test sign-in code"
        let secure = epa ["secure"; site; "--test-to"; testTo]
        notify $"EPA: {site} now asks visitors to sign in"
        """ + "\n"),
        ("epa-gmail-on-your-domain.flow", """
        // Your own address (you@yourdomain.com) in a free Gmail, through Cloudflare
        let address = ask "The address on your domain (such as you@acme.com)"
        let gmail = ask "Your Gmail address"
        let setup = epa ["gmail"; address; "--gmail"; gmail]
        notify $"EPA: {address} works from {gmail}"
        """ + "\n"),
        ("epa-person.flow", """
        // Everything every connected service knows about one address (read-only)
        let email = ask "Whose address? (such as jane@acme.com)"
        let person = epa ["person"; email]
        notify "EPA: what each service knows is in the run's output"
        """ + "\n"),
        ("epa-onboard.flow", """
        // A joiner, everywhere at once: the Microsoft 365 account, licence, groups and manager (EPA asks first)
        let email = ask "The new person's work address (such as jane@acme.com)"
        let fullName = ask "Their full name"
        let onboard = epa ["onboard"; email; "--name"; fullName]
        notify $"EPA: {fullName} is set up. Their temporary password is in the run's output"
        """ + "\n"),
        ("epa-offboard.flow", """
        // A leaver, everywhere at once: sign-in blocked, out-of-office on, work handed over (EPA asks first)
        let email = ask "Who is leaving? (their address)"
        let handTo = ask "Who takes over their mail and tickets? (an address)"
        let offboard = epa ["offboard"; email; "--hand-to"; handTo]
        notify $"EPA: {email} is offboarded"
        """ + "\n"),
        ("epa-phishing-sweep.flow", """
        // Clears one phishing email from every mailbox: counts it first, then asks before the Trash
        let search = ask "A Gmail search that finds it (such as from:@phish.example newer_than:2d)"
        let sweep = epa ["sweep"; search; "--mailbox"; "all"]
        notify "EPA: the sweep is done: the run's output has each mailbox"
        """ + "\n"),
        ("epa-atlas.flow", """
        // Opens the EPA Atlas in your browser: every provider's reads and actions (Stop closes it)
        epa ["atlas"; "--open"] |> ignore
        """ + "\n"),
    ]
}

extension Library {
    /// Puts the EPA recipes in the folder, leaving any already there as they are. Returns the ones added.
    @discardableResult
    public func addEPARecipes() throws -> [URL] {
        updateEPARecipes()
        return try add(scripts: Examples.epaScripts, flows: Examples.epaFlows)
    }

    /// Brings each EPA recipe that is exactly an earlier version this app wrote up to date (one
    /// someone changed, or that isn't there, is left alone). Returns the ones updated.
    @discardableResult
    public func updateEPARecipes() -> [URL] {
        var updated: [URL] = []
        for (name, contents) in Examples.epaScripts + Examples.epaFlows {
            guard let earlier = Examples.earlierEPARecipes[name] else { continue }
            let url = name.hasSuffix("." + Self.flowExtension) ? composerFolder.appendingPathComponent(name) : root.appendingPathComponent(name)
            guard let now = try? String(contentsOf: url, encoding: .utf8), earlier.contains(now) else { continue }
            if (try? contents.write(to: url, atomically: true, encoding: .utf8)) != nil { updated.append(url) }
        }
        return updated
    }

    /// Whether the folder has any of the EPA recipes (some may have been put in the Trash on purpose).
    public var hasAnyEPARecipe: Bool {
        let fm = FileManager.default
        return Examples.epaScripts.contains { fm.fileExists(atPath: root.appendingPathComponent($0.0).path) }
            || Examples.epaFlows.contains { fm.fileExists(atPath: composerFolder.appendingPathComponent($0.0).path) }
    }

    /// Whether the folder has the EPA recipes (all of them).
    public var hasEPARecipes: Bool {
        let fm = FileManager.default
        return Examples.epaScripts.allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0.0).path) }
            && Examples.epaFlows.allSatisfy { fm.fileExists(atPath: composerFolder.appendingPathComponent($0.0).path) }
    }
}
