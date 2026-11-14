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
# Copy beside the target and rename over it, never `cp` onto the file itself.
#
# Measured 2026-11-14, and it cost an hour: after an install, every run of the installed
# `codecblue` died with `Killed: 9` — `version`, `devices`, `status`, `start`, all of them — while
# the identical bytes in `.build/debug/` and even a copy of them in `/tmp` ran fine. `codesign -v`
# said the signature was valid, and `amfid` logged nothing about the installed path.
#
# The cause is that `cp` onto an existing file writes through the same inode, and the kernel caches
# a vnode's code signature against that inode. The file then holds a new cdhash under an old cache
# entry, the mismatch is treated as tampering, and the process is killed before `main` runs. A
# rename gives the file a new inode, so there is nothing stale to disagree with.
#
# It also makes the install atomic: the old binary is either fully there or fully replaced, never
# half-written if the copy is interrupted.
install_file() {
    from=$1; to=$2
    tmp="$to.new.$$"
    cp "$from" "$tmp" || { echo "error: could not copy $from" >&2; exit 1; }
    mv -f "$tmp" "$to" || { rm -f "$tmp"; echo "error: could not replace $to" >&2; exit 1; }
}

install_file .build/debug/codecblue "$APP_DIR/codecblue"
install_file .build/debug/codecblue-keys "$APP_DIR/codecblue-keys"
rm -rf "$APP_DIR/CodecBlue.app"
cp -R "$MENU_APP" "$APP_DIR/CodecBlue.app"
# The bundle's own copy of the helper is the one it will find; keep both in step.
install_file .build/debug/codecblue-keys "$APP_DIR/CodecBlue.app/Contents/MacOS/codecblue-keys"
# Ad-hoc, with the identifier as the designated requirement: `scripts/sign.sh` explains why that
# matters — a cdhash requirement would forget the Accessibility permission at the next update.
sh "$HERE/scripts/sign.sh" "$APP_DIR/CodecBlue.app" com.codecblue.menu 2>/dev/null || true

# Check that what was installed is what was just built, before saying it is installed.
#
# Added 2026-11-10, after it happened twice in one afternoon: the menu installed at 12:11 had md5
# 3f9c175 while the one built at 12:23 had 0191c29, so every fix of that hour was invisible and the
# icon was restarted without anyone checking. The cause is that `build-menu-app.sh` may return an
# older bundle than the one just built, and nothing compared the two. A copy is not an install
# until it is the same bytes.
# The same check for every piece, not only the menu.
#
# Added 2026-11-11. The menu was covered on 2026-11-10 and the other two were not, which is the
# wrong way round: the driver is the one that needs sudo, so a copy that silently does not take is
# the one nobody notices until they hear it — and the CLI is what `codecblue status` runs, so a
# stale one reports yesterday's rules about a stream that is following today's.
#
# `check_copy <what> <built> <installed>`: both must exist and be the same bytes.
check_copy() {
    what=$1; from=$2; to=$3
    built=$(md5 -q "$from" 2>/dev/null)
    installed=$(md5 -q "$to" 2>/dev/null)
    if [ -z "$built" ] || [ "$built" != "$installed" ]; then
        echo "error: the installed $what is not the one just built" >&2
        echo "  built:     $from  ${built:-missing}" >&2
        echo "  installed: $to  ${installed:-missing}" >&2
        echo "  the copy did not take, or a build script returned a stale artifact" >&2
        return 1
    fi
    echo "   $what: md5 $installed (matches the build)"
}

check_copy "menu bar app" "$MENU_APP/Contents/MacOS/CodecBlueMenu" \
    "$APP_DIR/CodecBlue.app/Contents/MacOS/CodecBlueMenu" || exit 1
check_copy "command line" ".build/debug/codecblue" "$APP_DIR/codecblue" || exit 1
check_copy "media key helper" ".build/debug/codecblue-keys" "$APP_DIR/codecblue-keys" || exit 1
# The bundle's copy is the one the app finds, and it is a second copy of the same file: if the two
# disagree, the app and the CLI press media keys differently.
check_copy "media key helper in the bundle" ".build/debug/codecblue-keys" \
    "$APP_DIR/CodecBlue.app/Contents/MacOS/codecblue-keys" || exit 1
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
