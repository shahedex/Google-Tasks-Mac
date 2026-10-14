#!/usr/bin/env bash
# Builds "Google Tasks.app" into ./build.
#   ./build.sh             build for this Mac
#   ./build.sh --install   ...and copy it to /Applications
#   ./build.sh --release   universal (Apple silicon + Intel) build, zipped for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP="build/Google Tasks.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "$MODE" == "--release" ]]; then
    swift build -c release --arch arm64
    swift build -c release --arch x86_64
    lipo -create -output "$APP/Contents/MacOS/GoogleTasks" \
        .build/arm64-apple-macosx/release/GoogleTasks \
        .build/x86_64-apple-macosx/release/GoogleTasks
else
    swift build -c release
    cp "$(swift build -c release --show-bin-path)/GoogleTasks" "$APP/Contents/MacOS/GoogleTasks"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS will run it locally.
codesign --force --deep --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/GoogleTasks"))"

case "$MODE" in
    --install)
        osascript -e 'quit app "Google Tasks"' 2>/dev/null || true
        rm -rf "/Applications/Google Tasks.app"
        cp -R "$APP" /Applications/
        echo "Installed to /Applications/Google Tasks.app"
        ;;
    --release)
        ZIP="build/Google-Tasks-Mac-v$VERSION.zip"
        rm -f "$ZIP"
        ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
        shasum -a 256 "$ZIP"
        echo "Release archive: $ZIP"
        ;;
esac
