# AGENTS.md — CodecBlue

Guidance for AI coding agents (and humans) working on this repository. Read this file in
full before changing anything; [CONTRIBUTING.md](CONTRIBUTING.md) has the legal rules.

## What this project is

CodecBlue streams Mac audio to Bluetooth headphones with LDAC, aptX/aptX HD, AAC 320 and
SBC XQ on Apple Silicon Macs. Bluetooth stays with macOS: CodecBlue only takes over the
headphones' audio channels through `bluetoothd`'s classic XPC service, and hands the
headphones back to macOS during calls.

The repository directory may still be called `ldac_mac`; the project is CodecBlue.

## Repository map (current and planned)

| Path | What lives there |
|---|---|
| `Package.swift` | SwiftPM package; must build with the Command Line Tools alone |
| `Sources/CodecBlueCore/` | Engine (Swift): XPC channel broker, AVDTP/AVRCP, codec wrappers, session state machine, call hand-off |
| `Sources/codecblue/` | CLI: `version`, later `probe` (codecs a headset declares) and `codectest` |
| `Sources/CodecBlue/` (planned) | Menu bar app (SwiftUI) |
| `Driver/` (planned) | Virtual audio output device, AudioServerPlugIn in **C** (runs inside coreaudiod) |
| `third_party/libldac/` | AOSP libldac submodule, unmodified (Apache-2.0) |
| `Sources/codecblue-selftest/` | Unit tests, run as an executable (see below) |

## Releasing

A tag is the whole instruction:

```sh
git tag -a v1.2.0 -m "what changed"
git push origin v1.2.0
```

`.github/workflows/release.yml` then runs `make lint` and `make test`, packages with
`scripts/package.sh`, and publishes a `.zip` with the binaries already inside. `make release` does
the same packaging locally, so a release can be inspected before it is announced.

The version is not a constant. `scripts/version.sh` reads `git describe` and writes
`Sources/CodecBlueCore/GeneratedVersion.swift` before the build, then restores it, so the binary
knows its own release on a machine with no git and `git status` stays clean. The committed value of
that file is `0.0.0-development`, which is what a checkout is — if a build says that, the script
did not run, not that the tag is missing.

A release is signed, notarised and stapled when the credentials are there, and says so out loud
when they are not. Four secrets, all optional:

| secret | what it is |
|---|---|
| `CODECBLUE_SIGN_IDENTITY` | `Developer ID Application: Name (TEAMID)` |
| `CODECBLUE_SIGN_P12` | the certificate and key, base64 of the `.p12` |
| `CODECBLUE_SIGN_P12_PASSWORD` | its password |
| `CODECBLUE_NOTARY_KEY_P8` | App Store Connect API key, the `.p8` file's contents |
| `CODECBLUE_NOTARY_KEY_ID` | its Key ID |
| `CODECBLUE_NOTARY_ISSUER` | the issuer UUID (only for Team keys) |

Without them the archive is ad-hoc signed. It runs, and the Accessibility permission survives
updates — `scripts/sign.sh` sets the designated requirement to the bundle identifier instead of the
default `cdhash`, which is what would otherwise forget the grant at every build. What ad-hoc cannot
do is earn Gatekeeper's trust: the user has to right-click and choose Open once, because there is no
authority chain behind the signature. Only a Developer ID and notarisation remove that dialog. Locally, `CODECBLUE_NOTARY_PROFILE` (from `xcrun notarytool store-credentials`) does the
same job as the three key variables.

Signed is not trusted. Signing proves who built the archive; notarisation is Apple having scanned
it, and the stapled ticket is what lets Gatekeeper accept it on a Mac that has never seen it. All
three or the user gets a dialog that says the app may be malicious.

## Build and test

```sh
git submodule update --init
make check                                       # format + lint + build + tests (what CI runs)
make format                                      # rewrite the sources with swift-format
make test                                        # build + unit tests only
.build/debug/codecblue version
.build/debug/codecblue lookup AA:BB:CC:DD:EE:FF  # read-only: what bluetoothd knows
.build/debug/codecblue probe  AA:BB:CC:DD:EE:FF  # takes the headphones briefly (ask first)
```

Unit tests are plain functions in `Sources/codecblue-selftest/` (`test("name") { check(...) }`).
XCTest is missing from the Command Line Tools and Swift Testing needs Xcode's macro plugins,
so neither can be used. CI (`.github/workflows/ci.yml`) runs `make lint` and `make test`, which
are the same commands you run by hand: a green CI and a green laptop must mean the same thing.

