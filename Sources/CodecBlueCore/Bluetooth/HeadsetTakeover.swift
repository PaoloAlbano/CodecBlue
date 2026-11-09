// Taking a pair of headphones over from macOS, and handing them back.
//
// The sequence and its timing constants come from Blue Bloom's measurements (MIT,
// Copyright (c) 2026 Blue Bloom contributors), made with Focal Bathys, Sony WH-1000XM4
// and others on macOS 26/27:
//
// * Headphones connected to macOS: force-disconnect. bluetoothd keeps the link about 2 s
//   ("override disconnection timeout"), and a signaling request in that window is accepted
//   on the same link. Our open channel then keeps the link up ("taking over in place").
// * Headphones not connected: ask bluetoothd to connect them, let macOS connect their
//   audio first (its round of profile connections cannot be stopped), then take over in
//   place.
// * Only one signaling request in flight at a time, one per XPC session (bluetoothd allows
//   one channel request per session and device). A request unanswered for 2 s no longer
//   holds the next one back.
// * A grabbed channel that does not answer DISCOVER within 1.5 s is a fake: grab again.

import Foundation

public struct TakeoverTiming: Sendable {
    public var raceInterval: TimeInterval = 0.04
    public var requestStuckAfter: TimeInterval = 2
    public var roundTimeout: TimeInterval = 6
    public var systemGoneMaxWait: TimeInterval = 0.8
    public var systemConnectWait: TimeInterval = 8
    public var systemConnectSettle: TimeInterval = 0.3
    public var discoverTimeout: TimeInterval = 1.5
    public var inPlaceRetries = 2
    public var raceSessions = 6
    public static let measured = TakeoverTiming()
}

public enum TakeoverError: Error, CustomStringConvertible {
    case notPaired(String)
    case headphonesDidNotConnect
    case notGrabbed(lastResult: Int?)
    case fakeChannel

    public var description: String {
        switch self {
        case .notPaired(let address):
            "\(address) is not known to this Mac (pair it in System Settings first)"
        case .headphonesDidNotConnect:
            "the headphones did not connect (off, out of range, or busy with another device)"
        case .notGrabbed(let result):
            "could not take the headphones' audio channel from macOS"
                + (result.map { " (last result \($0))" } ?? "")
        case .fakeChannel: "the headphones never answered on the grabbed channel"
        }
    }
}

public final class HeadsetTakeover: @unchecked Sendable {
    public let address: String
    public let timing: TakeoverTiming

    /// Called the moment macOS has published the headphones' audio device, which is the only
    /// window in which bluetoothd has a `-tacl` device for `StartAudio` to land on.
    ///
    /// It exists because the link quality mode has to be asked for *in that window*, and the
    /// window is short and unpredictable: the takeover closes the media channel seconds later and
    /// bluetoothd erases the device with it. Measured 2026-11-08: the device was registered at
    /// 19:03:26.986 and erased at 19:03:27.707, and a keeper that asked once a second from a
    /// different starting point missed all of it — 65% of the audio dropped, heard as crackle.
    public var onSystemConnected: (@Sendable () -> Void)?
    public private(set) var device: UUID?
    public private(set) var signalSession: ClassicXPCSession?
    public private(set) var signaling: SignalingChannel?
    /// True when the link was up before we started (macOS had the headphones).
    public private(set) var wasConnected = false
    /// bluetoothd's record from the start of the takeover (services, RFCOMM channels).
    public private(set) var record: DeviceRecord?

    /// Ask bluetoothd for a low-latency link when it has to connect the headphones. Only
    /// takes effect on a fresh connection: bluetoothd computes the connection use case then,
    /// and a link macOS already brought up keeps its sniff parameters.
    public var lowLatency = false

    private let log: @Sendable (String) -> Void
    private var sessions: [ClassicXPCSession] = []
    /// One XPC session per extra channel (bluetoothd allows one channel per session and
    /// device), so that each can be closed on hand-back.
    private var extraChannels: [(session: ClassicXPCSession, psm: UInt16)] = []
    private var rfcommChannels: [(session: ClassicXPCSession, channel: UInt8)] = []

