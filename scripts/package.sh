#!/bin/sh
# Builds the release archive: one .zip that a person downloads, unzips, and installs with one
# command. Run by .github/workflows/release.yml when a tag is pushed, and runnable by hand to check
# that a tag would produce what you think it would.
#
#   scripts/package.sh            build and package the current tree
#   scripts/package.sh --check    do everything except build, and say what it would do
#
# What goes in, and why each piece:
#
#   CodecBlue-<version>.zip
#     install.sh              the same installer the checkout uses, so the two cannot drift
#     uninstall.sh            one command to undo it, because an installer without one is a trap
#     codecblue               the CLI (release build, universal)
#     codecblue-keys          the media key helper, beside it: `codecblue` looks next to itself
#     CodecBlue.app           the menu bar app, with the helper inside it
#     CodecBlueDriver.driver  the virtual output device, built but not installed
#     README.md, LICENSE      so the archive is self-explanatory
#     VERSION                 what this is, for a script or a person
#
# What does not go in: the sources, the tests, the submodule, the notes. A release archive is for
# people who want to listen to music, not for people who want to build.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

VERSION=$(sh scripts/version.sh)
DIST="$HERE/.build/dist"
STAGE="$DIST/CodecBlue-$VERSION"

# The version is compiled in, so the file has to be written before the build and put back after.
# A trap and not a line at the end: a build that fails halfway must not leave a tagged version
# number sitting in the working tree for the next commit to pick up.
GENERATED="$HERE/Sources/CodecBlueCore/GeneratedVersion.swift"
BACKUP="$HERE/.build/GeneratedVersion.swift.bak"
mkdir -p "$HERE/.build"
cp "$GENERATED" "$BACKUP"
restore_version() {
    [ -f "$BACKUP" ] && mv "$BACKUP" "$GENERATED"
}
trap restore_version EXIT INT TERM

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

say "version: $VERSION"

# A release built from a dirty tree is a release nobody can reproduce, and the version string
# cannot say so (see scripts/version.sh on why --dirty is not used). Refuse instead.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    say "note: the working tree is not clean"
    if [ "${1:-}" != "--check" ]; then
        die "refusing to package a modified tree: commit or stash first"
    fi
fi

# The tag has to match the version, or the archive is named one thing and claims another.
if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ "${GITHUB_REF_NAME:-}" != "v$VERSION" ]; then
    die "the tag is $GITHUB_REF_NAME but the version is $VERSION"
fi

if [ "${1:-}" = "--check" ]; then
    say "would build and stage into $STAGE"
    exit 0
fi

# --- build ------------------------------------------------------------------------------------
#
# Release, and only the three products that ship. `swift build -c release` on the whole package
# also builds the self-test, which fails on this toolchain in release mode (whole-module
# optimisation breaks the module emission it needs) — a target that is not shipped should not be
# able to break a release.
say "building (release)…"
sh scripts/version.sh --write >/dev/null
swift build -c release --product codecblue --product codecblue-keys --product CodecBlueMenu 2>&1 \
    | grep -E "error:" && die "build failed"
for product in codecblue codecblue-keys CodecBlueMenu; do
    [ -x ".build/release/$product" ] || die ".build/release/$product was not built"
done

say "building the driver…"
# The driver is C and has its own script; it builds into .build/driver and does not install
# without --install, which is what a release needs: the user installs it, not the packager.
sh scripts/build-driver.sh 2>&1 | grep -vE "^built |^warning: codesign" || true
DRIVER=$(ls -d .build/driver*/CodecBlueDriver.driver 2>/dev/null | head -1)
[ -n "$DRIVER" ] || die "the driver was not built"

say "building the menu bar app…"
MENU_APP=$(sh scripts/build-menu-app.sh 2>/dev/null | sed -n 's/^built \(.*\)$/\1/p' | tail -1)
[ -n "$MENU_APP" ] && [ -d "$MENU_APP" ] || die "the menu bar app was not built"

# --- stage ------------------------------------------------------------------------------------
say "staging…"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cp .build/release/codecblue "$STAGE/codecblue"
cp .build/release/codecblue-keys "$STAGE/codecblue-keys"
cp -R "$MENU_APP" "$STAGE/CodecBlue.app"
# The bundle's own copy of the helper is the one it finds; keep both in step, exactly as
# scripts/install.sh does.
cp .build/release/codecblue-keys "$STAGE/CodecBlue.app/Contents/MacOS/codecblue-keys"
cp -R "$DRIVER" "$STAGE/CodecBlueDriver.driver"

cp README.md LICENSE "$STAGE/"
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

