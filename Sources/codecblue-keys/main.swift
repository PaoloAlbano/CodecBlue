// CodecBlue media key helper.
//
// Why this is a separate program, and not part of `codecblue`.
//
// The headphones' play/pause/next buttons arrive as AVRCP PASS THROUGH on the control channel
// that `codecblue` holds. Acting on them means posting a media key event, and macOS only allows
// that for a process the user has granted Accessibility permission to.
//
// That permission is asked for by *name*, and the name is the terminal: if `codecblue` posts the
// event itself, macOS asks the user to grant Accessibility to Terminal (or iTerm, or whatever
// launched it). Granting a whole terminal the ability to synthesise keystrokes for every program
// run in it is far more than this feature needs, and it is the kind of permission people are
// right to refuse.
//
// So the privilege lives in the smallest program that can hold it. This binary does one thing:
// read a line naming a button, post that media key, exit or wait for the next line. It has no
// network, no files, no arguments that do anything else. The user grants Accessibility to
// `codecblue-keys` and to nothing else.
//
// Protocol on stdin, one command per line:
//   play | pause | toggle | next | previous | fast | rewind | status | quit
// Answers on stdout, one per line:
//   ok <command>      the event was posted
//   denied            Accessibility permission is missing; nothing was posted
//   unknown <line>    the line was not a command
//
// `codecblue` starts one of these when it starts a stream and keeps it for the session, so the
// permission dialog appears once and the presses after it are instant.

import AppKit
import ApplicationServices
import Foundation

/// The media keys, by the numbers the HID system uses.
///
/// These are not in any Swift header: they are the `NX_KEYTYPE_*` constants from IOKit's
/// `ev_keymap.h`, which is not exposed to Swift. Written out with their names so the numbers in
/// the code mean something.
enum MediaKey: Int32 {
    case playPause = 16  // NX_KEYTYPE_PLAY
    case next = 17  // NX_KEYTYPE_NEXT
    case previous = 18  // NX_KEYTYPE_PREVIOUS
    case fast = 19  // NX_KEYTYPE_FAST
    case rewind = 20  // NX_KEYTYPE_REWIND
}

