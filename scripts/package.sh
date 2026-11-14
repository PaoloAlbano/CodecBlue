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
# One product per invocation, and this is not fussiness: `swift build --product A --product B`
# builds **only B**. Measured 2026-11-14 — three products were asked for, only `CodecBlueMenu`
# appeared, and the release died with ".build/release/codecblue was not built" while the same
# command on a laptop appeared to work because `codecblue` was left over from a build eight days
# earlier. That is the worst shape a bug can have: green locally, and the first tag anyone pushes
# is the one that finds it. The loop below cannot have that failure mode, because each product is
# asked for by name and then checked for on its own.
for product in codecblue codecblue-keys CodecBlueMenu; do
    swift build -c release --product "$product" 2>&1 | grep -E "error:" && die "build failed: $product"
    [ -x ".build/release/$product" ] || die ".build/release/$product was not built"
done

say "building the driver…"
# The driver is C and has its own script; it builds into .build/driver and does not install
# without --install, which is what a release needs: the user installs it, not the packager.
sh scripts/build-driver.sh 2>&1 | grep -vE "^built |^warning: codesign" || true
DRIVER=$(ls -d .build/driver*/CodecBlueDriver.driver 2>/dev/null | head -1)
[ -n "$DRIVER" ] || die "the driver was not built"

say "building the menu bar app…"
# `CODECBLUE_SIGN_IDENTITY` is deliberately hidden from this build: the script signs the bundle
# ad-hoc for local use, and the real signature is applied below, once, in the right order. Passing
# the identity here made the script try to sign with a certificate this machine does not have, fail,
# and exit before printing where the bundle went — which read as "the app was not built".
MENU_OUT=$(env -u CODECBLUE_SIGN_IDENTITY sh scripts/build-menu-app.sh 2>&1) || true
MENU_APP=$(printf '%s\n' "$MENU_OUT" | sed -n 's/^built \(.*\)$/\1/p' | tail -1)
if [ -z "$MENU_APP" ] || [ ! -d "$MENU_APP" ]; then
    printf '%s\n' "$MENU_OUT" >&2
    die "the menu bar app was not built"
fi

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

echo "1/3 installing the programs into ${APP_DIR}…"
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

# --- sign -------------------------------------------------------------------------------------
#
# One script does the signing, because the ad-hoc path has a subtlety that is easy to lose:
# `scripts/sign.sh` explains it, and the short version is that an ad-hoc signature's default
# designated requirement is the hash of that exact binary, so the Accessibility permission the user
# granted is forgotten at the next build. With `--requirements '=designated => identifier "..."'`
# the requirement is the bundle identifier, which does not change, and the grant survives updates.
#
# The order matters and is not negotiable: sign inside-out (the helper inside the bundle before the
# bundle), because a nested signature that changes invalidates the one around it.
say "signing…"
sign() { sh scripts/sign.sh "$1" "${2:-}"; }
sign "$STAGE/CodecBlue.app/Contents/MacOS/codecblue-keys" com.codecblue.menu.keys
sign "$STAGE/CodecBlue.app"
sign "$STAGE/CodecBlueDriver.driver"
sign "$STAGE/codecblue" codecblue
sign "$STAGE/codecblue-keys" codecblue-keys

# `verify --deep --strict` is the check Apple's own tooling runs. It is here because a broken
# signature is worse than no signature: the user gets "damaged and can't be opened", which reads as
# a corrupt download and is unfixable from their side.
say "verifying the signatures…"
for item in "$STAGE/CodecBlue.app" "$STAGE/CodecBlueDriver.driver" \
            "$STAGE/codecblue" "$STAGE/codecblue-keys"; do
    codesign --verify --deep --strict "$item" || die "$item does not verify"
done

if [ -z "${CODECBLUE_SIGN_IDENTITY:-}" ]; then
    say ""
    say "note: CODECBLUE_SIGN_IDENTITY is not set, so this archive is ad-hoc signed."
    say "      It runs, and the Accessibility permission now survives updates (the signature"
    say "      names the bundle identifier, not the binary's hash). But macOS still refuses it"
    say "      on a Mac that has never run it until the user right-clicks and chooses Open,"
    say "      because an ad-hoc signature has no authority chain behind it."
fi