    public init(
        address: String, timing: TakeoverTiming = .measured,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.address = address
        self.timing = timing
        self.log = log
    }

    // MARK: - Grab

    /// Takes the headphones' AVDTP signaling channel away from macOS.
    public func grabSignaling() async throws -> SignalingChannel {
        try await startSessions()
        guard let device else { throw TakeoverError.notPaired(address) }
        let control = sessions[0]

        let record = try await control.lookup(address: address)
        self.record = record
        wasConnected = record.isLinkUp
        if record.isLinkUp {
            log("headphones connected to macOS: taking the link over in place")
        } else {
            log(
                "headphones not connected: asking macOS to connect them first"
                    + (lowLatency ? " (low latency)" : ""))
            control.connect(device, lowLatency: lowLatency)
            try await waitForSystemConnection(control)
        }

        // Force macOS off the link once; a fake channel is retried on the same link.
        control.cancelConnection(device, force: true)
        await waitForSystemToLetGo(control)
        for attempt in 0...timing.inPlaceRetries {
            let (session, socket) = try await race(device)
            let channel = SignalingChannel(socket: socket)
            do {
                _ = try await channel.command(.discover, timeout: timing.discoverTimeout)
                signalSession = session
                signaling = channel
                log("signaling channel grabbed (MTU \(socket.outMTU))")
                return channel
            } catch {
                log("grabbed channel did not answer DISCOVER (attempt \(attempt + 1)): \(error)")
                channel.close()
                session.closeChannel(device, psm: AVDTP.psm)
            }
        }
        throw TakeoverError.fakeChannel
    }

    private func startSessions() async throws {
        guard sessions.isEmpty else { return }
        let sessions = (0..<timing.raceSessions).map { ClassicXPCSession(label: "race\($0)") }
        for session in sessions { try await session.start() }
        self.sessions = sessions
        device = try? await sessions[0].lookup(address: address).uuid
    }

