import AppKit
import CodecBlueCore
import SwiftUI

/// The menu bar app: pick the headphones, start LDAC, change the level while it plays.
///
/// It is a thin client on purpose. Everything it shows comes from one of two places — the list of
/// headphones macOS knows, and the control channel of a running stream — and everything it does is
/// one of three things: write a LaunchAgent, load it, or send a line down that channel. There is
/// no audio code here, and no second copy of the rules.
///
/// That matters for the same reason the control channel exists: a second copy of the logic is a
/// second thing to keep correct, and this project has already spent whole evenings on bugs that
/// existed in two places at once.
/// Routes Cmd-Q through `AppModel.quit()`, so the keyboard and the menu item do the same thing.
///
/// Without this, Cmd-Q terminates the app directly and skips the stop: the icon would disappear
/// while the stream kept the headphones. `applicationShouldTerminate` is the one hook AppKit
/// offers before the process goes away, and it is enough — the stop itself is synchronous about
/// the two things that matter (unload the agent, tell the stream to quit).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared?.quitWithoutTerminating()
        return .terminateNow
    }
}

@main
struct CodecBlueMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            // The icon says what is happening without needing to be clicked: a filled waveform
            // when audio is flowing, an outline when it is not.
            Image(systemName: model.isStreaming ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        content
            // The menu must not rebuild itself while it is open: see `menuIsOpen`.
            .onAppear { model.menuOpened() }
            .onDisappear { model.menuClosed() }
    }

    @ViewBuilder
    private var content: some View {
        // Status first: the first thing anyone opens this for is "is it working?".
        if model.isStreaming {
            Text(model.statusLine)
            Text(model.detailLine)
                .foregroundStyle(.secondary)
        } else {
            Text(model.headline)
            if let note = model.note {
                Text(note).foregroundStyle(.secondary)
            }
        }

        Divider()

        // The headphones. One entry per pair macOS knows, whether or not it is switched on, so a
        // pair that is off is visibly off rather than missing.
        if model.headphones.isEmpty {
            Text("No headphones paired")
        } else {
            ForEach(model.headphones) { device in
                Button {
                    model.choose(device)
                } label: {
                    let mark = device.address == model.selectedAddress ? "✓ " : "  "
                    let state = device.isConnected ? "" : " (off)"
                    // What will actually drive them, beside the name.
                    //
                    // Asked 2026-11-09: "it would be good to show it next to the name in the
                    // toolbar". The label is the honest answer to "will this work?": LDAC when
                    // CodecBlue can drive the pair, AAC when macOS will instead, and nothing at all
                    // before anyone has asked — because the question costs the link to answer, and
                    // a guess in that position is worse than a blank.
                    Text("\(mark)\(device.name)\(state)\(model.codecNote(for: device))")
                }
            }
        }

        Divider()

        // The ladder, not three names, and the rung this link can actually carry ticked.
        //
        // libldac has five EQMIDs (990 / 660 / 492 / 396 / 330 at 48 kHz) and Sony named only
        // three of them. The two in the middle are what make a rate that follows the link
        // possible: a link that carries ~530 kbps has to choose between 660 (a third of the audio
        // thrown away) and 330 (half the bitrate left on the table), and 492 is the answer.
        //
        // So the menu lists the ladder highest first, spells out the three named rungs, shows the
        // bitrate for the two that have no name, and ticks the one the stream would settle on
        // here. The tick on the *playing* rung is separate and comes from `model.quality`.
        //
        // Changing it does not interrupt the stream: libldac changes the frame size it produces
        // and every packet carries its own frame count.
        // "LDAC quality", not "Quality": there is one quality setting in this menu and it belongs
        // to one codec, and a bare "Quality" next to "Latency" and "Sample rate" reads as if it
        // governed all three.
        Menu("LDAC quality") {
            ForEach(
                QualityLevels.menuLevels(
                    capacityKbps: model.linkKbps,
                    sampleRate: model.streamRate,
                    // So the tick always has a row to land on: the settle rule can put the stream
                    // on a rung that is not one of the three offered, and a menu with no tick at
                    // all reads as "your selection did nothing".
                    playingRung: model.qualityRung), id: \.rung
            ) { level in
                Button {
                    model.setQuality("\(level.rung)")
                } label: {
                    // The tick follows what is *playing*, not what was asked for: the rung
                    // settles on its own when the link cannot carry the one chosen.
                    //
                    // And the number beside a level is the bitrate *it* is producing right now,
                    // which is not the same as the rung's nominal value: HQ on a link that carries
                    // 396 is playing 396, and the menu says so. Asked 2026-11-09: "when the stream
                    // starts the kbps would appear beside them" — beside the level that is
                    // playing, not beside all three.
                    let playing = model.qualityRung == level.rung && model.quality != "unknown"
                    Text(
                        (playing ? "✓ " : "  ")
                            + QualityLevels.menuLabel(
                                level, capacityKbps: model.linkKbps,
                                streaming: model.isStreaming,
                                playingKbps: playing ? model.playingKbps : nil,
                                cappedByCeiling: model.linkIsCeiling,
                                sampleRate: model.streamRate))
                }
            }
            Divider()
            Button {
                model.toggleAdapt()
            } label: {
                Text(model.adapt ? "✓ Let it choose" : "  Let it choose")
            }
            Text(
                model.adapt
                    ? "It settles on the best level this link carries"
                    : "A level is a ceiling: it drops if the link cannot carry it")
        }

        Menu("Latency") {
            // The cushion is the latency. These are the values worth trying, not a slider: below
            // about 30 ms the cushion stops covering a stall of the link, and above 150 there is
            // nothing left to gain.
            ForEach(
                [
                    (30, "30 ms — tightest"), (60, "60 ms — default"),
                    (100, "100 ms — safer"), (150, "150 ms — steadiest"),
                ], id: \.0
            ) { pair in
                Button {
                    model.setCushion(pair.0)
                } label: {
                    Text(model.cushionMilliseconds == pair.0 ? "✓ \(pair.1)" : "  \(pair.1)")
                }
            }
            Divider()
            Text("It grows by itself when the link stalls")
        }

        Menu("Sample rate") {
            ForEach([44100, 48000], id: \.self) { rate in
                Button {
                    model.setRate(rate)
                } label: {
                    Text(model.deviceRate == rate ? "✓ \(rate) Hz" : "  \(rate) Hz")
                }
            }
            Divider()
            // The one thing this menu can say that is both true and useful: the rate changes the
            // whole ladder, because LDAC's bitrates are per frame and the frame rate follows the
            // sample rate. Measured from libldac, not from a table: 990 / 660 / 492 / 396 / 330 at
            // 48 kHz, and 909 / 606 / 452 / 363 / 303 at 44.1 kHz.
            //
            // It used to say nothing, on the grounds that "44.1 kHz is the native rate of most
            // music" was false next to a tick on 48. The replacement is not a slogan: it is the
            // reason someone would pick 44.1, which is that the bottom rung drops from 330 to 303
            // — near AAC's 234, and the "just above AAC" that was asked for on 2026-11-09.
            Text("44.1 kHz moves the whole ladder down: 303 kbps at the bottom, not 330")
        }

        // The two labels say what happens to the audio, because the two items are one above the
        // other and their consequences are opposite. Measured 2026-11-09: "Quit" was pressed to
        // stop the music, the icon disappeared, and the stream kept running — the headphones were
        // still taken and a call could not use them. The comment in `quit()` explains why that is
        // the right behaviour; the label has to explain it too, or the comment is only for us.
        //
        // Reported again the same day, after the labels were changed: "I see a quit the icon that
        // keeps the streaming". The wording was accurate and still read as a complaint, because a
        // menu item that says what it does *not* do is asking the reader to work out what it is
        // for. So each item now says what it is for, and the one that only hides a remote control
        // is marked as such and moved below the divider, away from the audio controls.
        if model.isStreaming {
            Button("Stop streaming — hands the headphones back to macOS") { model.stop() }
        } else {
            Button("Start streaming — takes the headphones and plays in LDAC") { model.start() }
                .disabled(model.selectedAddress == nil)
        }

        Divider()

        // The icon is the only way to start a stream, and nothing brings it back after a reboot.
        // Measured 2026-11-09: the icon was gone and the audio device was still listed, which reads
        // as a contradiction until you know they are three separate things. This is the fix.
        Button {
            model.toggleLoginItem()
        } label: {
            Text(model.startsAtLogin ? "✓ Start at login" : "  Start at login")
        }

        Button("Show the log") { model.openLog() }

        Divider()

        // The standard Quit of a menu bar app, and it now means what it says.
        //
        // Asked three times on 2026-11-09, and the third time was the one that changed the code.
        // First: "I don't understand what 'Hide this icon' is for." Then, after the label was
        // rewritten: "I still see 'Quit CodecBlue — the music keeps playing', but what does it
        // mean?" Then: "can we make it so that when I quit it actually stops CodecBlue?"
        //
        // Each answer was a better sentence about a design that was wrong. The design said the
        // stream belongs to the LaunchAgent, so quitting a window cannot stop it — true, and
        // beside the point: this app is not a player whose music should survive the window
        // closing. It is holding the headphones away from macOS, and a process you can no longer
        // see should not be holding them on your behalf.
        //
        // So Quit stops the stream. What survives a crash still survives a crash — that is
        // launchd's KeepAlive and it is untouched — but a deliberate Quit is not a crash.
        // No suffix any more: quitting stops the stream, so there is nothing about the audio to
        // warn about. The label that used to live here said "the music keeps playing", then
        // "reopen the app to control the stream" — both were describing a design that no longer
        // exists. A label that needs a suffix is usually a behaviour that needs fixing.
        Button("Quit CodecBlue") { model.quit() }
    }
}
