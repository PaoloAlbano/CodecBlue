#!/bin/sh
# Measures how much of the engine the self-test actually executes.
#
#   scripts/coverage.sh              print the number, and the worst files
#   scripts/coverage.sh --json       print the shields.io endpoint document
#   scripts/coverage.sh --update     write .github/coverage.json (what CI does on main)
#
# Why this exists at all: the self-test counts checks (1500 of them), and a count of checks says
# nothing about how much code they touch. Most of this project's tests are of two kinds — pure
# functions called directly, and *source assertions* ("this file contains this rule"), which pass
# whether or not the rule ever runs. The second kind is cheap and catches the class of bug this
# project keeps producing (a rule written in one place and forgotten in another), but it inflates
# the check count without executing anything. So the number below is the honest one, and it is
# lower than the check count suggests.
#
# Only `Sources/CodecBlueCore` is counted. The CLI, the menu bar app and the driver are not
# exercised by the self-test by design — they are thin shells over the engine, and a test that
# needed a running stream would need headphones, a driver and a login item, which is the machine
# dependency the first CI run died on.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

MODE="${1:-}"
PROFILE_DIR="$HERE/.build/coverage"
PROFDATA="$PROFILE_DIR/merged.profdata"
BINARY=".build/debug/codecblue-selftest"
JSON="$HERE/.github/coverage.json"

# Progress goes to stderr, and that is not cosmetic: `--json` exists to be captured by a caller
# (`$(scripts/coverage.sh --json)`), and the first version printed "building with instrumentation…"
# on stdout as well, so the JSON that reached the commit message was the progress log followed by
# the document. Measured 2026-11-14, in a commit subject on the badges branch.
say() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v xcrun >/dev/null 2>&1 || die "xcrun not found: this needs the Xcode command line tools"

say "building with instrumentation…"
swift build --enable-code-coverage 2>&1 | grep -E "error:" && die "build failed"
[ -x "$BINARY" ] || die "$BINARY was not built"

rm -rf "$PROFILE_DIR"
mkdir -p "$PROFILE_DIR"

say "running the self-test…"
# The profile file is named per-process by `%p` so that a test which spawns the CLI does not
# overwrite the parent's counters.
LLVM_PROFILE_FILE="$PROFILE_DIR/run-%p.profraw" "$BINARY" >"$PROFILE_DIR/selftest.log" 2>&1 || {
    tail -20 "$PROFILE_DIR/selftest.log" >&2
    die "the self-test failed; coverage of a failing run says nothing"
}

# shellcheck disable=SC2086
xcrun llvm-profdata merge -sparse "$PROFILE_DIR"/run-*.profraw -o "$PROFDATA" \
    || die "could not merge the profile data"

REPORT="$PROFILE_DIR/report.txt"
xcrun llvm-cov report "$BINARY" -instr-profile="$PROFDATA" Sources/CodecBlueCore \
    >"$REPORT" 2>/dev/null || die "could not produce the report"

# The percentage is found from the header, not hard-coded, and the first attempt at this read the
# wrong column: the header says "Cover" three times — regions, lines, branches — and taking the
# last one returned the *branch* cover, which is "-" because nothing is instrumented for branches.
# The script then reported "could not read the total" over a report that was perfectly fine.
#
# Counting fields does not work either, and the reason is worth writing down: the *header* splits
# "Missed Regions" into two words and the *data rows* have one number there, so the header has
# seventeen fields and the TOTAL line thirteen. Any column index derived from the header is off by
# two.
#
# What is stable is the order of the percentages: regions, functions, lines, branches. So take the
# third field that ends in a percent sign. If llvm-cov ever changes that order this fails loudly
# rather than reporting the wrong number, which is the only property that matters here.
PERCENT=$(awk '
    /^TOTAL/ {
        n = 0
        for (i = 1; i <= NF; i++) if ($i ~ /%$/) { n++; if (n == 3) { sub(/%$/, "", $i); print $i; exit } }
    }
' "$REPORT")
[ -n "$PERCENT" ] || die "could not read the total from the report: $(tail -1 "$REPORT")"

# Rounded to one decimal, because two decimals of a number this coarse is false precision.
ROUNDED=$(printf '%.1f' "$PERCENT")
# Lines executed and missed, from the same TOTAL line: they are the two integers just before the
# third percentage.
LINES=$(awk '/^TOTAL/ { print $(NF - 5) }' "$REPORT")
MISSED=$(awk '/^TOTAL/ { print $(NF - 4) }' "$REPORT")

# Colour thresholds for shields.io. This project sits in the red and that is the honest colour: the
# engine talks to bluetoothd and CoreAudio, and neither is reachable from a test that must run on a
# machine with no headphones.
COLOR=$(awk -v p="$ROUNDED" 'BEGIN {
    if (p >= 80) print "brightgreen";
    else if (p >= 60) print "green";
    else if (p >= 40) print "yellow";
    else if (p >= 20) print "orange";
    else print "red"
}')

case "$MODE" in
    --json)
        printf '{"schemaVersion": 1, "label": "coverage", "message": "%s%%", "color": "%s"}\n' \
            "$ROUNDED" "$COLOR"
        ;;
    --update)
        mkdir -p "$(dirname "$JSON")"
        printf '{"schemaVersion": 1, "label": "coverage", "message": "%s%%", "color": "%s"}\n' \
            "$ROUNDED" "$COLOR" >"$JSON"
        say "wrote $JSON: $ROUNDED%"
        ;;
    "")
        say ""
        say "engine coverage: $ROUNDED%  ($((LINES - MISSED)) of $LINES lines executed)"
        say ""
        say "the ten files with the most unexecuted lines:"
        # Sorted by missed lines, so the list says where the work is rather than which file is
        # alphabetically first.
        awk 'NR > 2 && $1 != "TOTAL" && $2 ~ /^[0-9]+$/ && $(NF - 4) ~ /^[0-9]+$/ \
             { printf "%6d  %s\n", $(NF - 4), $1 }' "$REPORT" \
            | sort -rn | head -10 | sed 's/^/  /'
        say ""
        say "what is not counted: the CLI, the menu bar app and the driver — thin shells over the"
        say "engine, which a test that must run without headphones cannot exercise."
        ;;
    *)
        die "unknown option: $MODE (try --json or --update)"
        ;;
esac