    private func waitForSystemConnection(_ control: ClassicXPCSession) async throws {
        let deadline = Date().addingTimeInterval(timing.systemConnectWait)
        while Date() < deadline {
            let up = (try? await control.lookup(address: address).isLinkUp) ?? false
            if up && SystemHeadphoneAudio.hasDevice(address: address) {
                log("macOS connected the headphones' audio")
                // The one moment `StartAudio` is certain to land: bluetoothd has just published
                // the device. See `onSystemConnected`.
                onSystemConnected?()
                try await Task.sleep(for: .seconds(timing.systemConnectSettle))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let up = (try? await control.lookup(address: address).isLinkUp) ?? false
        if !up { throw TakeoverError.headphonesDidNotConnect }
        log("link up but macOS did not publish the headphones' audio; taking over anyway")
    }

    /// After the forced disconnect, wait until coreaudiod drops the headphones' devices
    /// (macOS's AVDTP channel is gone), at most `systemGoneMaxWait`.
    private func waitForSystemToLetGo(_ control: ClassicXPCSession) async {
        let start = Date()
        while Date().timeIntervalSince(start) < timing.systemGoneMaxWait {
            if !SystemHeadphoneAudio.hasDevice(address: address) {
                log(
                    String(
                        format: "macOS let go %.0f ms after the forced disconnect",
                        Date().timeIntervalSince(start) * 1000))
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        log("macOS still lists the headphones' audio; grabbing anyway")
    }

    /// Requests the signaling channel, one request at a time, until one wins.
    private func race(_ device: UUID) async throws -> (ClassicXPCSession, ChannelSocket) {
        let results = RaceResults()
        let deadline = Date().addingTimeInterval(timing.roundTimeout)
        var inFlight: (session: Int, since: Date)?
        var next = 0
        var requests = 0
        while Date() < deadline {
            if let won = results.takeWinner() {
                log("grabbed after \(requests) request(s)")
                return (
                    sessions[won.session],
                    ChannelSocket(channel: won.channel, label: "avdtp-signal")
                )
            }
            if let current = inFlight, results.isFinished(current.session) {
                inFlight = nil
            }
            let stuck =
                inFlight.map { Date().timeIntervalSince($0.since) > timing.requestStuckAfter }
                ?? false
            if inFlight == nil || stuck {
                let index = next % sessions.count
                next += 1
                if !results.isBusy(index) {
                    results.begin(index)
                    inFlight = (index, Date())
                    requests += 1
                    let session = sessions[index]
                    Task {
                        do {
                            let channel = try await session.openChannel(
                                device, psm: AVDTP.psm, timeout: 5)
                            if !results.finish(index, channel: channel) {
                                // Someone else already won: give this one back.
                                close(channel.fd)
                                session.closeChannel(device, psm: AVDTP.psm)
                            }
                        } catch {
                            if case ClassicXPCError.refused(let code) = error {
                                results.refused(index, code)
                            } else {
                                results.refused(index, nil)
                            }
                        }
                    }
                }
            }
            try await Task.sleep(for: .seconds(timing.raceInterval))
        }
        results.closeRound()
        throw TakeoverError.notGrabbed(lastResult: results.lastRefusal)
    }

    // MARK: - More channels on the grabbed link

    /// Asks bluetoothd to raise the ACL priority of the link, which is what keeps the
    /// controller out of sniff mode. Returns false when this macOS release does not let us
    /// (the message number is not known yet).
    @discardableResult
    public func requestHighPriority() -> Bool {
        guard let device, let control = sessions.first else { return false }
        return control.setACLHighPriority(device)
    }

    /// Opens another L2CAP channel to the headphones (AVDTP media, AVRCP...) in its own XPC
    /// session.
    public func openChannel(
        psm: UInt16, label: String, priority: Int64 = 0,
        timeout: TimeInterval = 5
    ) async throws -> OpenedChannel {
        guard let device else { throw TakeoverError.notPaired(address) }
        let session = ClassicXPCSession(label: label)
        try await session.start()
        do {
            let channel = try await session.openChannel(
                device, psm: psm, priority: priority, timeout: timeout)
            extraChannels.append((session, psm))
            return channel
        } catch {
            session.invalidate()
            throw error
        }
    }

    /// Opens an RFCOMM channel to the headphones in its own XPC session.
    public func openRFCOMM(channel: UInt8, label: String, timeout: TimeInterval = 5) async throws
        -> OpenedChannel
    {
        guard let device else { throw TakeoverError.notPaired(address) }
        let session = ClassicXPCSession(label: label)
        try await session.start()
        do {
            let opened = try await session.openRFCOMM(device, channel: channel, timeout: timeout)
            rfcommChannels.append((session, channel))
            return opened
        } catch {
            session.invalidate()
            throw error
        }
    }

    // MARK: - Hand back

    /// How much of the link to give up when handing the headphones back.
    public enum HandBackStyle: Sendable {
        /// Drop the link and let macOS connect the headphones from scratch. Costs ~8 s.
        case reconnect
        /// Close our channels, keep the link, ask bluetoothd for its profiles back. Falls back to
        /// `.reconnect` if macOS does not publish the headphones' audio in `inPlaceWait`.
        case inPlace

        public static func named(_ text: String) -> HandBackStyle? {
            switch text.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "reconnect": return .reconnect
            case "inplace", "in-place": return .inPlace
            default: return nil
            }
        }
    }

    /// How long `.inPlace` waits before falling back to dropping the link.
    public var inPlaceWait: TimeInterval = 3

    /// How long the reconnect path waits for macOS to publish the headphones' audio before giving
    /// up and saying so. Ten seconds covers the 7.4 s measured on 2026-11-09 with room to spare.
    public var reconnectWait: TimeInterval = 10

    /// Closes our channels and lets macOS connect the headphones as usual.
    public func handBack(_ style: HandBackStyle = .reconnect) async {
        guard let device else { return invalidateAll() }
        signaling?.close()
        signalSession?.closeChannel(device, psm: AVDTP.psm)
        signaling = nil
        for extra in extraChannels { extra.session.closeChannel(device, psm: extra.psm) }
        for rfcomm in rfcommChannels { rfcomm.session.closeRFCOMM(device, channel: rfcomm.channel) }
        extraChannels.removeAll()
        rfcommChannels.removeAll()
        let control = sessions.first

        if style == .inPlace {
            // Let go of everything of ours first, then ask bluetoothd to bring its profiles back
            // on the link that is already up. Order matters: with our sessions still alive
            // bluetoothd does nothing at all (measured 2026-11-09, twelve seconds of silence).
            invalidateAll()
            control?.connect(device)
            let started = Date()
            while Date().timeIntervalSince(started) < inPlaceWait {
                if SystemHeadphoneAudio.hasDevice(address: address) {
                    log(
                        String(
                            format: "macOS took the headphones back in place after %.0f ms",
                            Date().timeIntervalSince(started) * 1000))
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            log(
                String(
                    format:
                        "macOS did not take the headphones back in place within %.0f s: dropping the link",
                    inPlaceWait))
            control?.cancelConnection(device, force: true)
        }

        let dropped = Date()
        control?.cancelConnection(device, force: true)
        // Wait for the link to drop, then ask macOS to reconnect normally (no grabbing).
        for _ in 0..<50 {
            guard let up = try? await control?.lookup(address: address).isLinkUp, up else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // How long the link took to fall. It is the largest part of a hand-back and it was never
        // measured: the old code slept a flat second here and reported nothing, so "the hand-back
        // takes seven seconds" had no breakdown behind it.
        log(
            String(
                format: "the link fell %.0f ms after the forced disconnect",
                Date().timeIntervalSince(dropped) * 1000))
        log("asking macOS to reconnect the headphones")
        let asked = Date()
        control?.connect(device)
        invalidateAll()
        // Wait for the result instead of sleeping for a guess.
        //
        // This used to be `sleep(3)` and a return, which made the hand-back *look* like it took
        // three seconds while the headphones were still missing for five more. Measured
        // 2026-11-09: `asking macOS to reconnect` at 13:05:44.2, macOS publishing the headphones'
        // audio at 13:05:51.6 — 7.4 s, and the process had already exited. A number in a log is
        // only useful if it is the number the listener experiences.
        while Date().timeIntervalSince(asked) < reconnectWait {
            if SystemHeadphoneAudio.hasDevice(address: address) {
                log(
                    String(
                        format: "macOS has the headphones again after %.1f s",
                        Date().timeIntervalSince(asked)))
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log(
            String(
                format:
                    "macOS has not published the headphones' audio after %.0f s: if it does not, put them in the case for a few seconds",
                reconnectWait))
    }

    private func invalidateAll() {
        for session in sessions { session.invalidate() }
        for extra in extraChannels { extra.session.invalidate() }
        for rfcomm in rfcommChannels { rfcomm.session.invalidate() }
        sessions.removeAll()
        extraChannels.removeAll()
        rfcommChannels.removeAll()
    }
}

/// Bookkeeping for the request race, shared with the request tasks.
private final class RaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var busy: Set<Int> = []
    private var finished: Set<Int> = []
    private var winner: (session: Int, channel: OpenedChannel)?
    private var discardLateWinners = false
    private(set) var lastRefusal: Int?

    func closeRound() { lock.withLock { discardLateWinners = true } }

    func begin(_ i: Int) {
        lock.withLock {
            _ = busy.insert(i)
            finished.remove(i)
        }
    }
    func isBusy(_ i: Int) -> Bool { lock.withLock { busy.contains(i) } }
    func isFinished(_ i: Int) -> Bool { lock.withLock { finished.contains(i) } }

    /// Returns false if the channel is not wanted (another request already won).
    func finish(_ i: Int, channel: OpenedChannel) -> Bool {
        lock.withLock {
            busy.remove(i)
            finished.insert(i)
            if winner != nil || discardLateWinners { return false }
            winner = (i, channel)
            return true
        }
    }

    func refused(_ i: Int, _ code: Int?) {
        lock.withLock {
            busy.remove(i)
            finished.insert(i)
            if let code { lastRefusal = code }
        }
    }

    /// The winning channel, once. Later successes are given back.
    func takeWinner() -> (session: Int, channel: OpenedChannel)? {
        lock.withLock {
            guard let won = winner else { return nil }
            winner = nil
            discardLateWinners = true
            return won
        }
    }
}
