#!/bin/sh
# Signs a bundle or a binary.
#
#   scripts/sign.sh <path> [identifier]
#
# Two modes, and the difference between them is the whole reason this file exists.
#
# WITH a Developer ID (`CODECBLUE_SIGN_IDENTITY`): sign properly, with the hardened runtime and a
# trusted timestamp. Notarisation can then staple a ticket, and Gatekeeper accepts the archive on a
# Mac that has never seen it. Nothing else to think about.
#
# WITHOUT one: sign ad-hoc, but with a *stable designated requirement*. This is the part that is
# easy to get wrong and expensive to get wrong, so it is worth writing down.
#
# An ad-hoc signature's default designated requirement is a list of `cdhash` values — the hash of
# that exact binary. macOS identifies a program to the accessibility and TCC databases by its
# designated requirement, so a cdhash-based requirement means the permission is granted to *that
# build and no other*. Build again, and the user's Accessibility grant is silently forgotten: the
# tick is still there in System Settings, next to a program that no longer exists, and the buttons
# do nothing. Measured on this project: every `make release` invalidated the grant.
#
# `--requirements '=designated => identifier "..."'` replaces that with the bundle identifier, which
# is the same in every build. The permission then survives updates, which is what a user expects
# when they tick a box once.
#
# What this does NOT do, and cannot: make the archive trusted. An ad-hoc signature has no authority
# chain, so Gatekeeper still refuses the download on another Mac until the user right-clicks and
# chooses Open, and `install.sh` has to clear the quarantine flag. Only an Apple Developer ID
# ($99/year) and notarisation remove that dialog. This script makes the free path as good as the
# free path can be, and no better.
set -eu

TARGET="${1:-}"
IDENTIFIER="${2:-}"
[ -n "$TARGET" ] || { echo "usage: scripts/sign.sh <path> [identifier]" >&2; exit 2; }

if [ -n "${CODECBLUE_SIGN_IDENTITY:-}" ]; then
    # Inside-out is the caller's job: a nested signature that changes invalidates the one around it.
    codesign --force --options runtime --timestamp --sign "$CODECBLUE_SIGN_IDENTITY" "$TARGET"
    exit 0
fi

# Ad-hoc. The identifier has to be passed in for a loose binary (a Mach-O has no Info.plist to read
# it from), and is read from the bundle when it is a bundle.
if [ -z "$IDENTIFIER" ] && [ -f "$TARGET/Contents/Info.plist" ]; then
    IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$TARGET/Contents/Info.plist" 2>/dev/null || true)
fi
if [ -z "$IDENTIFIER" ]; then
    echo "warning: no identifier for $TARGET, signing ad-hoc with a cdhash requirement" >&2
    echo "         (the Accessibility permission will be forgotten on the next build)" >&2
    codesign --force --sign - "$TARGET" 2>/dev/null || true
    exit 0
fi

codesign --force --sign - --identifier "$IDENTIFIER" \
    --requirements "=designated => identifier \"$IDENTIFIER\"" "$TARGET" 2>/dev/null || {
    echo "warning: could not sign $TARGET" >&2
    exit 0
}
