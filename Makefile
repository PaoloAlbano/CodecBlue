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

.PHONY: all build test selftest menu driver install uninstall clean distclean help

all: build

help:
	@echo "make build      build everything (Swift package)"
	@echo "make test       build, then run the self-test (this is what CI runs)"
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
	@echo "smoke test:"
	@$(BIN)/codecblue version

# Kept as an alias because "make selftest" is what one types when looking for the tests.
selftest: test

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
