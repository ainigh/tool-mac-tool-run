#!/bin/bash
# Installs (or updates: run it again) Tool Mac Tool Run into ~/Applications, then opens it.
#
#   gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool-run/contents/install.sh | bash
#
# The repository may be private, so everything comes through gh, signed in to GitHub (this sets
# gh up if it's missing). It takes the latest release GitHub built. If there isn't one (or
# TMR_FROM_SOURCE=1), it downloads the source of main (TMR_BRANCH=name for another branch) and
# builds it here with Apple's command line tools. Running it again is safe: it replaces the app
# and keeps your scripts, settings and run history.
set -euo pipefail

REPO="ainigh/tool-mac-tool-run"
BRANCH="${TMR_BRANCH:-main}"
APPS="$HOME/Applications"
NAME="ToolMacToolRun"

say() { printf '\n\033[1m👉 %s\033[0m\n' "$*"; }
ok() { printf '✅ %s\n' "$*"; }
die() { printf '\n\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

say "Installing Tool Mac Tool Run: the latest build into $APPS, then open it (your scripts and settings stay as they are)"

# gh, signed in ------------------------------------------------------------------------------
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do if [[ -x "$b" ]]; then eval "$("$b" shellenv)"; fi; done
if ! command -v gh >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "Needs Homebrew first: https://brew.sh — install it, then run this again."
  say "Installing gh (GitHub's command line tool)"
  brew install gh
fi
if ! gh api "repos/$REPO" --silent >/dev/null 2>&1; then
  say "Sign in to GitHub with an account that can see $REPO (a browser window opens)"
  gh auth login --web --git-protocol https -h github.com </dev/tty
  gh api "repos/$REPO" --silent >/dev/null 2>&1 || die "That account can't open $REPO. Sign in with one that can (gh auth login), then run this again."
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# the app: GitHub's build, else built here -----------------------------------------------------
app=""
if [[ "${TMR_FROM_SOURCE:-0}" != 1 && "$BRANCH" == main ]]; then
  say "Downloading the latest release"
  if gh release download --repo "$REPO" --pattern "$NAME.zip" --dir "$tmp" 2>/dev/null; then
    ditto -x -k "$tmp/$NAME.zip" "$tmp/unpacked"
    app="$tmp/unpacked/$NAME.app"
  else
    echo "   No release yet: building it here instead (a minute or two)."
  fi
fi

if [[ -z "$app" ]]; then
  xcode-select -p >/dev/null 2>&1 || die "Building needs Apple's command line tools: run  xcode-select --install  then run this again."
  sha="$(gh api "repos/$REPO/commits/$BRANCH" --jq .sha)" || die "Couldn't find the branch $BRANCH."
  say "Downloading the source ($BRANCH, ${sha:0:7})"
  mkdir -p "$tmp/src"
  gh api "repos/$REPO/tarball/$sha" > "$tmp/src.tar.gz"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components 1
  say "Building (a minute or two)"
  (cd "$tmp/src" && VERSION="0.1-${sha:0:7}" COMMIT="$sha" BRANCH="$BRANCH" UNIVERSAL=0 scripts/build-app.sh)
  app="$tmp/src/build/$NAME.app"
fi

# install and open -----------------------------------------------------------------------------
# The app that was here is kept until the new one is seen running: if the new one quits straight
# away, the old one goes back and opens again, so an install never leaves you without it.
say "Installing into $APPS"
[[ -d "$app" ]] || die "The download didn't hold $NAME.app. Run this again; if it happens twice, try TMR_FROM_SOURCE=1."
if pkill -x "$NAME" 2>/dev/null; then echo "   Closed the running copy (it reopens in a moment)."; sleep 1; fi
mkdir -p "$APPS"
previous="$APPS/.$NAME-previous.app"
rm -rf "$previous"
replaced=0
if [[ -d "$APPS/$NAME.app" ]]; then mv "$APPS/$NAME.app" "$previous"; replaced=1; fi
ditto "$app" "$APPS/$NAME.app"
xattr -dr com.apple.quarantine "$APPS/$NAME.app" 2>/dev/null || true
version="$(defaults read "$APPS/$NAME.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
if [[ "$replaced" == 1 ]]; then ok "Replaced the app that was there with $version"; else ok "Installed $version"; fi

# The flow command, for the terminal.
mkdir -p "$HOME/.local/bin"
ln -sf "$APPS/$NAME.app/Contents/MacOS/flow" "$HOME/.local/bin/flow"
ok "The flow command is at ~/.local/bin/flow"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "   (To type just 'flow', add ~/.local/bin to your PATH: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc)";; esac

open "$APPS/$NAME.app"

# Still running a few seconds on: it started.
started=0
for _ in 1 2 3 4 5 6; do
  sleep 1
  if pgrep -x "$NAME" >/dev/null; then started=1; else started=0; fi
done
if [[ "$started" == 1 ]]; then
  rm -rf "$previous"
  say "Done ($version). Look for the terminal icon in the menu bar: click it, then Scripts Grid."
  echo "   Not there? The menu bar may be full (behind the camera notch): quit an icon or two, or hold ⌘ and drag some away."
  echo "   To update later, run the same command again."
  exit 0
fi

crash="$(ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i "$NAME" | head -1 || true)"
if [[ -d "$previous" ]]; then
  rm -rf "$APPS/$NAME.app"
  mv "$previous" "$APPS/$NAME.app"
  open "$APPS/$NAME.app"
  printf '\n\033[31m❌ %s\033[0m\n' "$NAME $version quit as soon as it opened, so the one you had is back and open again." >&2
else
  printf '\n\033[31m❌ %s\033[0m\n' "$NAME $version quit as soon as it opened." >&2
fi
[[ -n "$crash" ]] && echo "   What went wrong is in ~/Library/Logs/DiagnosticReports/$crash" >&2
echo "   To see it happen: $APPS/$NAME.app/Contents/MacOS/$NAME" >&2
exit 1
