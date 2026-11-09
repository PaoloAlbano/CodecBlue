# CodecBlue — the commands worth remembering.
#
# `make test` is the one that matters: it builds and runs the self-test, and it is what CI runs,
# so a green `make test` here and a green CI are the same statement. Everything else is a
# shortcut for a command that is written down in README.md anyway.
#
# The self-test is an executable, not XCTest: XCTest is missing from the Command Line Tools and
# Swift Testing needs Xcode's macro plugins, so the tests are plain functions that print a tick
# or a cross and exit non-zero on failure.

SHELL := /bin/sh

# Where things go. The same three places `scripts/install.sh` uses, and for the same reasons:
# the driver needs sudo, the programs do not, and the agent is written by the app.
APP_DIR := $(HOME)/Applications/CodecBlue

# The binaries the self-test and the smoke test use. `.build/debug` is the symlink SwiftPM keeps;
# `.build/out/Products/Debug` is the directory it points at and which `swift package clean` deletes.
BIN := .build/debug

# The C compiler for the driver's own rule test. The harness includes the driver source, which
# includes CoreAudio headers from the SDK, so the SDK has to be named explicitly: `clang` on its
# own resolves frameworks from /System/Library, where a plug-in header does not exist.
CC := clang -isysroot $(shell xcrun --show-sdk-path)

.PHONY: all build test selftest format lint check menu driver install uninstall release clean distclean help

all: build

help:
	@echo "make build      build everything (Swift package)"
	@echo "make test       build, then run the self-test (this is what CI runs)"
	@echo "make format     rewrite the Swift sources with swift-format"
	@echo "make lint       check formatting and compiler warnings without changing anything"
	@echo "make check      lint, then test — the whole gate, and what CI runs"
	@echo "make release    build the release archive (.build/dist/CodecBlue-<version>.zip)"
	@echo "make menu       assemble CodecBlue.app"
	@echo "make driver     build the virtual output device (no install)"
	@echo "make install    install driver + programs + menu app (asks for sudo once)"
	@echo "make uninstall  remove all three"
	@echo "make clean      swift package clean, keeping the submodule"

build:
	swift build

# The tests, and nothing else. Two properties matter and both are why this is a target rather
# than a line in a README:
#
#   1. it fails loudly — the self-test exits non-zero, and `make` stops on the first failure;
#   2. it does not need a machine with the app installed, headphones paired, or a driver loaded.
#      Everything that touches the system is either given its answer as an argument or skipped
#      with a reason. A test that depends on the machine is a test that fails in someone else's
#      checkout, which is exactly what happened on the first CI run.
test: build
	@echo "self-test:"
	@$(BIN)/codecblue-selftest
	@echo "driver rule:"
	@$(CC) -O1 -o $(BIN)/hide-rule Tests/Driver/hide-rule.c -framework CoreFoundation
	@$(BIN)/hide-rule
	@echo "smoke test:"
	@$(BIN)/codecblue version

# Kept as an alias because "make selftest" is what one types when looking for the tests.
selftest: test

# The formatter is the one Apple ships with the toolchain: `xcrun swift-format`. Not swiftlint,
# not SwiftFormat — this project is built with the Command Line Tools alone, and a tool that has
# to be installed separately is a tool half the contributors will not have. `xcrun` finds it in
# the active developer directory, which is where the compiler already comes from.
#
# `xcrun` and not a pinned version, but the *configuration* is written to be read by every version
# from 5.9 to 6.4: only keys that all of them know, and none whose type changed. That is not
# fussiness — the runner's `xcrun` resolves to a different swift-format than a laptop's, and the
# configuration file is the only thing the two share. Measured 2026-11-08, first CI run of this
# target: `reflowMultilineStringLiterals: "never"` is a string in 6.4 and an object in 6.1, so the
# whole file was rejected with "The data couldn't be read because it isn't in the correct format"
# — fourteen times, once per file, and no formatting check at all. A configuration that only the
# author's toolchain can read is a check that only the author passes.
SWIFT_FORMAT := xcrun swift-format
# Found on disk and not asked of git, so a file that is new and not yet `git add`ed is checked
# too. A formatter that skips the file you are working on is a formatter you stop running.
SWIFT_SOURCES := $(shell find Sources Driver scripts -name '*.swift' 2>/dev/null) Package.swift

# Rewrites the sources in place. Safe to run at any time: the configuration is committed
# (.swift-format), so the result is the same on every machine, and `make lint` is what says so.
format:
	@$(SWIFT_FORMAT) format --in-place --configuration .swift-format $(SWIFT_SOURCES)

# Two checks, and they answer two different questions.
#
# `swift-format lint` answers "is this formatted the way the project says?" — it is the same
# program as `make format`, run in the mode that reports instead of writing, so the two can never
# disagree. A line length or an indentation is a style question and this is where the project's
# answer to it lives.
#
# `--strict` is not decoration: without it `swift-format lint` prints the warnings and exits 0, so
# a target built on it reports "clean" over a file it has just complained about. Measured while
# writing this: a deliberately misformatted file printed two warnings and the target passed.
#
# The compiler answers the other question: "is there anything here that is probably a mistake?".
# `-warnings-as-errors` is not used, because a new SDK warning would then break a build that is
# fine; instead the warnings are collected and counted, and any warning fails the target. The
# difference matters: a warning that appears is a thing to look at, and a build that fails because
# Apple added a deprecation is a build nobody can fix on a Sunday.
lint:
	@echo "swift-format:"
	@$(SWIFT_FORMAT) lint --strict --configuration .swift-format $(SWIFT_SOURCES) \
	    && echo "  clean"
	@echo "compiler warnings:"
	@mkdir -p .build
# The compiler prints each warning twice — once on the line, once on the caret line under it — and
# in colour when it thinks it is talking to a terminal. Both are noise here: one line per warning,
# no escapes, path relative to the checkout.
	@swift build 2>&1 \
	    | sed 's/\x1b\[[0-9;]*m//g' \
	    | grep -E "^[^ ].*warning:" | grep -v "search path" \
	    | sed 's|^$(CURDIR)/||' > .build/warnings.txt || true
	@if [ -s .build/warnings.txt ]; then \
	    echo "  $$(wc -l < .build/warnings.txt | tr -d ' ') warning(s):"; \
	    cut -c1-160 .build/warnings.txt; \
	    exit 1; \
	else echo "  clean"; fi

# The gate: what CI runs, and what to run before pushing.
check: lint test

# The archive a tag produces, built here so that a release can be checked before it is published.
# Needs a tag: without one the version is 0.0.0-development and the archive says so, which is the
# honest answer but not something to hand to anyone.
release:
	@sh scripts/package.sh

menu:
	@sh scripts/build-menu-app.sh

driver:
	@sh scripts/build-driver.sh

install:
	@sh scripts/install.sh

uninstall:
	@sh scripts/install.sh --uninstall

# `swift package clean` removes .build but leaves the submodule alone; `distclean` is for the
# case where the checkout itself is suspect.
clean:
	swift package clean

distclean: clean
	rm -rf .build
