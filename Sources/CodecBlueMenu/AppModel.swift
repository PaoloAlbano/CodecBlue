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
    /// What a window that *dropped audio* measured: the link's real ceiling, in kbit/s.
    ///
    /// This is the only number allowed to decide whether a level fits. Zero means "not measured
    /// yet", and the menu then says nothing about fit — a menu that guesses is worse than one that
    /// admits it does not know.
    @Published private(set) var linkKbps = 0.0

    /// What the link has demonstrably carried, in kbit/s. A *floor*, not a ceiling.
    ///
    /// Kept apart from `linkKbps` on purpose, and the separation is the whole point: a stream
    /// paced to real time reports "kept up" on a link with any amount of spare room, so 336 kbps
    /// carried says nothing about whether 990 would fit. Feeding this into the fit test would
    /// claim HQ "gives 330 here" on a link that has never been asked to try — measured 2026-11-09,
    /// and the first version of this did exactly that.
    @Published private(set) var linkFloorKbps = 0.0

    /// Whether `linkKbps` came from a ceiling (a window that lost audio) or from the floor.
    ///
    /// The distinction is the difference between "this does not fit" and "this is what the link has
    /// carried so far", and the menu says one or the other. Collapsing them into one number is what
    /// produced "HQ 990 kbps" on a link carrying 303.
    @Published private(set) var linkIsCeiling = false
    /// The rate the stream is encoding at, which decides what the three levels are worth: at
    /// 44.1 kHz they are 909 / 606 / 303, not 990 / 660 / 330.
    @Published private(set) var streamRate = 48000
    /// Whether the icon starts at login. Read from the installed launch item, not from a
    /// preference: two places to remember the same thing is two places to disagree.
    @Published private(set) var startsAtLogin = MenuBarLoginItem.isInstalled

    private var timer: Timer?
    /// Whether the menu is on screen right now.
    ///
    /// The timer keeps polling so the icon stays honest, but it does not *publish* while the menu
    /// is open. Every published change rebuilds the menu, and a rebuild closes whatever submenu is
    /// open — measured 2026-11-09, reported as "as soon as the latency part refreshes, the
    /// submenus close": the timer fires every two seconds, so a submenu could not stay open long
    /// enough to be clicked. A status line that is two seconds stale is invisible; a menu that
    /// closes under the pointer is not.
    private var menuIsOpen = false
    /// When the menu was last seen opening, so a latch that never cleared can be noticed.
    private var menuOpenedAt: Date?
    /// How long the latch may stay set before it is assumed stuck.
    ///
    /// Reported 2026-11-11: "the app at the top says the headphones are not connected, but I think
    /// they are working now". They were: the stream was playing at 363 kbps with the device as the
    /// system output, and the menu had been frozen for fourteen hours — since the moment it was
    /// first opened, when the headphones really were off.
    ///
    /// The cause is this latch and the assumption behind it. `menuIsOpen` is cleared by
    /// `onDisappear`, and with `MenuBarExtra` in `.menu` style that callback is not reliably
    /// called: the menu is dismissed by AppKit, the SwiftUI view is not torn down, and the flag
    /// stays true for the life of the process. From then on every `refresh()` returns at the
    /// guard, so nothing is ever published again — the menu shows whatever it showed the first
    /// time it was opened, forever, while the icon and the stream move on.
    ///
    /// A status line two seconds stale is invisible; one fourteen hours stale is a lie. So the
    /// latch is now bounded in time: past this, it is treated as stuck and cleared.
    private static let openLatchLimit: TimeInterval = 60
    /// Where the last choice is remembered. `UserDefaults` is the right size for one string.
    private let selectionKey = "codecblue.selectedAddress"

    /// The one instance, so the app delegate's Cmd-Q can reach `quit()`.
    ///
    /// Cmd-Q is handled by AppKit before any SwiftUI button is involved, so without this the
    /// keyboard would keep the old behaviour — icon gone, stream running — and only the menu item
    /// would stop it. Two ways to quit with two different outcomes is exactly the bug being fixed.
    static private(set) weak var shared: AppModel?

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
        AppModel.shared = self
    }

    // MARK: - What the menu shows

    var headline: String {
        if isStreaming { return "Streaming in LDAC" }
        if let address = selectedAddress,
            let device = headphones.first(where: { $0.address == address })
        {
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
    /// The bitrate the playing rung is producing, as a number, for the menu line.
    ///
    /// `nil` when nothing is playing: a number next to a level that is not producing anything is
    /// the "HQ · 990 kbps" mistake in a smaller font.
    var playingKbps: Int? {
        guard let kbps = Int(bitrateKbps), kbps > 0 else { return nil }
        return kbps
    }

    var qualityKbps: String {
        guard let kbps = Int(bitrateKbps), kbps > 0 else { return "" }
        return "\(kbps) kbps"
    }

    var detailLine: String {
        var parts = ["latency \(latencyMilliseconds) ms"]
        // The link's measured capacity, when there is one, and only then: "0 kbps" would read as
        // a broken link, and the honest answer before a measurement is silence.
        // The ceiling when it is known, because that is a limit; otherwise the floor, worded as
        // what it is. "link 336 kbps" on a link nobody has pushed would read as a limit, and the
        // whole complaint being fixed here is numbers presented as promises.
        // The word follows the evidence. "carries" is a limit and needs a ceiling; without one the
        // honest sentence is "has done", which is a measurement of the past and not a promise about
        // the future. Using "carries" for a floor is how "link 336 kbps" came to read as a cap.
        if linkKbps > 0 {
            parts.append(
                String(
                    format: linkIsCeiling ? "link carries %.0f kbps" : "link has done %.0f kbps",
                    linkKbps))
        } else if linkFloorKbps > 0 {
            parts.append(String(format: "link has done %.0f kbps", linkFloorKbps))
        }
        parts.append("\(skips) skipped")
        parts.append("link quality \(linkQuality)")
        return parts.joined(separator: " · ")
    }

    /// What is driving a pair, for the line beside its name: " · LDAC", " · AAC via macOS", or
    /// nothing when nobody has asked yet.
    ///
    /// The refusal is read from disk, not measured: measuring means opening an AVDTP channel, which
    /// forces macOS off the headphones for a second. That is acceptable once, when someone presses
    /// Start; it is not acceptable every two seconds to decorate a menu. So the answer is whatever
    /// the last attempt found, and a pair nobody has tried is left blank rather than guessed at.
    func codecNote(for device: BluetoothHeadphone) -> String {
        guard device.isConnected else { return "" }
        if let refusal = CodecFallback.refusal(for: device.address) {
            // The codecs the pair actually offered, in the order it offered them, each once.
            // `offered` is already deduplicated where it is written (a pair publishes two sinks per
            // codec, so the raw answer is `SBC, SBC, AAC, AAC`); the `Set` here is a second guard,
            // because a refusal written by an older build may still carry the duplicates.
            let offered = refusal.offered.filter { $0 == "AAC" || $0 == "SBC" }
            var seen: Set<String> = []
            let unique = offered.filter { seen.insert($0).inserted }
            let what = unique.isEmpty ? "SBC/AAC" : unique.joined(separator: "/")
            return " · \(what) via macOS"
        }
        if isStreaming, device.address == selectedAddress { return " · LDAC" }
        return ""
    }

    // MARK: - Actions

    /// Called when the menu appears, so polling stops rebuilding it.
    func menuOpened() {
        // Refresh *before* the flag, so the menu draws with current numbers.
        //
        // Reported 2026-11-09: "the headphones are in the case but the menu still says they are
        // connected". They were: the last publish happened while they were still out, and this
        // method only stopped publishing without ever taking a fresh reading. The menu opened on
        // whatever was true up to two seconds earlier, which for a state that changes when a lid
        // closes is the wrong two seconds. Publishing once here is safe — the menu is not drawn
        // yet, so nothing can be closed by it.
        // Forced, not merely requested: if the latch is stuck true, an ordinary `refresh()` would
        // return at the guard and the menu would open on the same stale numbers it is stuck on.
        // Opening is the one moment a rebuild cannot close anything — the menu is not drawn yet.
        refresh(force: true)
        menuIsOpen = true
        menuOpenedAt = Date()
    }

    /// Called when it closes: refresh once, so the next open shows current numbers.
    func menuClosed() {
        menuIsOpen = false
        menuOpenedAt = nil
        refresh()
    }

    func refresh(force: Bool = false) {
        // Polling continues while the menu is open — the icon depends on it — but nothing is
        // published, because publishing is what closes the submenu the pointer is in.
        //
        // Unless the latch has been set for longer than any human keeps a menu open: then
        // `onDisappear` was never called, and holding the menu still is holding it wrong.
        if menuIsOpen, let openedAt = menuOpenedAt,
            Date().timeIntervalSince(openedAt) > Self.openLatchLimit
        {
            menuIsOpen = false
            menuOpenedAt = nil
        }
        guard force || !menuIsOpen else { return }
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
        // The ceiling decides what fits; when there is no ceiling yet, the floor is still a fact
        // about this link and must be shown instead of the codec's own number.
        //
        // Reported 2026-11-09, twice: "I still see HQ at 990 kbps, I thought I had been clear".
        // It was clear, and the code was reading `link_ceiling` alone — which is 0 until a window
        // actually loses audio, and on a healthy stream that never happens. So `capacity` stayed 0,
        // `wouldUse` returned nil, and the label fell back to the rung's nominal 990 while the
        // stream was playing 303. A number that is wrong on every healthy stream is not a
        // conservative default, it is a wrong default.
        //
        // The two numbers keep their different meanings: `link_ceiling` is the only thing allowed
        // to say "this does not fit", and `link_floor` is what the link has demonstrably carried.
        // For *display* the floor is the better of the two when the ceiling is missing, because it
        // is measured rather than assumed, and `QualityLevels` says which one it used.
        // A ceiling *below* what is playing is not a ceiling, it is one unlucky window.
        //
        // Measured 2026-11-11, with the stream running cleanly: `link_ceiling 250`, `link_floor
        // 312`, `quality_kbps 303`, `skips 0`. The menu said "link carries 250 kbps" while 303 was
        // going through without losing a sample — a number smaller than the thing it claimed to
        // bound. The ceiling is the throughput of *one* window that dropped audio, and a window
        // can drop because `bluetoothd` stalled, not because the level does not fit; the code
        // already knows this (see the settle rule), and the display did not.
        //
        // So the playing bitrate is the third witness, and it settles the argument: a link cannot
        // be carrying less than what is demonstrably passing through it. When the ceiling is below
        // that, the ceiling is discarded and the floor is used instead — the floor is a measurement
        // of what the link has done, which is exactly the claim being made.
        let ceiling = Double(values["link_ceiling"] ?? "0") ?? 0
        let floor = Double(values["link_floor"] ?? "0") ?? 0
        let playing = Double(values["quality_kbps"] ?? "0") ?? 0
        // Both witnesses, and the floor was missing.
        //
        // Measured 2026-11-11: `link_ceiling 514`, `link_floor 549`, `quality_kbps 303`. The
        // ceiling passed the playing-bitrate test (514 >= 303) and was used, so the menu said the
        // link carries 514 kbps while the stream's own history said it had carried 549. A ceiling
        // below the floor is self-contradictory: the floor is the maximum throughput ever measured,
        // so nothing can credibly bound the link beneath it.
        //
        // This is what makes the three levels update in the background without touching the rung:
        // the floor is measured passively on every window, at whatever level is playing, and it is
        // the one number that improves without a probe. Letting a stale ceiling override it threw
        // away the only free measurement there is.
        let witness = max(playing, floor)
        let ceilingIsCredible = ceiling > 0 && (witness <= 0 || ceiling >= witness)
        linkIsCeiling = ceilingIsCredible
        linkKbps = ceilingIsCredible ? ceiling : floor
        linkFloorKbps = floor
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
                arguments: LaunchAgent.arguments(
                    quality: Self.level(level), adapt: adapt,
                    cushionMilliseconds: cushionMilliseconds,
                    // Carried through, not re-chosen: the capacity was measured at rest by
                    // `codecblue flood` and belongs to the machine. Rebuilding the argument list
                    // without it would erase the measurement on the first level change, and the
                    // menu would go back to learning the ceiling by dropping audio.
                    capacityKbps: LaunchAgent.knownCapacityKbps()))
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

    /// Turns "start at login" on or off, and says so if it could not.
    func toggleLoginItem() {
        if startsAtLogin {
            MenuBarLoginItem.remove()
            startsAtLogin = MenuBarLoginItem.isInstalled
            note = startsAtLogin ? "could not remove the login item" : nil
            return
        }
        do {
            try MenuBarLoginItem.install()
            note = nil
        } catch {
            note = "could not start at login: \(error.localizedDescription)"
        }
        startsAtLogin = MenuBarLoginItem.isInstalled
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
                arguments: LaunchAgent.arguments(
                    quality: Self.level(quality), adapt: adapt,
                    cushionMilliseconds: cushionMilliseconds,
                    capacityKbps: LaunchAgent.knownCapacityKbps()))
            try LaunchAgent.load()
            note = nil
        } catch {
            note = "could not start: \(error.localizedDescription)"
        }
        // The stream takes a few seconds to negotiate; polling picks it up.
    }

    func stop(keepSelection: Bool = true) {
        // Unload the agent first, then ask the stream to stop.
        //
        // The order looks arbitrary and is not. `unload` sends SIGTERM, which the stream now
        // handles by stopping politely and handing the headphones back — but the hand-back takes
        // a few seconds (the link has to drop, then macOS has to reconnect), and unloading also
        // removes the thing that would restart it. Asking the socket first and unloading
        // immediately after would race a teardown that has not finished.
        //
        // Keeping the agent loaded and only sending `quit` is worse: KeepAlive restarts the stream
        // five seconds later, which is right for a crash and wrong for a deliberate stop.
        try? LaunchAgent.unload()
        _ = ControlClient.send("quit")
        if !keepSelection { selectedAddress = nil }
        // The stream is still handing the headphones back; the icon should say so rather than
        // flipping to "not streaming" while the link is still ours.
        note = "stopping: handing the headphones back to macOS"
        // The class is already @MainActor, so this inherits it: no annotation needed, and adding
        // one would suggest the isolation was in doubt.
        Task {
            // A little longer than the teardown takes, so the note does not disappear while it is
            // still true.
            try? await Task.sleep(for: .seconds(7))
            note = nil
            refresh()
        }
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

    /// Quit means quit: the icon and the stream go together.
    ///
    /// Asked 2026-11-09: "can we make it so that when I quit it actually stops CodecBlue?" Yes, and
    /// the previous behaviour was defensible in the wrong direction. The argument for leaving the
    /// stream running was that quitting a menu bar app should not stop the music — true for a
    /// player, false here, because this app is not playing anything. It is holding the headphones
    /// away from macOS, and a process you can no longer see is holding them on your behalf.
    ///
    /// The old arrangement had one honest justification and it was not about the music: the stream
    /// survives a crash, and that is worth keeping. It is kept — a crash is not a Quit. `terminate`
    /// is only reached by a deliberate press, and Cmd-Q is routed here too (see `AppDelegate`), so
    /// there is no path where the icon disappears and the stream keeps running.
    ///
    /// The hand-back takes a few seconds, so the app waits for it rather than exiting into a
    /// half-finished teardown: `stop` is synchronous about the unload and the socket, and the
    /// remaining wait is the link dropping and macOS reconnecting, which outlives us harmlessly.
    func quit() {
        quitWithoutTerminating()
        NSApplication.shared.terminate(nil)
    }

    /// The stop half of `quit()`, for the path where AppKit is already terminating us.
    ///
    /// Split because `applicationShouldTerminate` cannot call `terminate` again — that is a
    /// re-entrant quit, and AppKit answers it with a beep and no exit.
    func quitWithoutTerminating() {
        guard isStreaming || LaunchAgent.isLoaded() else { return }
        stop()
    }
}