# --- zip --------------------------------------------------------------------------------------
#
# `ditto` and not `zip`: it preserves the extended attributes and the resource forks that a bundle
# needs, and a `.app` zipped with `zip` arrives broken in ways that look like a corrupt download.
say "zipping…"
ZIP="$DIST/CodecBlue-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"

# --- notarise ---------------------------------------------------------------------------------
#
# Notarisation is Apple scanning the archive and issuing a ticket, and the ticket is what makes
# Gatekeeper let it run on a Mac that has never seen it. Without it a signed archive still gets
# "Apple cannot check it for malicious software" on first launch — signed is not the same as
# trusted, which is the confusion this step exists to remove.
#
# Credentials come from the environment, never from this script: an App Store Connect key
# (`CODECBLUE_NOTARY_KEY`, `CODECBLUE_NOTARY_KEY_ID`, `CODECBLUE_NOTARY_ISSUER`) or a keychain
# profile (`CODECBLUE_NOTARY_PROFILE`, made once with `xcrun notarytool store-credentials`). No
# credential is ever written to the archive, the log, or the repository.
NOTARY_ARGS=""
if [ -n "${CODECBLUE_NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS="-p $CODECBLUE_NOTARY_PROFILE"
elif [ -n "${CODECBLUE_NOTARY_KEY:-}" ] && [ -n "${CODECBLUE_NOTARY_KEY_ID:-}" ]; then
    NOTARY_ARGS="-k $CODECBLUE_NOTARY_KEY -d $CODECBLUE_NOTARY_KEY_ID"
    [ -n "${CODECBLUE_NOTARY_ISSUER:-}" ] && NOTARY_ARGS="$NOTARY_ARGS -i $CODECBLUE_NOTARY_ISSUER"
fi

if [ -z "$NOTARY_ARGS" ]; then
    say ""
    say "note: no notarisation credentials, so this archive is not notarised."
    say "      Gatekeeper will refuse it on a Mac that has never run it, and the user will"
    say "      have to right-click, Open, and confirm. Set CODECBLUE_NOTARY_PROFILE (or the"
    say "      three CODECBLUE_NOTARY_KEY* variables) to have this step do it."
elif [ -z "${CODECBLUE_SIGN_IDENTITY:-}" ]; then
    say ""
    say "note: notarisation needs a real signature first; skipping it because"
    say "      CODECBLUE_SIGN_IDENTITY is not set. Apple rejects ad-hoc signed archives."
else
    say "notarising (this takes a minute or two)…"
    # `notarytool` returns non-zero for "invalid" as well as for transport errors, and the useful
    # part of the answer is in the log, not in the exit code. So the log is fetched either way.
    if xcrun notarytool submit "$ZIP" $NOTARY_ARGS --wait --output-format json > "$DIST/notary.json" 2>&1; then
        say "  accepted"
    else
        say "error: notarisation failed. The log follows." >&2
        submission=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$DIST/notary.json" | head -1)
        [ -n "$submission" ] && xcrun notarytool log "$submission" $NOTARY_ARGS >&2 || true
        cat "$DIST/notary.json" >&2
        die "notarisation failed"
    fi

    # Stapling attaches the ticket to the archive itself, so the first launch works offline. Without
    # it the ticket is fetched from Apple on first run, which fails on a plane and looks like the
    # same "cannot be checked" dialog notarisation was supposed to remove.
    say "stapling the ticket…"
    xcrun stapler staple "$ZIP" || die "stapling failed"
    xcrun stapler validate "$ZIP" || die "the stapled ticket does not validate"
    # A marker for whatever writes the release notes, so that the notes describe this archive and
    # not a condition re-derived from the same secrets somewhere else.
    touch "$DIST/notarised"
fi

# The checksum, last and not earlier: stapling rewrites the archive, so a checksum taken before it
# describes a file that no longer exists — and a checksum that fails on a good download is worse
# than no checksum at all, because the user concludes the download is corrupt.
( cd "$DIST" && shasum -a 256 "CodecBlue-$VERSION.zip" > "CodecBlue-$VERSION.zip.sha256" )
# The notary log can quote the submission id and the team, which belong in a bug report and not in
# a public release asset.
rm -f "$DIST/notary.json"

say ""
say "built $ZIP"
say "$(cat "$DIST/CodecBlue-$VERSION.zip.sha256")"
