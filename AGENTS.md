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

## Build and test

```sh
git submodule update --init
swift build
swift run codecblue-selftest                     # unit tests
.build/debug/codecblue version
.build/debug/codecblue lookup AA:BB:CC:DD:EE:FF  # read-only: what bluetoothd knows
.build/debug/codecblue probe  AA:BB:CC:DD:EE:FF  # takes the headphones briefly (ask first)
```

Unit tests are plain functions in `Sources/codecblue-selftest/` (`test("name") { check(...) }`).
XCTest is missing from the Command Line Tools and Swift Testing needs Xcode's macro plugins,
so neither can be used. CI (`.github/workflows/ci.yml`) runs the build and the self-test;
both must pass.

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