Formatting is `xcrun swift-format` with the committed `.swift-format` — the tool that comes with
the toolchain, not one to install. `make format` writes, `make lint` reports, and they are the
same program with the same configuration, so they cannot disagree. `make lint` also fails on any
compiler warning: not `-warnings-as-errors`, which would break a build the day Apple adds a
deprecation, but a count that has to be zero.

`.swift-format` must be readable by every swift-format from 5.9 to 6.4, because `xcrun` resolves
to whatever the machine has: an Xcode 16 runner and a Command Line Tools laptop do not run the
same version. Only keys that all of them know, and none whose type has changed between versions.
The one that caught this is `reflowMultilineStringLiterals`, a string in 6.4 and an object in
6.1 — a single wrong type rejects the *whole file*, one error per source file, and the check
reports nothing at all rather than reporting wrongly. Before adding a key, check it exists in
the oldest version that has to pass, and prefer leaving a default alone over restating it.

A test must not depend on the machine it runs on. Everything that reads the system — the
installed copy of the app, a real audio device, paired headphones, a loaded driver — either
takes its answer as an argument or is skipped with a reason. The first CI run failed on a test
that discovered `~/Applications/CodecBlue` and asserted it had won: correct on a laptop with
the app installed, wrong on a runner without it.

## Hard rules

1. **English only** in everything committed: code, comments, docs, commit messages.
2. **Swift everywhere,** except C where Swift does not fit: codec libraries, and the audio
   driver that runs in coreaudiod's real-time threads. Real-time audio paths must not
   allocate or take locks.
3. **License hygiene.** The project is MIT. No GPL/AGPL or non-commercial code. LGPL only as
   an optional, dynamically loaded component. Record every third-party component in
   `THIRD_PARTY_NOTICES.md`; code derived from Blue Bloom keeps its MIT notice in the
   file header.
4. **Never break the user's Bluetooth.** On every failure path (error, timeout, crash,
   bluetoothd restart, unknown macOS build) the headphones must end up with macOS. Never
   leave a request without a timeout.
5. **No synchronous XPC on the main thread.** All bluetoothd communication is async and
   handles `XPC_TYPE_ERROR` (connection interrupted or invalid).
6. **Do not run hardware tests on the user's behalf** without asking. Taking the
   headphones away interrupts what the user is listening to.
7. **Do not use Swift macros** (`@Observable`, `#Preview`...). Their plugins ship only with
   Xcode, and the build must also work with the Command Line Tools alone. Use
   `ObservableObject`/`@Published` instead.

## Technical facts

- **Channel broker.** The XPC service is `com.apple.server.bluetooth.classic.xpc`.
  - Check-in: message 1, then 10, then 12.
  - Device lookup: message 44.
  - Connect / cancel: 45 / 46.
  - Open and close an L2CAP channel: 29 and 30; the open reply is event 27, which carries a
    socket fd.
  - RFCOMM: open 59, close 60; event 62 answers the open, event 63 reports a close.
  - These numbers were recorded on macOS 26/27 (Blue Bloom). Treat them as versioned
    data, not constants scattered in the code.
- **Sockets are SOCK_STREAM.** L2CAP message boundaries are not preserved. AVDTP signaling
  must be framed from its headers, and partial writes must be resumed, never resent.
- **Taking headphones over.** Force-disconnect macOS's link. bluetoothd keeps it about 2 s;
  open our AVDTP signaling channel inside that window, then AVRCP before the media
  channel. Holding AVRCP (and HFP while streaming) stops macOS from reconnecting.
- **Calls.** When a call app starts using the microphone, release the headphones so macOS
  connects HFP. Take them back after the call ends, with hysteresis of at least 5 s.
- **LDAC.**
  - Vendor `0x0000012D`, codec `0x00AA`, RTP payload type 96.
  - One LDAC header byte carries the frame count in its low 4 bits.
  - 128 samples per channel per encode call. Minimum MTU 679.
  - Quality levels: HQ 990, SQ 660 and MQ 330 kbps at 48/96 kHz; 909, 606 and 303 kbps at
    44.1/88.2 kHz.
- **Audio clock.** The virtual device runs on the host clock, the headphones on their own.
  Compensate drift with an adaptive resampler; never drop or insert audio in large chunks.

## Code style

- Swift 6, strict concurrency, macOS 14.2 deployment target. Use actors for the session
  state; keep state machines explicit (`enum` states, no flag soup).
- Comments explain *why* (protocol constraints, observed device behaviour with date and
  device), not what the code does.
- Pull requests should do one thing each. Put the motivation and the hardware tested on in
  the description.
