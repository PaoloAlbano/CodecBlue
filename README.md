<p align="center">
  <img src="Resources/icon.png" width="128" alt="CodecBlue icon">
</p>

<h1 align="center">CodecBlue</h1>

<p align="center">
  <a href="https://github.com/PaoloAlbano/CodecBlue/actions/workflows/ci.yml"><img
    src="https://github.com/PaoloAlbano/CodecBlue/actions/workflows/ci.yml/badge.svg"
    alt="CI"></a>
  <a href="https://github.com/PaoloAlbano/CodecBlue/releases/latest"><img
    src="https://img.shields.io/github/v/release/PaoloAlbano/CodecBlue?label=release"
    alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14.2%2B-blue" alt="macOS 14.2 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-blue" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
</p>

<p align="center">
  <a href="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/PaoloAlbano/CodecBlue/badges/coverage.json"><img
    src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/PaoloAlbano/CodecBlue/badges/coverage.json"
    alt="Engine coverage"></a>
</p>

<!--
  The release badge was left out until 2026-11-14, when v0.2.0 became the first tag to produce an
  archive: the v0.1.0 tag of 2026-11-09 failed, because `swift build --product A --product B` builds
  only B and the archive was never assembled. A badge that says "no releases" on the front page of a
  project is worse than no badge, so it went back only once there was something to point at.
-->

**Hi-res Bluetooth audio for the Mac.** CodecBlue streams your Mac's audio to Bluetooth
headphones in **LDAC**, using the Mac's built-in Bluetooth. No dongle, no SIP changes, no
kernel extensions, no root daemon — and no proprietary app deciding which codec you get.

> **Status: LDAC works end to end, from the Mac's own output.** Pick the **CodecBlue** output
> device and every app plays through it in LDAC — no root, no kernel extension, no daemon.
> Measured on 2026-11-07 with Huawei FreeBuds 5 on a MacBook's built-in controller: 336 kbps
> of LDAC, 0% of audio dropped, 0 skips, cushion 40 ms, ~60 ms of latency added by this
> program, verified by ear.
>
> The level is not a switch between three names. libldac has **five** bitrates — 990, 660,
> 492, 396 and 330 kbps at 48 kHz — and Sony named only three of them. CodecBlue measures what
> the link carries and picks the highest rung that fits in 85% of it, because on a link that
> carries ~530 kbps, 660 throws away a third of the audio and 330 leaves half the bitrate on
> the table. `codecblue levels` shows the ladder and what fits here.
>
> Three findings did most of the work, and each is written up with its measurements in
> `notes/findings/2026-11-05-play-ldac-queue.md`:
>
> - the throughput ceiling was the controller's **A2DP link quality mode**, which `bluetoothd`
>   only enables when it believes it is streaming (§13.1);
> - the crackle was the virtual device declaring a **one-second clock period**, so the host
>   corrected clock drift once a second, in one audible step (§13.15);
> - the skips were the packet queue discarding the **front** of the cushion instead of the
>   back, so the stall that caused the overflow found nothing to play (§13.13).
>
> The ceiling of ~410 kbps on this machine is a controller limit: it never negotiates 3-slot
> packets (`Link Adaptive Packet type support = 0`) and macOS does not expose
> `HCISetACLPacketType`. LDAC HQ at 990 kbps is therefore not reachable here, and that is a
> property of the hardware, not of this program — which is why the level is chosen from the
> measured bitrate instead of from a preference. The number is measured, not estimated:
> `codecblue flood` offers the link raw ACL packets and 22,716 of them were refused in 15
> seconds, settling at 410 kbps. Audio gets a little less than that, because the cushion has
> to absorb the stalls: 303 kbps plays with the cushion empty, while 363 kbps plays only as
> long as the stalls stay rare (`notes/findings/2026-11-10-ceiling-window.md`).

## How it works

macOS only offers SBC and AAC to Bluetooth headphones. CodecBlue leaves Bluetooth to macOS
and takes over **only your headphones' audio channels**:

1. It asks `bluetoothd` (through its classic Bluetooth XPC service) for the headphones'
   A2DP signaling and media channels, and for their remote-control (AVRCP) channel.