# The installer is generated here and not copied from scripts/install.sh, because the two do
# genuinely different things: the checkout one builds and installs, this one only installs what is
# already in the archive. Sharing one script would mean a script with two modes and a branch for
# each, which is how an installer comes to do the wrong thing on the wrong machine.
cat > "$STAGE/install.sh" <<'INSTALL'
#!/bin/sh
# Installs CodecBlue from this archive. Asks for your password once, for the audio driver only.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
APP_DIR="$HOME/Applications/CodecBlue"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

if [ "$(id -u)" = "0" ]; then
    echo "error: do not run this with sudo." >&2
    echo "       It asks for sudo itself, for the driver only: running the whole installer as" >&2
    echo "       root would leave your copy of CodecBlue owned by root." >&2
    exit 1
fi

echo "1/3 installing the programs into $APP_DIR…"
mkdir -p "$APP_DIR"
cp "$HERE/codecblue" "$APP_DIR/codecblue"
cp "$HERE/codecblue-keys" "$APP_DIR/codecblue-keys"
rm -rf "$APP_DIR/CodecBlue.app"
cp -R "$HERE/CodecBlue.app" "$APP_DIR/CodecBlue.app"
chmod +x "$APP_DIR/codecblue" "$APP_DIR/codecblue-keys"

echo "2/3 removing the quarantine flag…"
# A downloaded archive is quarantined, and Gatekeeper refuses an unsigned bundle that carries it.
# This is the honest version of "right-click, open": the user asked for this program, and the
# alternative is a dialog that says the app is damaged.
xattr -dr com.apple.quarantine "$APP_DIR/CodecBlue.app" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP_DIR/codecblue" 2>/dev/null || true

echo "3/3 installing the audio driver (sudo)…"
sudo rm -rf "$HAL_DIR/CodecBlueDriver.driver" "$HAL_DIR/CodecBlueDriver.bundle"
sudo cp -R "$HERE/CodecBlueDriver.driver" "$HAL_DIR/"
sudo chown -R root:wheel "$HAL_DIR/CodecBlueDriver.driver"
sudo killall coreaudiod 2>/dev/null || true

echo
echo "Installed. To use it:"
echo "  open $APP_DIR/CodecBlue.app      (menu bar: pick your headphones, Start streaming)"
echo
echo "The command line works too:"
echo "  $APP_DIR/codecblue devices"
echo "  $APP_DIR/codecblue status"
INSTALL
chmod +x "$STAGE/install.sh"

cat > "$STAGE/uninstall.sh" <<'UNINSTALL'
#!/bin/sh
# Removes everything CodecBlue installed. Leaves your preferences alone.
set -eu
APP_DIR="$HOME/Applications/CodecBlue"
AGENT="$HOME/Library/LaunchAgents/com.codecblue.system.plist"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

echo "stopping the agent…"
launchctl unload "$AGENT" 2>/dev/null || true
rm -f "$AGENT"
echo "removing the programs…"
rm -rf "$APP_DIR"
echo "removing the driver (sudo)…"
sudo rm -rf "$HAL_DIR/CodecBlueDriver.driver" "$HAL_DIR/CodecBlueDriver.bundle"
sudo killall coreaudiod 2>/dev/null || true
echo "done. Your preferences are still in ~/Library/Preferences/com.codecblue.menu.plist"
UNINSTALL
chmod +x "$STAGE/uninstall.sh"

# --- sign and zip -----------------------------------------------------------------------------
#
# Signing is optional and its absence is announced, not hidden. An unsigned release works, but
# macOS will ask the user to confirm the first launch and the Accessibility permission is tied to
# the signature — so every update forgets it.
if [ -n "${CODECBLUE_SIGN_IDENTITY:-}" ]; then
    say "signing with $CODECBLUE_SIGN_IDENTITY…"
    for item in "$STAGE/CodecBlue.app" "$STAGE/CodecBlueDriver.driver" \
                "$STAGE/codecblue" "$STAGE/codecblue-keys"; do
        codesign --force --options runtime --timestamp --sign "$CODECBLUE_SIGN_IDENTITY" "$item" \
            || die "signing $item failed"
    done
else
    say "note: CODECBLUE_SIGN_IDENTITY is not set, so this archive is ad-hoc signed."
    say "      It runs, but macOS asks for confirmation on first launch and forgets the"
    say "      Accessibility permission on every update."
fi

say "zipping…"
ZIP="$DIST/CodecBlue-$VERSION.zip"
rm -f "$ZIP"
# `ditto` and not `zip`: it preserves the extended attributes and the resource forks that a bundle
# needs, and a `.app` zipped with `zip` arrives broken in ways that look like a corrupt download.
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"

# The checksum, because a download that can be verified is a download that can be reported on.
( cd "$DIST" && shasum -a 256 "CodecBlue-$VERSION.zip" > "CodecBlue-$VERSION.zip.sha256" )

say ""
say "built $ZIP"
say "$(cat "$DIST/CodecBlue-$VERSION.zip.sha256")"
