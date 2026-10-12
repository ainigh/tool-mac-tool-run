#!/bin/bash
# Builds build/ToolMacToolRun.app and build/ToolMacToolRun.zip (what a release carries). Needs a
# Mac with Xcode or its Command Line Tools; GitHub Actions runs it on every push, so nobody has to
# build anything by hand.
#
#   VERSION=0.1.7 scripts/build-app.sh
#
# UNIVERSAL=0 builds for this Mac's chip only (works with just the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
BRANCH="${BRANCH:-main}"
NAME=ToolMacToolRun
APP="build/$NAME.app"

command -v swift >/dev/null 2>&1 || {
  echo "error: building needs Swift. Install Apple's command line tools (xcode-select --install), then try again." >&2
  exit 3
}

if [[ "${UNIVERSAL:-1}" == 1 ]]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BINDIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/$NAME" "$APP/Contents/MacOS/$NAME"
# The flow command rides along, for the terminal (install.sh links it into ~/.local/bin).
cp "$BINDIR/flow" "$APP/Contents/MacOS/flow"
# The guide the app shows (one file: the same docs/FLOW-GUIDE.md as in the repository).
cp docs/FLOW-GUIDE.md "$APP/Contents/Resources/FLOW-GUIDE.md"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ainigh.toolmactoolrun</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>Tool Mac Tool Run</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>ToolMacToolRunCommit</key><string>$COMMIT</string>
  <key>ToolMacToolRunBranch</key><string>$BRANCH</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Your scripts may control other apps (AppleScript, osascript).</string>
  <key>NSDesktopFolderUsageDescription</key><string>Your scripts may read or write files on the Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Your scripts may read or write files in Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Your scripts may read or write files in Downloads.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: Apple silicon only runs signed code, and this needs no developer account.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/flow"
codesign --force --sign - --timestamp=none "$APP"
ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "built $APP ($VERSION, $BRANCH, $COMMIT)"