2. It negotiates the codec itself (AVDTP) and streams audio encoded with **LDAC**. aptX, AAC
   and SBC are not implemented here and are not planned: a pair of headphones that offers no LDAC
   endpoint is handed straight back to macOS, which plays to it in AAC or SBC — you hear sound, and
   the menu says `· AAC via macOS` beside the pair. Writing a second encoder would be a second
   packetiser and a second set of bugs for a result the system already produces.
3. Audio comes from a **CodecBlue virtual output device**. It appears in the output list only
   while a stream is running, and starting the stream selects it for you: the device is hidden
   when nothing can feed it, because a device that accepts audio and throws it away is worse than
   one that is not there. When the stream stops, your previous output comes back.
4. **Calls work, by giving the headphones back.** CodecBlue holds the headphones' hands-free
   channel and refuses calls on it, so a call app cannot quietly open a SCO link and starve the
   stream. When a call application opens the microphone, CodecBlue hands the headphones to macOS
   — which is what makes the microphone work — and takes them back when the call ends. During the
   call you hear in AAC, not LDAC: 330 kbps of LDAC does not fit beside a call link, and every
   implementation makes the same trade. The microphone is the headphones' own, at call quality.
   `--no-call-monitor` turns the hand-off off, and `codecblue release ADDR` does it by hand.

   The microphone **cannot** live inside our own link, and that is measured rather than assumed:
   SCO is not reachable through the XPC protocol this program uses. `codecblue probe-sco ADDR`
   asks the question directly — a control L2CAP channel opens with MTU 895, while `openChannel`
   with any other `kCBMsgArgType` is rejected with result 3, i.e. the message is invalid rather
   than the headphones refusing. Reaching SCO means going under `bluetoothd` to the Skywalk
   channels with SIP on, which is weeks of work and two masters on one link. So a call is a
   hand-off, not a feature of the stream.

Keyboards, mice and every other Bluetooth device stay with macOS and keep working.

Requirements: Apple Silicon, macOS 14.2 or later. Built and tested on macOS 27 with the
Command Line Tools alone — no full Xcode.

> ⚠️ CodecBlue relies on **private macOS interfaces**. A macOS update can break it; when
> that happens, the headphones simply fall back to macOS.

## Building

Requirements: Xcode Command Line Tools (Swift 6). Full Xcode is not needed.

```sh
git clone --recurse-submodules https://github.com/PaoloAlbano/CodecBlue.git
cd CodecBlue
make check                         # format + lint + build + tests (what CI runs)
make coverage                      # how much of the engine those tests actually execute
make release                       # the same .zip a tag publishes, built locally
.build/debug/codecblue version
.build/debug/codecblue lookup AA:BB:CC:DD:EE:FF   # what bluetoothd knows about your headphones
.build/debug/codecblue probe  AA:BB:CC:DD:EE:FF   # list the codecs they support (takes them for a few seconds)
```

## Installing

One command installs everything:

```sh
./scripts/install.sh
```

It builds, then puts three pieces where they belong, and asks for `sudo` once:

| Where | What | Why there |
|---|---|---|
| `/Library/Audio/Plug-Ins/HAL/CodecBlueDriver.driver` | the virtual output device | the audio system owns that folder, and loads it on every boot |
| `~/Applications/CodecBlue/` | `codecblue`, `codecblue-keys`, `CodecBlue.app` | no `sudo`, and it survives `swift package clean` |
| `~/Library/LaunchAgents/com.codecblue.system.plist` | the agent that keeps audio flowing | written by the app when you pick a pair of headphones |

Installing only the driver is the mistake this script exists to prevent: the device appears,
every app plays into it, and nothing feeds it, so the result is silence with no error anywhere.

`./scripts/install.sh --uninstall` removes all three.

## Installing a release

