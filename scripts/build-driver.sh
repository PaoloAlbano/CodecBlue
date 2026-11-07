#!/bin/sh
# Builds CodecBlueDriver.driver and installs it where CoreAudio looks for it.
#
# The driver is a CFPlugIn bundle: one C file, no Xcode project, no Swift. That is deliberate —
# the audio server calls into it on a real-time thread, so the less machinery between the two,
# the better.
#
# Usage:
#   scripts/build-driver.sh            build only
#   scripts/build-driver.sh --install  build and copy to /Library/Audio/Plug-Ins/HAL
#
# Installing needs sudo once. Uninstalling is `sudo rm -rf` of the same path plus a restart of
# coreaudiod, which the script can do for you with --uninstall.
set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="$HERE/Driver/CodecBlueDriver"
BUILD="$HERE/.build/driver"
# The extension matters: CoreAudio only scans *.driver in the HAL folder. A .bundle with the
# right contents is silently ignored, with no error anywhere — which is exactly how this was
# found the first time.
BUNDLE="$BUILD/CodecBlueDriver.driver"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"

# The previous bundle may be owned by root — `sudo ./scripts/build-driver.sh --install` runs the
# whole script as root, so the build directory itself ends up root-owned and the next build as a
# normal user cannot clean it. Build in a fresh directory instead of fighting over permissions.
if [ -d "$BUNDLE" ] && [ ! -w "$BUNDLE" ]; then
    BUILD="$BUILD-$(id -u)"
    BUNDLE="$BUILD/CodecBlueDriver.driver"
    echo "note: $HERE/.build/driver is not writable (left over from a sudo build); using $BUILD"
fi
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

clang -bundle \
    -fvisibility=hidden \
    -fno-common \
    -Wall -Wextra \
    -Wno-unused-parameter \
    -mmacosx-version-min=14.0 \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$BUNDLE/Contents/MacOS/CodecBlueDriver" \
    "$SRC/CodecBlueDriver.c"

cp "$SRC/Info.plist" "$BUNDLE/Contents/Info.plist"

# Ad-hoc signature: enough for the local machine. A Developer ID would be needed to ship it,
# and the audio server checks the signature of what it loads.
codesign --force --sign - "$BUNDLE" 2>/dev/null || echo "warning: codesign failed, the driver may not load"

echo "built $BUNDLE"
plutil -lint "$BUNDLE/Contents/Info.plist"

case "${1:-}" in
    --install)
        # Remove both spellings: an earlier version installed the .bundle name.
        sudo rm -rf "$INSTALL_DIR/CodecBlueDriver.driver" "$INSTALL_DIR/CodecBlueDriver.bundle"
        sudo cp -R "$BUNDLE" "$INSTALL_DIR/"
        sudo chown -R root:wheel "$INSTALL_DIR/CodecBlueDriver.driver"
        echo "installed; restarting coreaudiod"
        sudo killall coreaudiod
        echo "done. 'CodecBlue' should now appear in System Settings > Sound."
        ;;
    --uninstall)
        sudo rm -rf "$INSTALL_DIR/CodecBlueDriver.driver" "$INSTALL_DIR/CodecBlueDriver.bundle"
        sudo killall coreaudiod
        echo "removed"
        ;;
esac
