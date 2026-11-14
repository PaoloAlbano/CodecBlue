#!/bin/sh
# Bumps the version, tags it, and pushes the tag — which is what starts a release.
#
#   scripts/bump.sh patch           0.1.0 -> 0.1.1
#   scripts/bump.sh minor           0.1.0 -> 0.2.0
#   scripts/bump.sh major           0.1.0 -> 1.0.0
#   scripts/bump.sh patch --dry-run say what it would do, change nothing
#   scripts/bump.sh patch --yes     do not ask for confirmation
#
# There is no file to edit and no commit to make. The version is not stored anywhere in the tree:
# `scripts/version.sh` derives it from the tag at build time and writes it into the binary, and the
# committed `GeneratedVersion.swift` says "0.0.0-development" on purpose. So a bump is exactly one
# act — create the tag — and the tag is the version. That is why this script tags and does not
# commit: a commit that only changed a number would be a commit that says nothing.
#
# The tag is what starts the release: `.github/workflows/release.yml` runs on `v*`, builds, runs
# the same gate as a normal push, packages the archive and publishes it. Pushing the tag *is*
# publishing, which is why every check below refuses rather than warns.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

PART="${1:-}"
DRY_RUN=no
ASSUME_YES=no
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=yes ;;
        --yes | -y) ASSUME_YES=yes ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$PART" in
    major | minor | patch) ;;
    "")
        die "which part? scripts/bump.sh patch|minor|major [--dry-run] [--yes]"
        ;;
    *)
        die "unknown part '$PART': expected patch, minor or major"
        ;;
esac

# --- what the current version is ---------------------------------------------------------------
#
# From the tags, and only from the tags that look like versions. This repository also carries
# `backup-before-squash-2` and friends, which `git describe` would happily consider, and a
# `git describe` answer like `v0.1.0-3-gabc1234` is not a version to bump — it is three commits
# past one. So: the highest `vX.Y.Z` tag, or 0.0.0 if there is none.
latest=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
latest=${latest:-0.0.0}
major=$(printf '%s' "$latest" | cut -d. -f1)
minor=$(printf '%s' "$latest" | cut -d. -f2)
patch=$(printf '%s' "$latest" | cut -d. -f3)

case "$PART" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
esac
next="$major.$minor.$patch"
tag="v$next"

# --- the checks, and each one is a way a release goes wrong -------------------------------------

# A tag is a promise about a tree. A modified tree is a tree nobody else has.
if [ -n "$(git status --porcelain)" ]; then
    say "the working tree is not clean:"
    git status --short | sed 's/^/  /'
    die "commit or stash first: a tag on a modified tree is a release nobody can reproduce"
fi

# A release from a branch is a release of something else. The workflow checks this too, on the
# tag, but failing here costs a second instead of a CI run.
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || die "on '$branch', not main: a release is cut from main"

# And main has to be what the world has, or the tag points at commits nobody can fetch.
git fetch --quiet origin main 2>/dev/null || say "note: could not fetch origin, using the local view"
if git rev-parse --verify --quiet origin/main >/dev/null; then
    behind=$(git rev-list --count HEAD..origin/main)
    ahead=$(git rev-list --count origin/main..HEAD)
    [ "$behind" -eq 0 ] || die "main is $behind commit(s) behind origin/main: pull first"
    [ "$ahead" -eq 0 ] || die "main is $ahead commit(s) ahead of origin/main: push first"
fi

# The tag must not exist, locally or on the remote. `git tag` would refuse the first and silently
# accept the second, and then the push would be rejected after the tag had been created — leaving
# a local tag that looks like a release and is not.
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    die "$tag already exists locally"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    die "$tag already exists on origin"
fi

# A version that goes backwards is not a bump. This cannot happen with the arithmetic above, but
# the check is here because the arithmetic is the thing most likely to be edited later.
if [ "$(printf '%s\n%s\n' "$latest" "$next" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$next" ]; then
    die "$next is not greater than $latest"
fi

# --- say what will happen, then do it -----------------------------------------------------------

say ""
say "  current   v$latest"
say "  next      $tag   ($PART)"
say "  commit    $(git rev-parse --short HEAD)  $(git log -1 --pretty=%s)"
say ""
say "Pushing this tag builds, tests, packages and publishes a release."
say "There is no undo: a published release can be deleted, but the tag and the run stay."
say ""

if [ "$DRY_RUN" = yes ]; then
    say "dry run: nothing was tagged and nothing was pushed."
    exit 0
fi

if [ "$ASSUME_YES" != yes ]; then
    # No terminal means no answer, and a release cut by a script that never asked is worse than
    # one that refused. `[ -t 0 ]` is false in CI and in a pipe, which is exactly when this must
    # not proceed on its own.
    [ -t 0 ] || die "no terminal to confirm on: pass --yes if that is really what you want"
    printf 'Tag and push %s? [y/N] ' "$tag"
    read -r answer
    case "$answer" in
        y | Y | yes | YES) ;;
        *) say "nothing was tagged."; exit 1 ;;
    esac
fi

# Annotated, not lightweight: a lightweight tag is a bare pointer, and `git describe` and the
# release notes both want a tag object with a date and a message.
git tag -a "$tag" -m "CodecBlue $next"

# If the push fails the tag is removed, so that the local repository does not claim a release that
# does not exist. The next attempt then starts from a clean state instead of "already exists
# locally" about a tag nobody can see.
if ! git push origin "$tag"; then
    git tag -d "$tag" >/dev/null
    die "the push failed, so the local tag was removed; nothing was released"
fi

say ""
say "pushed $tag"
say "the release is being built: https://github.com/PaoloAlbano/CodecBlue/actions/workflows/release.yml"
say "watch it with:  gh run watch \$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')"
