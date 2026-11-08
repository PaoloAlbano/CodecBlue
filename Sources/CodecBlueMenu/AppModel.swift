import AppKit
import CodecBlueCore
import Combine
import Foundation

/// Everything the menu shows, and the only place that talks to the outside world.
///
/// Three sources, and no others:
///
/// - `BluetoothHeadphone.audioDevices()` for the list of pairs macOS knows about;
/// - `ControlClient` for what a running stream is doing, and for changing it;
/// - `LaunchAgent` for starting and stopping the stream, because a stream that dies when the
///   window closes is not a stream, it is a demo.
///
/// Polling rather than push: the control channel is a request/response socket, and a menu that is
/// open for a few seconds does not deserve a subscription protocol. Two seconds is fast enough to
/// feel live and slow enough to cost nothing.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var headphones: [BluetoothHeadphone] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var quality = "—"
    /// The rung that is playing, 0…4. `quality` is the name and only three rungs have one, so the
    /// menu needs the number to tick the right entry.
    @Published private(set) var qualityRung = -1
    /// What the encoder is producing, in kbit/s, from the stream itself.
    @Published private(set) var bitrateKbps = "—"
    @Published private(set) var adapt = false
    @Published private(set) var battery = "—"
    @Published private(set) var ringMilliseconds = "—"
    @Published private(set) var skips = "—"
    @Published private(set) var note: String?
    @Published var selectedAddress: String?
    /// The rate the virtual device runs at. Changing it needs coreaudiod reloaded, so the menu
    /// offers it and says so rather than pretending it takes effect at once.
    @Published private(set) var deviceRate = 48000
    /// The cushion, in milliseconds: the audio held between the driver and the socket. This is
    /// the latency, and it is the number a listener can actually judge.
    @Published private(set) var cushionMilliseconds = 0
    /// The latency the listener gets: cushion plus whatever is waiting in the ring.
    @Published private(set) var latencyMilliseconds = 0
    /// Whether bluetoothd has the audio device, which is what keeps the link in A2DP Link Quality
    /// Mode. It is the difference between ~50 kbps and ~500, so a stream that crackles should be
    /// able to say "the link quality mode is off" without anyone reading a log.
    @Published private(set) var linkQuality = "unknown"
    /// What the link actually carried, in kbit/s. The number that decides whether a level is
    /// usable at all: HQ asks 990 and this link carries ~530, so "HQ" here means half the audio
    /// thrown away. Zero means "not measured yet", and the menu then says nothing about fit.
    @Published private(set) var linkKbps = 0.0
    /// The rate the stream is encoding at, which decides what the three levels are worth: at
    /// 44.1 kHz they are 909 / 606 / 303, not 990 / 660 / 330.
    @Published private(set) var streamRate = 48000

    private var timer: Timer?
    /// Where the last choice is remembered. `UserDefaults` is the right size for one string.
    private let selectionKey = "codecblue.selectedAddress"

    init() {
        selectedAddress = UserDefaults.standard.string(forKey: selectionKey)
        refresh()
        // 2 s: fast enough to feel live, slow enough to cost nothing. The menu is usually open for
        // a few seconds at a time, and a timer that fires while it is closed is a wasted wake-up —
        // but polling only while open would mean the icon could not show whether audio is flowing.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: - What the menu shows

    var headline: String {
        if isStreaming { return "Streaming in LDAC" }
        if let address = selectedAddress,
           let device = headphones.first(where: { $0.address == address }) {
            return device.isConnected
                ? "\(device.name) is connected, not streaming"
                : "\(device.name) is off"
        }
        return "No headphones chosen"
    }

    var statusLine: String {
        // The level by its full name, because the code alone does not say what it costs: "LQ"
        // reads as "low" only if you know that Sony calls it MQ. The bitrate is the fact that
        // matters — 330 kbps is what this link is actually carrying — and the battery is the
        // other thing worth a glance.
        "LDAC \(qualityName) \(qualityKbps) · battery \(battery)"
    }

    /// The level as a word: High, Standard, Low.
    var qualityName: String {
        LDACEncoder.Quality.parse(quality)?.longName ?? quality
    }

    /// The bitrate the level is producing, as the encoder itself reports it.
    ///
    /// Not looked up from a table any more: the stream now sits on rungs that have no name, and
    /// the encoder's own number is the only thing that can say "492 kbps".
    var qualityKbps: String {
        guard let kbps = Int(bitrateKbps), kbps > 0 else { return "" }
        return "\(kbps) kbps"
    }

    var detailLine: String {
        var parts = ["latency \(latencyMilliseconds) ms"]
        // The link's measured capacity, when there is one, and only then: "0 kbps" would read as
        // a broken link, and the honest answer before a measurement is silence.
        if linkKbps > 0 { parts.append(String(format: "link %.0f kbps", linkKbps)) }
        parts.append("\(skips) skipped")
        parts.append("link quality \(linkQuality)")
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    func refresh() {
        headphones = BluetoothHeadphone.audioDevices()
        if let ring = try? SharedRing() { deviceRate = ring.sampleRate }
        // A pair that was chosen and has since been unpaired: forget it rather than showing a
        // tick next to nothing.
        if let address = selectedAddress, !headphones.contains(where: { $0.address == address }) {
            selectedAddress = nil
        }
        if selectedAddress == nil, let connected = headphones.first(where: \.isConnected) {
            selectedAddress = connected.address
        }

        guard let lines = ControlClient.send("status") else {
            isStreaming = false
            return
        }
        isStreaming = true
        var values: [String: String] = [:]
        for line in lines where line != "end" {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        quality = values["quality"] ?? "—"
        qualityRung = Int(values["quality_rung"] ?? "") ?? -1
        bitrateKbps = values["quality_kbps"] ?? "—"
        adapt = values["adapt"] == "on"
        battery = (values["battery"] ?? "unknown") == "unknown" ? "—" : "\(values["battery"]!)%"
        ringMilliseconds = values["ring_ms"] ?? "—"
        cushionMilliseconds = Int(values["cushion_ms"] ?? "0") ?? 0
        latencyMilliseconds = Int(values["latency_ms"] ?? "0") ?? 0
        skips = values["skips"] ?? "—"
        linkQuality = values["link_quality"] ?? "unknown"
        linkKbps = Double(values["link_kbps"] ?? "0") ?? 0
        streamRate = Int(values["sample_rate"] ?? "48000") ?? 48000
        note = nil
    }

    func choose(_ device: BluetoothHeadphone) {
        selectedAddress = device.address
        UserDefaults.standard.set(device.address, forKey: selectionKey)
        // Choosing a pair while a stream runs means the old one has to stop: one stream, one
        // pair. The LaunchAgent is rewritten and reloaded, which is what `start` does.
        if isStreaming { stop(keepSelection: true) }
        note = device.isConnected ? nil : "\(device.name) is switched off"
    }

    func setQuality(_ level: String) {
        guard let lines = ControlClient.send("quality \(level)") else {
            note = "no stream is running"
            return
        }
        if let first = lines.first, first.hasPrefix("error") {
            note = first
        }
        // Remembered, or the next restart of the agent — a crash, a login, a change of headphones
        // — would quietly go back to the level in the plist, which is the level nobody chose.
        //
        // The adapter is left as it is: the level is a ceiling, and a ceiling with the adapter off
        // is a stream that sits at a level the link may not carry. That combination is what made
        // HQ unlistenable.
        rememberQuality(level, adapt: adapt)
        refresh()
    }

    func toggleAdapt() {
        _ = ControlClient.send("adapt \(adapt ? "off" : "on")")
        rememberQuality(quality, adapt: !adapt)
        refresh()
    }

    /// Writes the chosen level and cushion into the agent's plist, without reloading it: the
    /// running stream has already been told, and reloading would interrupt the audio to say the
    /// same thing twice.
    private func rememberQuality(_ level: String, adapt: Bool) {
        guard let address = selectedAddress else { return }
        do {
            try LaunchAgent.install(
                address: address,
                arguments: LaunchAgent.arguments(quality: Self.level(level), adapt: adapt,
                                                 cushionMilliseconds: cushionMilliseconds))
        } catch {
            note = "could not remember the setting: \(error.localizedDescription)"
        }
    }

    /// The level as a command-line value, or nil when there is not one yet.
    ///
    /// `quality` is `"—"` until a stream has reported itself, and `--quality —` is not a level:
    /// `codecblue` would print its usage and exit, which launchd would then restart every five
    /// seconds forever. A setting that has never been chosen must be absent, not wrong.
    private static func level(_ text: String) -> String? {
        // The rung number, always, and never the name.
        //
        // The name is not a value `--quality` can always read back: two of the five rungs have no
        // name, and `LDACEncoder.name` returns their *bitrate* for them ("396"), which
        // `LDACEncoder.rung(from:)` would then read as rung 396 and refuse. A plist that holds a
        // setting the program cannot parse is a stream that fails to start at the next login, so
        // what is written is the one spelling that always round-trips.
        guard let rung = LDACEncoder.rung(from: text) else { return nil }
        return String(rung)
    }

    func start() {
        guard let address = selectedAddress else {
            note = "no headphones chosen"
            return
        }
        do {
            // The level and the cushion the listener last chose, not a hard-coded MQ: the agent is
            // restarted by launchd after every crash and every login, and a setting that is
            // forgotten there is a setting that silently reverts.
            try LaunchAgent.install(
                address: address,
                arguments: LaunchAgent.arguments(quality: Self.level(quality), adapt: adapt,
                                                 cushionMilliseconds: cushionMilliseconds))
            try LaunchAgent.load()
            note = nil
        } catch {
            note = "could not start: \(error.localizedDescription)"
        }
        // The stream takes a few seconds to negotiate; polling picks it up.
    }

    func stop(keepSelection: Bool = true) {
        _ = ControlClient.send("quit")
        // And unload the agent, or launchd's KeepAlive would start it again five seconds later —
        // which is the right behaviour for a crash and the wrong one for a deliberate stop.
        try? LaunchAgent.unload()
        if !keepSelection { selectedAddress = nil }
        refresh()
    }

    /// Writes the rate into the ring's header, which the driver reads when coreaudiod loads it.
    ///
    /// It cannot take effect immediately: a device that changed rate under its clients would break
    /// every app that had already opened it. So the menu says what to do next, and the note stays
    /// visible until the app is reopened.
    /// Changes the cushion while the audio plays.
    ///
    /// It is a floor, not a cap: the queue still widens itself when the link stalls, because a
    /// cushion that cannot grow is a cushion that clicks. So a low setting here means "low when
    /// the link allows it", not "low always".
    func setCushion(_ milliseconds: Int) {
        guard let lines = ControlClient.send("cushion \(milliseconds)") else {
            note = "no stream is running"
            return
        }
        if let first = lines.first, first.hasPrefix("error") { note = first }
        // Remembered like the quality, and for the same reason: the agent restarts itself.
        // The new value is written, not the one the status still reports: the stream has just been
        // told and has not published it yet.
        cushionMilliseconds = milliseconds
        rememberQuality(quality, adapt: adapt)
        refresh()
    }

    func setRate(_ rate: Int) {
        guard let ring = try? SharedRing() else {
            note = "the driver is not running"
            return
        }
        ring.setSampleRate(rate)
        deviceRate = rate
        note = "takes effect after: sudo killall coreaudiod"
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: LaunchAgent.logPath))
    }

    func quit() {
        // Leave the stream running: quitting a menu bar app should not stop the music. The
        // LaunchAgent owns it, and `Stop streaming` is the way to stop it.
        NSApplication.shared.terminate(nil)
    }
}