Download the `.zip` from the [releases page](https://github.com/PaoloAlbano/CodecBlue/releases),
unzip it, and run `./install.sh` inside the folder. It asks for your password once, for the audio
driver, and nothing else. `./uninstall.sh` undoes it.

Building a release is one command:

```sh
make bump-patch     # 0.1.0 -> 0.1.1
make bump-minor     # 0.1.0 -> 0.2.0
make bump-major     # 0.1.0 -> 1.0.0
```

Each tags and pushes, which is what starts the release: there is no version file to edit and no
commit to make, because `scripts/version.sh` reads the version from the tag at build time and the
committed `GeneratedVersion.swift` says `0.0.0-development` on purpose. The tag *is* the version.

The script refuses rather than warns, because a tag is a promise about a tree: it wants a clean
tree, on `main`, level with `origin`, a tag that does not exist yet, and a version that goes up.
`make bump-patch DRY_RUN=1` says what it would do without doing it.

The workflow builds, runs the same gate as a normal push, packages the archive, and publishes it
with the commit subjects since the previous tag as the notes. **No Apple Developer account is
needed**: without a signing identity in the repository secrets the archive is ad-hoc signed, the
release notes say so, and the user right-clicks the app once. With one, it is signed, notarised
and stapled — the same workflow, and nothing else changes.

The archive has the binaries already built — the CLI, the media key helper, the menu bar app and
the driver — so nothing has to be compiled and no toolchain is needed.

**On first launch macOS will refuse it.** CodecBlue is not notarised — that needs an Apple Developer
ID, which this project does not have. Right-click the app, choose **Open**, and confirm once; after
that it launches normally. This is expected, not a corrupt download.

The archive is ad-hoc signed with a *stable* designated requirement, so the Accessibility permission
the headphones' buttons need is remembered across updates. Without that, every update would silently
forget it.

If the release notes say "signed and notarised by Apple", none of the above applies: that build was
made with a Developer ID and opens like any other app.

```sh
shasum -a 256 -c CodecBlue-<version>.zip.sha256
```

## Latency

The delay this program adds is two numbers, and they are two different things:

| | Default | What it is |
|---|---|---|
| **cushion** | 60 ms, learned | audio encoded and waiting for the link. It widens itself when the link stalls, because a cushion that cannot grow is a cushion that clicks |
| **ring** | 100 ms | audio the driver has written and the encoder has not read yet. It is a jitter buffer for the writer, not for the link |

Both are adjustable, and both are worth adjusting by ear rather than by argument:

```sh
codecblue cushion 40                        # while it plays
codecblue system ADDR --ring-ms 60          # at start
```

The ring's 100 ms was forced by a real fault — short reads that repeated the last sample, heard
as crackle, measured on 2026-11-10 as 462 windows out of 8 656 holding 2 980 ms of plateau. That
fault is fixed, so the number is now a trade rather than a requirement: lower it until it
crackles, then go back one step. `codecblue status` reports `latency_ms`, which is the sum, so the
comparison is not a guess.

## Using it

Open **CodecBlue** from `~/Applications/CodecBlue/` (or run `open ~/Applications/CodecBlue/CodecBlue.app`).
It lives in the menu bar: pick your headphones, press **Start streaming**, and every app now
plays through them in LDAC. Closing the window does not stop the music — the agent owns the
stream, and brings it back when the headphones do.

The icon is a remote control, not the stream: quitting it leaves the music playing, which is why
the menu spells out the difference between **Stop streaming** and **Quit the icon**. Turn on
**Start at login** so the icon is there after a reboot; without it nothing brings it back, and the
only symptom is an icon that is not there.

From the menu you can also change the LDAC level while it plays — the whole ladder, with the
rung this link would actually use ticked — and the device's sample rate.

From a terminal, the same things:

```sh
codecblue devices                # the headphones macOS knows, and whether they are on
codecblue status                 # what a running stream is doing
codecblue quality HQ             # the ceiling: as good as this link allows, up to HQ
codecblue quality 2              # or a rung with no name: 492 kbps
codecblue adapt on               # or let it choose the level itself
codecblue levels                 # the whole ladder, and what fits here
codecblue compare                # this link against the Mac's own AAC
codecblue rate 44100             # the device's rate; applies after `sudo killall coreaudiod`
```

Without the app, the stream can also be run by hand:

```sh
./codecblue system AA:BB:CC:DD:EE:FF --quality LQ
```

`Ctrl-C` stops cleanly and hands the headphones back to macOS.

| Command | What it does |
|---|---|
| `codecblue system ADDR` | Stream the Mac's output to the headphones (the real use) |
| `codecblue play ADDR FILE` | Stream a file, for testing without the driver |
| `codecblue flood ADDR SECS BYTES` | Measure the link's throughput |
| `codecblue tone FILE SECS [--sweep]` | Write a test signal: a constant sine, or a sweep |
| `codecblue devices` | The headphones macOS knows, and whether they are on |
| `codecblue status` | What a running stream is doing |
| `codecblue levels` | The whole ladder, and what fits on this link |
| `codecblue compare` | This link against the Mac's own AAC, in kbps |
| `codecblue quality HQ\|SQ\|LQ\|0-4` | The ceiling, while it plays. A level is a limit, not a resting place |
| `codecblue adapt on\|off` | Let it choose the level itself |
| `codecblue cushion 40` | The cushion in ms — half of the latency |
| `codecblue system ADDR --ring-ms 60` | The ring's depth — the other half |
| `codecblue rate 44100\|48000` | The device's sample rate (after a coreaudiod restart) |
| `codecblue abr` | What this libldac build accepts, measured rather than assumed |
| `codecblue agent install\|remove\|status` | The LaunchAgent |
| `codecblue handlers device\|general` | Which handler answers each known message |

Options for `system` and `play`: `--quality HQ|SQ|LQ|0-4` (the ceiling of the ladder),
`--queue-ms` (the cushion, and therefore the latency), `--adapt`, `--keep-link-quality`,
`--sndbuf-packets`, `--gain`.

**Test signals matter.** `codecblue tone` writes a constant sine, not a melody: a file whose
notes change has phase jumps at every change, and a phase jump is exactly what a codec makes
worse. Testing a link with such a file tests the file. This cost a day.

## Repository layout

| Path | Contents |
|---|---|
| `Package.swift` | Swift package (SwiftPM) |
| `Sources/CodecBlueCore/` | Engine: bluetoothd channel broker, AVDTP/AVRCP, codecs, session state machine |
| `Sources/codecblue/` | Command-line tool |
| `Sources/codecblue-keys/` | Media key helper — the only binary that needs Accessibility permission |
| `Sources/CodecBlueMenu/` | The menu bar app: a client of the control channel, no audio code |
| `Sources/codecblue-selftest/` | Unit tests (run with `make test`) |
| `Driver/CodecBlueDriver/` | The virtual output device (a C AudioServerPlugIn) |
| `scripts/build-driver.sh` | Builds the driver, and installs or removes it with `--install` / `--uninstall` |
| `scripts/build-menu-app.sh` | Assembles `CodecBlueMenu.app` (a bundle is needed for `LSUIElement`) |
| `scripts/install.sh` | Installs all three pieces, or removes them with `--uninstall` |
| `scripts/coverage.sh` | Measures how much of the engine the self-test executes (`make coverage`) |
| `scripts/bump.sh` | Tags the next version and pushes it (`make bump-patch`, `-minor`, `-major`) |
| `Makefile` | `make check` is the gate CI runs; `make format` rewrites the sources |
| `notes/findings/` | What was measured and what it proved, including the dead ends |
| `third_party/libldac/` | AOSP libldac (git submodule, unmodified) |

Only LDAC is implemented, and aptX, AAC and SBC are not planned here — see point 2 above: a pair
that offers no LDAC endpoint is handed back to macOS, which plays to it in AAC or SBC, and the menu
says `· AAC via macOS` beside it. Writing a second encoder would be a second packetiser and a second
set of bugs for a result the system already produces.

If the headphones show as connected in macOS and CodecBlue says they are not reachable, check
`bluetoothd` before the headphones: it can run for days and stop answering its check-in, and
`sudo killall bluetoothd` fixes it. The log distinguishes the two — `bluetoothd is not answering` is
a fact about the daemon, `the headphones are not reachable` is a fact about the device.

The menu bar app is a thin client: everything it shows comes from the list of headphones macOS
knows and from the control channel of a running stream, and everything it does is write the
LaunchAgent, load it, or send a line down that channel. There is no audio code in it and no
second copy of the rules — a second copy is a second thing to keep correct.

## Acknowledgements

CodecBlue builds on what [Blue Bloom](https://github.com/jonathanlu98/bluebloom) (MIT)
learned about bluetoothd's XPC interface and about taking headphones over from macOS.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). If you use an AI coding agent, point it at
[AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE). Third-party components are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

CodecBlue is an independent open-source project. LDAC is a trademark of Sony Corporation;
aptX is a trademark of Qualcomm Technologies, Inc.; Bluetooth is a registered trademark of
Bluetooth SIG, Inc. This project is not affiliated with or endorsed by them; the names are
used only to describe codec compatibility.
