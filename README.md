# CodecBlue

**Hi-res Bluetooth audio for the Mac.** CodecBlue streams your Mac's audio to Bluetooth
headphones in **LDAC**, using the Mac's built-in Bluetooth. No dongle, no SIP changes, no
kernel extensions, no root daemon — and no proprietary app deciding which codec you get.

> **Status: LDAC works end to end, from the Mac's own output.** Pick the **CodecBlue** output
> device and every app plays through it in LDAC — no root, no kernel extension, no daemon.
> Measured on 2026-11-07 with Huawei FreeBuds 5 on a MacBook's built-in controller: 336 kbps
> of LDAC MQ, 0% of audio dropped, 0 skips, cushion 40 ms, ~60 ms of latency added by this
> program, verified by ear.
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
> The ceiling of ~500 kbps on this machine is a controller limit: it never negotiates 3-slot
> packets (`Link Adaptive Packet type support = 0`) and macOS does not expose
> `HCISetACLPacketType`. LDAC HQ at 990 kbps is therefore not reachable here, and that is a
> property of the hardware, not of this program.

## How it works

macOS only offers SBC and AAC to Bluetooth headphones. CodecBlue leaves Bluetooth to macOS
and takes over **only your headphones' audio channels**:

1. It asks `bluetoothd` (through its classic Bluetooth XPC service) for the headphones'
   A2DP signaling and media channels, and for their remote-control (AVRCP) channel.
2. It negotiates the codec itself (AVDTP) and streams audio encoded with LDAC, aptX, AAC or
   SBC XQ.
3. Audio comes from a **CodecBlue virtual output device**: pick it like any other output.
4. **Calls work.** When a call app uses the microphone, CodecBlue hands the headphones back
   to macOS, so the call uses the headphones' microphone as usual. When the call ends,
   CodecBlue takes the headphones back.

Keyboards, mice and every other Bluetooth device stay with macOS and keep working.

Requirements (planned): Apple Silicon, macOS 14.2 or later; tested on macOS 27.

> ⚠️ CodecBlue relies on **private macOS interfaces**. A macOS update can break it; when
> that happens, the headphones simply fall back to macOS.

## Building

Requirements: Xcode Command Line Tools (Swift 6). Full Xcode is not needed.

```sh
git clone --recurse-submodules <repo-url>
cd codecblue
swift build
swift run codecblue-selftest      # unit tests
.build/debug/codecblue version
.build/debug/codecblue lookup AA:BB:CC:DD:EE:FF   # what bluetoothd knows about your headphones
.build/debug/codecblue probe  AA:BB:CC:DD:EE:FF   # list the codecs they support (takes them for a few seconds)
```

## Using it

The virtual output device needs to be installed once, with `sudo` (it lives in
`/Library/Audio/Plug-Ins/HAL`, which the audio system owns):

```sh
sudo ./scripts/build-driver.sh --install
sudo killall coreaudiod          # makes macOS pick the new plug-in up
```

Then, with the headphones connected:

```sh
./codecblue system AA:BB:CC:DD:EE:FF --quality MQ
```

and select **CodecBlue** as the output device. Every app now plays through it in LDAC. `Ctrl-C`
stops cleanly and hands the headphones back to macOS.

To have it start at login instead of from a terminal:

```sh
./codecblue agent install AA:BB:CC:DD:EE:FF --quality MQ
launchctl load ~/Library/LaunchAgents/com.codecblue.system.plist
./codecblue agent status         # is the device actually being fed?
```

`agent status` answers the question that matters — whether something is writing into the
device — not merely whether a process exists. A device that is selected but not fed plays
silence, and says so in the log rather than leaving you to guess.

| Command | What it does |
|---|---|
| `codecblue system ADDR` | Stream the Mac's output to the headphones (the real use) |
| `codecblue play ADDR FILE` | Stream a file, for testing without the driver |
| `codecblue flood ADDR SECS BYTES` | Measure the link's throughput |
| `codecblue tone FILE SECS [--sweep]` | Write a test signal: a constant sine, or a sweep |
| `codecblue agent install\|remove\|status` | The LaunchAgent |
| `codecblue handlers device\|general` | Which handler answers each known message |

Options for `system` and `play`: `--quality HQ|SQ|MQ` (start of the adaptive ladder),
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
| `Sources/codecblue-selftest/` | Unit tests (run with `swift run codecblue-selftest`) |
| `Driver/CodecBlueDriver/` | The virtual output device (a C AudioServerPlugIn) |
| `scripts/build-driver.sh` | Builds it, and installs or removes it with `--install` / `--uninstall` |
| `notes/findings/` | What was measured and what it proved, including the dead ends |
| `third_party/libldac/` | AOSP libldac (git submodule, unmodified) |

Only LDAC is implemented. aptX, AAC and SBC are named in the introduction as the goal, not as
a claim: headphones that do not offer LDAC cannot be driven by this yet, and the error says so
explicitly rather than looking like a configuration problem.

The menu bar app is not written; see [AGENTS.md](AGENTS.md) for the planned structure.

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
