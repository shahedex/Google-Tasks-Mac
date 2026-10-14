#!/usr/bin/env bash
# Builds "Google Tasks.app" into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/GoogleTasks"

APP="build/Google Tasks.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GoogleTasks"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS will run it locally.
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "Google Tasks"' 2>/dev/null || true
    rm -rf "/Applications/Google Tasks.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Google Tasks.app"
fi
