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
@main
struct CodecBlueMenuApp: App {
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
                    Text("\(mark)\(device.name)\(state)")
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
        Menu("Quality") {
            ForEach(
                QualityLevels.describe(
                    capacityKbps: model.linkKbps,
                    sampleRate: model.streamRate), id: \.rung
            ) { level in
                Button {
                    model.setQuality("\(level.rung)")
                } label: {
                    // The tick follows what is *playing*, not what was asked for: the rung
                    // settles on its own when the link cannot carry the one chosen.
                    let playing = model.qualityRung == level.rung && model.quality != "unknown"
                    Text(
                        (playing ? "✓ " : "  ")
                            + QualityLevels.menuLabel(level, capacityKbps: model.linkKbps))
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
            // No explanatory line here on purpose. It used to read "44.1 kHz is the native rate
            // of most music", which is true in general and false in this menu: the device is
            // configured at 48 kHz, and a sentence about 44.1 next to a tick on 48 is a
            // contradiction the reader has to resolve for themselves. The rates are labelled;
            // that is all this menu needs to say.
        }

        if model.isStreaming {
            Button("Stop streaming") { model.stop() }
        } else {
            Button("Start streaming") { model.start() }
                .disabled(model.selectedAddress == nil)
        }

        Divider()

        Button("Show the log") { model.openLog() }
        Button("Quit") { model.quit() }
    }
}
