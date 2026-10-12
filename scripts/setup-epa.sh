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
  else
    echo "❌ EPA needs Node.js 22 or newer, and there's no Homebrew here to install it with." >&2
    echo "Next: install Node.js (the LTS) from https://nodejs.org, then run this again." >&2
    exit 1
  fi
fi
echo "✅ Node.js $(node --version)"

# 2. The kit: updated when it's here, fetched when it isn't (with gh when it's signed in).
if [ -d "$KIT/.git" ]; then
  echo "→ Updating EPA in $KIT…"
  if ! git -C "$KIT" pull --ff-only --quiet; then
    echo "⚠️ Couldn't update $KIT (it has changes of its own), so the EPA there is kept as it is." >&2
    echo "   To start it fresh: move that folder to the Trash, then run this again." >&2
  fi
else
  echo "→ Fetching EPA into $KIT…"
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
