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
        "LDAC \(quality) · battery \(battery)"
    }

    var detailLine: String {
        "latency \(latencyMilliseconds) ms · \(skips) skipped"
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
        adapt = values["adapt"] == "on"
        battery = (values["battery"] ?? "unknown") == "unknown" ? "—" : "\(values["battery"]!)%"
        ringMilliseconds = values["ring_ms"] ?? "—"
        cushionMilliseconds = Int(values["cushion_ms"] ?? "0") ?? 0
        latencyMilliseconds = Int(values["latency_ms"] ?? "0") ?? 0
        skips = values["skips"] ?? "—"
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
        refresh()
    }

    func toggleAdapt() {
        _ = ControlClient.send("adapt \(adapt ? "off" : "on")")
        refresh()
    }

    func start() {
        guard let address = selectedAddress else {
            note = "no headphones chosen"
            return
        }
        do {
            try LaunchAgent.install(address: address, arguments: ["--quality", "MQ"])
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
