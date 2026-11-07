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
    case playPause = 16   // NX_KEYTYPE_PLAY
    case next = 17        // NX_KEYTYPE_NEXT
    case previous = 18    // NX_KEYTYPE_PREVIOUS
    case fast = 19        // NX_KEYTYPE_FAST
    case rewind = 20      // NX_KEYTYPE_REWIND
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
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { continue }
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

func handle(_ line: String) -> Bool {
    switch line {
    case "play":
        post(.playPause)
    case "pause":
        post(.playPause)
    case "toggle":
        post(.playPause)
    case "next":
        post(.next)
    case "previous":
        post(.previous)
    case "fast":
        post(.fast)
    case "rewind":
        post(.rewind)
    case "status":
        print(isTrusted() ? "ok status" : "denied")
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