/// Posts a media key as a down/up pair.
///
/// `subtype: 8` is `NX_SUBTYPE_AUX_CONTROL_BUTTONS`, and the key code travels in the high half of
/// `data1` with the down/up state in the low half. Posting only the down event leaves the key
/// stuck; posting only the up does nothing at all. Both, in that order, is what a real key press
/// looks like.
func post(_ key: MediaKey) {
    for isDown in [true, false] {
        let state: Int32 = isDown ? 0x0A00 : 0x0B00
        let data1 = Int((key.rawValue << 16) | state)
        let flags = NSEvent.ModifierFlags(rawValue: UInt(isDown ? 0x0A00 : 0x0B00))
        guard
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
        else { continue }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}

/// Whether this process may post events at all.
///
/// Without it `CGEvent.post` returns quietly and the key never happens: the same silence as not
/// implementing the feature, which is exactly the failure mode this whole area has been full of.
/// So it is checked and reported rather than assumed.
func isTrusted() -> Bool {
    AXIsProcessTrusted()
}

/// Asks macOS to show the Accessibility prompt, once, naming this binary.
func requestTrust() {
    // The key is a `CFString` global, which Swift 6 will not let us touch directly because it is
    // shared mutable state. Its value is the documented string "AXTrustedCheckOptionPrompt"; the
    // literal is used instead of the global, with a comment, rather than fighting the checker.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

/// Sends an explicit transport command through MediaRemote, the private framework macOS itself
/// uses for the Now Playing keys.
///
/// The HID key `NX_KEYTYPE_PLAY` is a *toggle*: it means "flip whatever is playing". So `play` and
/// `pause` both became the same key press, and a double-click on the headphones — which sends
/// PAUSE then PLAY — toggled twice. That works only if the player agrees with the headphones about
/// the current state. Measured 2026-11-07: the listener's double-click did nothing, because the
/// two toggles cancelled out against a player that was already in the state the first press asked
/// for.
///
/// MediaRemote has separate commands (`kMRPlay` = 0, `kMRPause` = 1), which is what makes an
/// explicit pause stay paused. It is a private framework, so it is loaded at run time and its
/// absence is not fatal: the HID toggle stays as the fallback.
enum MediaRemote {
    typealias SendCommand = @convention(c) (Int, CFTypeRef?) -> Void
    private static let send: SendCommand? = {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW),
            let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    static var isAvailable: Bool { send != nil }

    /// The command numbers, spelled out: they are not in any header Swift can see.
    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    @discardableResult
    static func send(_ command: Command) -> Bool {
        guard let send else { return false }
        send(command.rawValue, nil)
        return true
    }

    /// The pid of the app the system considers "now playing", or 0 when there is none.
    ///
    /// This is the difference between a key that is delivered and a key that goes nowhere. The
    /// media keys — HID ones included — are routed by mediaremoted to the registered Now Playing
    /// client, and with no client there is no destination: the key is posted, nothing complains,
    /// and nothing happens. Measured 2026-11-08 on this Mac: `nowPlayingPID=0` while a video
    /// played in a browser, and every command was accepted and dropped.
    static func nowPlayingPID() -> Int32 {
        typealias GetPID =
            @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
        guard
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                RTLD_NOW),
            let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID")
        else { return -1 }
        let get = unsafeBitCast(symbol, to: GetPID.self)
        var result: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        get(DispatchQueue.global()) { pid in
            result = pid
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        return result
    }
}

func handle(_ line: String) -> Bool {
    switch line {
    case "play":
        // Explicit, for the case where a caller really does mean "play": MediaRemote has no
        // toggle ambiguity. It only works when a Now Playing client is registered, so the HID
        // toggle is the fallback — and the headphones' own button uses `toggle` instead, because
        // one button means one thing.
        if !MediaRemote.send(.play) { post(.playPause) }
    case "pause":
        if !MediaRemote.send(.pause) { post(.playPause) }
    case "toggle":
        // Say so when the key has nowhere to go. A key posted with no Now Playing client is
        // indistinguishable, from the outside, from a key that was never posted — and that
        // ambiguity is what made this take three attempts.
        let pid = MediaRemote.nowPlayingPID()
        if pid == 0 {
            print("ok toggle but no now-playing client (pid 0): the key has no destination")
            post(.playPause)
            return true
        }
        // The HID key, deliberately, and not MediaRemote.
        //
        // `NX_KEYTYPE_PLAY` is exactly what a keyboard's play/pause key sends, and it is a
        // toggle: the system routes it to whatever is playing. MediaRemote's
        // `kMRTogglePlayPause` does the same thing but only when there is a *registered* Now
        // Playing client — measured 2026-11-08 on this Mac: `nowPlayingPID=0` with a video
        // playing in a browser, and every MediaRemote command was accepted and did nothing.
        // The HID key goes through the same path a real keypress does, so it cannot be
        // silently dropped for want of a client.
        post(.playPause)
    case "next":
        if !MediaRemote.send(.nextTrack) { post(.next) }
    case "previous":
        if !MediaRemote.send(.previousTrack) { post(.previous) }
    case "fast":
        post(.fast)
    case "rewind":
        post(.rewind)
    case "status":
        // Both facts, because either one missing breaks a different button: no Accessibility and
        // nothing is posted at all; no MediaRemote and play/pause degrade to a toggle.
        let trust = isTrusted() ? "trusted" : "not trusted"
        let remote = MediaRemote.isAvailable ? "mediaremote" : "hid only"
        print(isTrusted() ? "ok status \(trust), \(remote)" : "denied \(trust), \(remote)")
        return true
    case "quit":
        return false
    case "":
        return true
    default:
        print("unknown \(line)")
        return true
    }
    if !isTrusted() {
        // Ask once, then say so. A caller that keeps pressing gets `denied` and can decide.
        requestTrust()
        print("denied")
        return true
    }
    print("ok \(line)")
    return true
}

// `--status` and `--request` for use from a shell, before a stream is running.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--status") {
    print(isTrusted() ? "trusted" : "not trusted")
    exit(isTrusted() ? 0 : 1)
}
if arguments.contains("--request") {
    requestTrust()
    print("asked macOS for Accessibility permission for \(CommandLine.arguments[0])")
    exit(0)
}

setvbuf(stdout, nil, _IOLBF, 0)  // line buffered: the caller reads a line at a time
while let line = readLine(strippingNewline: true) {
    if !handle(line.trimmingCharacters(in: .whitespaces)) { break }
}
