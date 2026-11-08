#!/bin/sh
# Installs everything CodecBlue needs, in one command, and says what it did.
#
# There are three pieces and they have different lifetimes, which is why this script exists at all:
#
#   1. the driver, in /Library/Audio/Plug-Ins/HAL — needs sudo, loaded by coreaudiod, survives
#      reboots, and must be reinstalled every time it is rebuilt;
#   2. the programs, in ~/Applications/CodecBlue — no sudo, owned by you, and the LaunchAgent
#      points at them;
#   3. the LaunchAgent, in ~/Library/LaunchAgents — no sudo, written by the app when you pick a
#      pair of headphones.
#
# Doing only the first and expecting the rest to work is the mistake this script prevents: the
# driver publishes a device, but nothing feeds it, and every app plays into silence with no error
# anywhere. That has cost real time once already.
#
# Usage:
#   scripts/install.sh             install everything (asks for sudo once, for the driver)
#   scripts/install.sh --no-driver skip the driver (when it is already installed and unchanged)
#   scripts/install.sh --uninstall remove everything, including the agent
set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

APP_DIR="$HOME/Applications/CodecBlue"
AGENT="$HOME/Library/LaunchAgents/com.codecblue.system.plist"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

if [ "${1:-}" = "--uninstall" ]; then
    echo "stopping the agent…"
    launchctl unload "$AGENT" 2>/dev/null || true
    rm -f "$AGENT"
    echo "removing the programs…"
    rm -rf "$APP_DIR"
    echo "removing the driver (needs sudo)…"
    sudo rm -rf "$HAL_DIR/CodecBlueDriver.driver" "$HAL_DIR/CodecBlueDriver.bundle"
    sudo killall coreaudiod 2>/dev/null || true
    echo "done. Nothing of CodecBlue is left installed."
    echo "Your preferences are still in ~/Library/Preferences/com.codecblue.menu.plist"
    exit 0
fi

# Refuse to run as root.
#
# Measured 2026-11-08: `sudo ./scripts/install.sh` built the whole project as root, so every file
# in .build/out and in the app bundle came out owned by root — and then the next ordinary
# `swift build` failed with "Operation not permitted" on files it could not overwrite, which looks
# like a broken toolchain and is not. Only the driver needs privileges, and it asks for them
# itself, one step at a time.
if [ "$(id -u)" = "0" ]; then
    echo "error: do not run this with sudo." >&2
    echo "       It asks for sudo by itself, for the driver only. Running the whole script as" >&2
    echo "       root leaves every build product owned by root, and the next build cannot" >&2
    echo "       overwrite them." >&2
    exit 1
fi

echo "1/3 building…"
swift build 2>&1 | grep -E "error:" && exit 1
# The icon is generated, not committed as a binary blob: it is 30 lines of Python that describe
# the mark, and a PNG in git that nobody can edit is worse than a script that can be re-run.
if [ -f "scripts/make-icon.py" ] && [ ! -f "Resources/AppIcon.icns" ]; then
    python3 scripts/make-icon.py >/dev/null 2>&1 || echo "   (icon not generated: is pillow installed?)"
fi
# The script may build into a fallback path (see its own note about root-owned bundles), so ask
# it where the bundle ended up rather than assuming.
MENU_APP=$(sh scripts/build-menu-app.sh 2>/dev/null | sed -n 's/^built \(.*\)$/\1/p' | tail -1)
if [ -z "$MENU_APP" ] || [ ! -d "$MENU_APP" ]; then
    echo "error: could not build the menu bar app" >&2
    sh scripts/build-menu-app.sh >&2 || true
    exit 1
fi

echo "2/3 installing the programs into ${APP_DIR}…"
mkdir -p "$APP_DIR"
# The CLI and the media key helper go side by side: `codecblue` looks for `codecblue-keys` next
# to itself, and the LaunchAgent points at this copy rather than at a build directory that
# `swift package clean` would delete.
cp .build/debug/codecblue "$APP_DIR/codecblue"
cp .build/debug/codecblue-keys "$APP_DIR/codecblue-keys"
rm -rf "$APP_DIR/CodecBlue.app"
cp -R "$MENU_APP" "$APP_DIR/CodecBlue.app"
# The bundle's own copy of the helper is the one it will find; keep both in step.
cp .build/debug/codecblue-keys "$APP_DIR/CodecBlue.app/Contents/MacOS/codecblue-keys"
codesign --force --sign - "$APP_DIR/CodecBlue.app" 2>/dev/null || true
echo "   $APP_DIR/codecblue"
echo "   $APP_DIR/codecblue-keys"
echo "   $APP_DIR/CodecBlue.app"

if [ "${1:-}" = "--no-driver" ]; then
    echo "3/3 driver: skipped (--no-driver)"
else
    echo "3/3 installing the driver (sudo)…"
    # The driver script builds and installs in one go, then restarts coreaudiod itself.
    #
    # Note: the rate lives in the ring's header, and the ring is in /tmp, which macOS clears on
    # reboot. So after a reboot the driver comes back at 48 kHz regardless of what was chosen.
    # That is the honest behaviour of a file-backed preference with no daemon to hold it; a
    # persistent choice would need the driver to read a file of its own, which is a change worth
    # making only if the rate turns out to matter in daily use.
    sudo sh scripts/build-driver.sh --install
fi

echo
echo "Installed. To use it:"
echo "  open $APP_DIR/CodecBlue.app      (menu bar: pick your headphones, Start streaming)"
echo
echo "The command line works too:"
echo "  $APP_DIR/codecblue devices"
echo "  $APP_DIR/codecblue status"
echo
echo "If you rebuild the driver, run this again: the driver is loaded by coreaudiod and the old"
echo "copy keeps running until it is replaced."
