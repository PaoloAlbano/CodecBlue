#!/bin/bash
# Builds CodecBlueMenu.app, the menu bar app.
#
# A bare executable is not enough: without a bundle, macOS shows it in the Dock, gives it a
# generic icon, and — the part that matters — cannot be told it is a background app. `LSUIElement`
# in Info.plist is what makes it live in the menu bar only.
#
# The bundle is assembled here rather than by Xcode because the rest of the project is SwiftPM and
# adding an Xcode project would mean two build systems that can disagree.

set -euo pipefail
cd "$(dirname "$0")/.."

APP=".build/CodecBlueMenu.app"
BINARY=".build/debug/CodecBlueMenu"

# The bundle may be owned by root, left behind by a `sudo ./scripts/install.sh` that built
# everything as root. `rm -rf` then fails with "Permission denied" and the script dies halfway,
# which reads as a broken build. Build somewhere writable instead of fighting over ownership —
# the same rule `build-driver.sh` already follows.
if [ -d "$APP" ] && [ ! -w "$APP" ]; then
    APP=".build/menu-app-$(id -u).app"
    echo "note: .build/CodecBlueMenu.app is not writable (left over from a sudo build); using $APP"
fi

echo "building…"
swift build --product CodecBlueMenu 2>&1 | grep -E "error:|warning: " || true

if [ ! -x "$BINARY" ]; then
    echo "error: $BINARY was not built" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/CodecBlueMenu"

# The helper has to sit next to the binary: `MediaKeyHelper.locate()` looks beside its own
# executable, and inside a bundle that is Contents/MacOS.
if [ -x ".build/debug/codecblue-keys" ]; then
    cp ".build/debug/codecblue-keys" "$APP/Contents/MacOS/codecblue-keys"
fi

# The icon, if it has been generated (scripts/make-icon.py). Without it the app shows the generic
# application icon in Finder and in System Settings, which for a program that lives in the menu
# bar is the only place it is ever seen as an "app" at all.
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>CodecBlue</string>
    <key>CFBundleDisplayName</key>
    <string>CodecBlue</string>
    <key>CFBundleIdentifier</key>
    <string>com.codecblue.menu</string>
    <key>CFBundleExecutable</key>
    <string>CodecBlueMenu</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- No Dock icon and no app menu: this lives in the menu bar. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>CodecBlue</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Without any signature macOS refuses to run a bundle whose executable changed
# after it was created, and the Accessibility permission is remembered per signature — an ad-hoc
# one is stable as long as the binary does not change, which is enough for a local build.
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: could not sign the bundle"

echo "built $APP"
echo "run it with: open $APP"
