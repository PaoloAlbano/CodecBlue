// An XPC session with bluetoothd's classic Bluetooth service: device lookup, connections,
// and L2CAP/RFCOMM channels handed to us as sockets.
//
// Protocol knowledge from Blue Bloom (MIT); see XPCProtocol.swift. Unlike a plain port,
// every request here is asynchronous and has a timeout, and connection errors
// (bluetoothd restarting, the service changing) fail every pending request instead of
// leaving it hanging.

import Foundation
@preconcurrency import XPC

public enum ClassicXPCError: Error, CustomStringConvertible, Equatable {
    case connectionLost(String)
    case timeout(String)
    case refused(Int)
    case notReady
    /// bluetoothd said the radio is off. Distinct from `notReady` so that the retry in `start`
    /// can tell "nobody answered" from "the answer is no".
    case powerOff
    case unknownDevice(String)
    case malformedReply(String)

    public var description: String {
        switch self {
        case .connectionLost(let why): "connection to bluetoothd lost (\(why))"
        case .timeout(let what): "bluetoothd did not answer: \(what)"
        case .refused(let code): "refused by bluetoothd or the headphones (result \(code))"
        case .notReady: "Bluetooth is not powered on"
        case .powerOff: "Bluetooth is switched off"
        case .unknownDevice(let address): "bluetoothd does not know \(address)"
        case .malformedReply(let what): "unexpected reply from bluetoothd: \(what)"
        }
    }
}

/// bluetoothd's record of a device (answered from its database; nothing goes over the air).
public struct DeviceRecord: Sendable, CustomStringConvertible {
    public let uuid: UUID
    /// 0 while there is no link, 2 while one is up (observed).
    public let linkState: Int64
    /// 16-bit service UUIDs with their RFCOMM channel (0 for L2CAP-only services).
    public let services: [(uuid16: UInt16, rfcomm: UInt8)]

    public var isLinkUp: Bool { linkState == 2 }

    public var description: String {
        let list = services.map {
            String(format: "0x%04X%@", $0.uuid16, $0.rfcomm > 0 ? "/rfcomm \($0.rfcomm)" : "")
        }
        return "device \(uuid) link=\(linkState) services=[\(list.joined(separator: ", "))]"
    }
}

/// A bare connection to one of bluetoothd's XPC services, used to probe message numbers.
///
/// The general service does not take the classic check-in (it never reports a power state),
/// so this only opens the connection, sends, and waits a moment: what matters is what
/// bluetoothd logs, not the reply.
public final class XPCProbe: @unchecked Sendable {
    private let connection: xpc_connection_t
    private let queue = DispatchQueue(label: "codecblue.probe")

    public init(service: String) {
        connection = xpc_connection_create_mach_service(service, queue, 0)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
    }

    deinit { xpc_connection_cancel(connection) }

    /// Sends `kCBMsgId` with the given arguments. A device UUID is passed under the usual key
    /// when one is given, so that device handlers have something to fail on.
    /// Sends a raw dictionary: the audio channel of bluetoothd takes its own keys
    /// (`kBTAudioMsgId`, `kBTAudioMsgDeviceUid`), not the classic ones.
    public func sendRaw(_ message: [String: Any]) {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        Self.fill(dictionary, with: message)
        queue.sync { xpc_connection_send_message(connection, dictionary) }
    }

    private static func fill(_ dictionary: xpc_object_t, with message: [String: Any]) {
        for (key, value) in message {
            switch value {
            case let number as Int64: xpc_dictionary_set_int64(dictionary, key, number)
            case let text as String:
                xpc_dictionary_set_string(dictionary, key, text)
            case let nested as [String: Any]:
                let child = xpc_dictionary_create(nil, nil, 0)
                fill(child, with: nested)
                xpc_dictionary_set_value(dictionary, key, child)
            default: break
            }
        }
    }

    public func send(_ id: Int64, device: UUID? = nil, arguments: [String: Int64] = [:]) {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(message, XPCKey.messageID, id)
        let args = xpc_dictionary_create(nil, nil, 0)
        if let device {
            withUnsafeBytes(of: device.uuid) { raw in
                xpc_dictionary_set_uuid(
                    args, XPCKey.deviceUUID, raw.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
        for (key, value) in arguments { xpc_dictionary_set_int64(args, key, value) }
        xpc_dictionary_set_value(message, XPCKey.arguments, args)
        queue.sync { xpc_connection_send_message(connection, message) }
    }
}

/// A channel bluetoothd opened for us: the socket is ours to read, write and close.
public struct OpenedChannel: Sendable {
    public let fd: Int32
    public let cid: UInt16
    public let outMTU: UInt16
}

public final class ClassicXPCSession: @unchecked Sendable {
    public let label: String
    public let proto: XPCProtocol
    /// Called on the session queue when a channel of ours is closed (PSM, result).
    public var onChannelClosed: (@Sendable (UInt16, Int) -> Void)?
    /// Called on the session queue when Bluetooth power changes (true = on).
    public var onPowerChanged: (@Sendable (Bool) -> Void)?

    private let queue: DispatchQueue
    /// Marks `queue`, so that calls from our own callbacks (which run on it) never
    /// dispatch_sync onto it and deadlock.
    private let onQueueKey = DispatchSpecificKey<Bool>()
    private var connection: xpc_connection_t?
    private var ready = false
    /// Set when bluetoothd has explicitly said the radio is off. A retry is pointless then: the
    /// answer will be the same for as long as the switch stays off, and three five-second waits
    /// would turn "Bluetooth is off" into a sixteen-second hang.
    private var powerOff = false
    private var failure: ClassicXPCError?
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var openWaiters: [UInt16: CheckedContinuation<OpenedChannel, Error>] = [:]
    private var rfcommWaiters: [UInt8: CheckedContinuation<OpenedChannel, Error>] = [:]

    private let serviceOverride: String?

    public init(label: String, proto: XPCProtocol = .current, service: String? = nil) {
        self.label = label
        self.proto = proto
        serviceOverride = service
        queue = DispatchQueue(label: "codecblue.xpc.\(label)")
        queue.setSpecific(key: onQueueKey, value: true)
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: onQueueKey) == true ? body() : queue.sync(execute: body)
    }

    deinit { invalidate() }

    // MARK: - Lifecycle

    /// Connects and checks in the way IOBluetooth does; returns once Bluetooth is on.
    ///
    /// The check-in is retried, and the retry is the whole point.
    ///
    /// Measured 2026-11-08: `bluetoothd did not answer: check-in / power state` happened on most
    /// runs and then recovered on the next attempt, with the same binary and the same arguments.
    /// The reply arrives on bluetoothd's schedule, and five seconds is not always enough on a
    /// machine that has just woken up a daemon and a controller — so a single timeout used to end
    /// a stream that would have worked a second later.
    ///
    /// The retry is a *fresh connection*, not a second wait on the same one: a check-in that went
    /// unanswered has no state worth keeping, and reusing the connection is how a half-open one
    /// turns into a stream that fails with a different error every time.
    public func start(timeout: TimeInterval = 5, attempts: Int = 3) async throws {
        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            onQueue { openConnection() }
            do {
                try await waitReady(timeout: timeout)
                return
            } catch {
                lastError = error
                // A silent radio is worth asking again; a radio that said "off" is not.
                let off = onQueue { powerOff }
                invalidate()
                guard attempt < attempts, !off else { break }
                // Half a second between attempts: long enough for bluetoothd to finish whatever it
                // was doing, short enough that a stream started by hand does not look hung.
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError ?? ClassicXPCError.timeout("check-in / power state")
    }

    public func invalidate() {
        onQueue {
            if let connection { xpc_connection_cancel(connection) }
            connection = nil
            fail(.connectionLost("invalidated"))
        }
    }

    private func openConnection() {
        guard connection == nil else { return }
        // A fresh connection is a fresh start: the failure that ended the previous one belongs to
        // it, and keeping it would make the retry above fail instantly with the old error.
        failure = nil
        ready = false
        let connection = xpc_connection_create_mach_service(
            serviceOverride ?? proto.serviceName, queue, 0)
        xpc_connection_set_event_handler(connection) { [weak self] event in self?.handle(event) }
        xpc_connection_resume(connection)
        self.connection = connection

        let options = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(options, XPCKey.isPrivilegedDaemon, 1)
        let args = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(args, XPCKey.version, proto.checkInVersion)
        xpc_dictionary_set_value(args, XPCKey.options, options)
        xpc_dictionary_set_int64(args, XPCKey.type, proto.checkInType)
        xpc_dictionary_set_string(args, XPCKey.name, Bundle.main.bundleIdentifier ?? "codecblue")
        send(proto.checkIn, args)
        // IOBluetooth follows check-in with message 10 and a message 12 that expects a
        // reply. Only then does bluetoothd push the power state (observed).
        send(proto.afterCheckIn, xpc_dictionary_create(nil, nil, 0))
        let query = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(query, XPCKey.messageID, proto.retrievePairedDevices)
        xpc_connection_send_message_with_reply(connection, query, queue) { _ in }
    }

    private func waitReady(timeout: TimeInterval) async throws {
        let token = UUID()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let failure { return continuation.resume(throwing: failure) }
                if ready { return continuation.resume() }
                readyWaiters[token] = continuation
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    readyWaiters.removeValue(forKey: token)?.resume(
                        throwing: ClassicXPCError.timeout("check-in / power state")
                    )
                }
            }
        }
    }

    // MARK: - Requests

    public func lookup(address: String, timeout: TimeInterval = 3) async throws -> DeviceRecord {
        let args = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(args, XPCKey.addressString, address.lowercased())
        let reply = try await request(proto.retrievePeerWithAddress, args, timeout: timeout)
        guard let record = xpc_dictionary_get_value(reply, XPCKey.devices),
            xpc_get_type(record) == XPC_TYPE_DICTIONARY
        else {
            throw ClassicXPCError.unknownDevice(address)
        }
        guard let bytes = xpc_dictionary_get_uuid(record, XPCKey.deviceUUID) else {
            throw ClassicXPCError.malformedReply("device record without UUID")
        }
        let uuid = NSUUID(uuidBytes: bytes) as UUID
        var services: [(UInt16, UInt8)] = []
        if let list = xpc_dictionary_get_value(record, XPCKey.services),
            xpc_get_type(list) == XPC_TYPE_ARRAY
        {
            xpc_array_apply(list) { _, service in
                guard xpc_get_type(service) == XPC_TYPE_DICTIONARY else { return true }
                var length = 0
                if let raw = xpc_dictionary_get_data(service, XPCKey.serviceUUID, &length),
                    length == 2
                {
                    let bytes = raw.assumingMemoryBound(to: UInt8.self)
                    let rfcomm = xpc_dictionary_get_int64(service, XPCKey.rfcommChannelID)
                    services.append(
                        (
                            UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
                            (1...30).contains(rfcomm) ? UInt8(rfcomm) : 0
                        ))
                }
                return true
            }
        }
        return DeviceRecord(
            uuid: uuid,
            linkState: xpc_dictionary_get_int64(record, XPCKey.internalState),
            services: services
        )
    }

    /// Asks bluetoothd to connect the device (it then connects its usual profiles).
    ///
    /// `lowLatency` asks for the link to stay out of sniff mode: bluetoothd then keeps it
    /// active (`setLinkMode`) and raises the ACL priority. Without it the controller puts the
    /// link to sleep between packets, and a media packet per sniff interval is all the
    /// throughput there is (measured: ~100-140 ms round trip, ~40 kbps).
    public func connect(_ device: UUID, lowLatency: Bool = false) {
        let services = xpc_array_create(nil, 0)
        xpc_array_set_int64(services, XPC_ARRAY_APPEND, proto.connectServices)
        let options = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(options, XPCKey.servicesOption, services)
        if lowLatency {
            xpc_dictionary_set_int64(options, XPCKey.requiresLowLatency, 1)
            xpc_dictionary_set_int64(options, XPCKey.latencyCritical, 1)
            xpc_dictionary_set_int64(options, XPCKey.maxAllowedConnectionDelay, 0)
        }
        let args = deviceArgs(device)
        xpc_dictionary_set_value(args, XPCKey.options, options)
        queue.async { [self] in send(proto.connectPeer, args) }
    }

    /// Disconnects the device. `force` drops all of macOS's services on it, as IOBluetooth's
    /// closeConnection does.
    public func cancelConnection(_ device: UUID, force: Bool = true) {
        let options = xpc_dictionary_create(nil, nil, 0)
        if force { xpc_dictionary_set_int64(options, XPCKey.forceOption, 1) }
        let args = deviceArgs(device)
        xpc_dictionary_set_value(args, XPCKey.options, options)
        queue.async { [self] in send(proto.cancelPeerConnection, args) }
    }

    /// Asks bluetoothd to raise the ACL priority of the link (`aclPriority`). This is the
    /// signal that makes the controller keep the link out of sniff mode, which is what caps
    /// our media throughput at ~40-110 kbps. Returns false when the message number for this
    /// macOS release is not known.
    @discardableResult
    public func setACLHighPriority(_ device: UUID, priority: Int64 = 1) -> Bool {
        guard let id = proto.setACLHighPriority else { return false }
        let args = deviceArgs(device)
        xpc_dictionary_set_int64(args, XPCKey.aclPriority, priority)
        queue.async { [self] in send(id, args) }
        return true
    }

    /// Sends a raw message with a device UUID and no reply, for probing which message number
    /// bluetoothd maps to which handler. bluetoothd logs the handler's name when it receives
    /// the message, so the log is the answer; a UUID that matches no device keeps the probe
    /// harmless (every handler fails with "device not found").
    public func probe(_ id: Int64, device: UUID) {
        let args = deviceArgs(device)
        xpc_dictionary_set_int64(args, XPCKey.aclPriority, 1)
        queue.async { [self] in send(id, args) }
    }

    /// Opens an L2CAP channel. bluetoothd allows one request per session and device at a
    /// time; a second one is refused with 1803.
    public func openChannel(
        _ device: UUID, psm: UInt16, priority: Int64 = 0, timeout: TimeInterval = 5
    ) async throws -> OpenedChannel {
        let args = deviceArgs(device)
        xpc_dictionary_set_int64(args, XPCKey.psm, Int64(psm))
        let options = xpc_dictionary_create(nil, nil, 0)
        if priority != 0 { xpc_dictionary_set_int64(options, XPCKey.channelPriority, priority) }
        xpc_dictionary_set_value(args, XPCKey.options, options)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let failure { return continuation.resume(throwing: failure) }
                guard openWaiters[psm] == nil else {
                    return continuation.resume(
                        throwing: ClassicXPCError.refused(ChannelResult.alreadyConnected))
                }
                openWaiters[psm] = continuation
                send(proto.openChannel, args)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    openWaiters.removeValue(forKey: psm)?.resume(
                        throwing: ClassicXPCError.timeout("open PSM 0x\(String(psm, radix: 16))")
                    )
                }
            }
        }
    }

    /// Opens an RFCOMM channel (e.g. the headphones' hands-free service). The reply carries
    /// a socket like L2CAP; result 913 means macOS already holds the channel.
    public func openRFCOMM(_ device: UUID, channel: UInt8, timeout: TimeInterval = 5) async throws
        -> OpenedChannel
    {
        let args = deviceArgs(device)
        xpc_dictionary_set_int64(args, XPCKey.rfcommChannelID, Int64(channel))
        xpc_dictionary_set_value(args, XPCKey.options, xpc_dictionary_create(nil, nil, 0))
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let failure { return continuation.resume(throwing: failure) }
                guard rfcommWaiters[channel] == nil else {
                    return continuation.resume(
                        throwing: ClassicXPCError.refused(ChannelResult.alreadyConnected))
                }
                rfcommWaiters[channel] = continuation
                send(proto.openRFCOMM, args)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    rfcommWaiters.removeValue(forKey: channel)?.resume(
                        throwing: ClassicXPCError.timeout("open RFCOMM \(channel)")
                    )
                }
            }
        }
    }

    public func closeRFCOMM(_ device: UUID, channel: UInt8) {
        let args = deviceArgs(device)
        xpc_dictionary_set_int64(args, XPCKey.rfcommChannelID, Int64(channel))
        queue.async { [self] in send(proto.closeRFCOMM, args) }
    }

    public var hasOpenInFlight: Bool { onQueue { !openWaiters.isEmpty } }

    public func closeChannel(_ device: UUID, psm: UInt16) {
        let args = deviceArgs(device)
        xpc_dictionary_set_int64(args, XPCKey.psm, Int64(psm))
        queue.async { [self] in send(proto.closeChannel, args) }
    }

    // MARK: - Plumbing

    private func deviceArgs(_ device: UUID) -> xpc_object_t {
        let args = xpc_dictionary_create(nil, nil, 0)
        withUnsafeBytes(of: device.uuid) { raw in
            xpc_dictionary_set_uuid(
                args, XPCKey.deviceUUID, raw.bindMemory(to: UInt8.self).baseAddress!)
        }
        return args
    }

    /// Must run on `queue`.
    private func send(_ id: Int64, _ args: xpc_object_t?) {
        guard let connection else { return }  // sending on a dead connection would trap
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(message, XPCKey.messageID, id)
        if let args { xpc_dictionary_set_value(message, XPCKey.arguments, args) }
        xpc_connection_send_message(connection, message)
    }

    private func request(_ id: Int64, _ args: xpc_object_t, timeout: TimeInterval) async throws
        -> xpc_object_t
    {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(message, XPCKey.messageID, id)
        xpc_dictionary_set_value(message, XPCKey.arguments, args)
        let box = ReplyBox()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let failure { return continuation.resume(throwing: failure) }
                guard let connection else {
                    return continuation.resume(throwing: ClassicXPCError.notReady)
                }
                box.continuation = continuation
                xpc_connection_send_message_with_reply(connection, message, queue) { reply in
                    if xpc_get_type(reply) == XPC_TYPE_ERROR {
                        box.finish(throwing: ClassicXPCError.connectionLost(Self.describe(reply)))
                    } else {
                        box.finish(returning: reply)
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    box.finish(throwing: ClassicXPCError.timeout("message \(id)"))
                }
            }
        }
    }

    private func handle(_ event: xpc_object_t) {
        if xpc_get_type(event) == XPC_TYPE_ERROR {
            fail(.connectionLost(Self.describe(event)))
            return
        }
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return }
        let id = xpc_dictionary_get_int64(event, XPCKey.messageID)
        let args = xpc_dictionary_get_value(event, XPCKey.arguments)
        switch id {
        case proto.stateChanged:
            guard let args else { return }
            let state = xpc_dictionary_get_int64(args, XPCKey.state)
            let on = state == proto.statePoweredOn
            if on && !ready {
                ready = true
                powerOff = false
                for waiter in readyWaiters.values { waiter.resume() }
                readyWaiters.removeAll()
            } else if !on {
                // Only a *settled* "off" ends the wait. `stateChanged` also carries the transient
                // states of a radio that is turning on (and of one that is turning off), and
                // treating any of them as "off" made the stream exit with `Bluetooth is switched
                // off` on a machine whose Bluetooth was on and whose headphones were connected —
                // measured 2026-11-08, twice, on the first run after a rebuild. The transient
                // values are not documented anywhere reliable, so the rule is the conservative
                // one: only the value that means "powered off" fails, everything else waits for
                // the timeout it was always going to wait for.
                let settledOff = state == proto.statePoweredOff
                if settledOff { powerOff = true }
                if ready { ready = false }
                guard settledOff else { return }
                for waiter in readyWaiters.values {
                    waiter.resume(throwing: ClassicXPCError.powerOff)
                }
                readyWaiters.removeAll()
            }
            onPowerChanged?(on)
        case proto.channelConnected:
            guard let args else { return }
            let psm = UInt16(truncatingIfNeeded: xpc_dictionary_get_int64(args, XPCKey.psm))
            let result = Int(xpc_dictionary_get_int64(args, XPCKey.result))
            let fd = result == 0 ? xpc_dictionary_dup_fd(args, XPCKey.socket) : -1
            guard let waiter = openWaiters.removeValue(forKey: psm) else {
                if fd >= 0 { close(fd) }  // nobody waits any more (timed out): do not leak it
                return
            }
            if result == 0 && fd >= 0 {
                waiter.resume(
                    returning: OpenedChannel(
                        fd: fd,
                        cid: UInt16(truncatingIfNeeded: xpc_dictionary_get_int64(args, XPCKey.cid)),
                        outMTU: UInt16(
                            truncatingIfNeeded: xpc_dictionary_get_int64(args, XPCKey.outMTU))
                    ))
            } else {
                waiter.resume(throwing: ClassicXPCError.refused(result))
            }
        case proto.rfcommOpened:
            guard let args else { return }
            let channel = UInt8(
                truncatingIfNeeded: xpc_dictionary_get_int64(args, XPCKey.rfcommChannelID))
            let result = Int(xpc_dictionary_get_int64(args, XPCKey.result))
            let fd = result == 0 ? xpc_dictionary_dup_fd(args, XPCKey.socket) : -1
            guard let waiter = rfcommWaiters.removeValue(forKey: channel) else {
                if fd >= 0 { close(fd) }
                return
            }
            if result == 0 && fd >= 0 {
                waiter.resume(
                    returning: OpenedChannel(
                        fd: fd, cid: 0,
                        outMTU: UInt16(
                            truncatingIfNeeded: xpc_dictionary_get_int64(args, XPCKey.mtu))
                    ))
            } else {
                waiter.resume(throwing: ClassicXPCError.refused(result))
            }
        case proto.channelDisconnected:
            guard let args else { return }
            onChannelClosed?(
                UInt16(truncatingIfNeeded: xpc_dictionary_get_int64(args, XPCKey.psm)),
                Int(xpc_dictionary_get_int64(args, XPCKey.result))
            )
        default:
            break
        }
    }

    /// Must run on `queue`. Fails everything pending; later requests fail at once.
    private func fail(_ error: ClassicXPCError) {
        if failure == nil { failure = error }
        ready = false
        for waiter in readyWaiters.values { waiter.resume(throwing: error) }
        readyWaiters.removeAll()
        for waiter in openWaiters.values { waiter.resume(throwing: error) }
        openWaiters.removeAll()
        for waiter in rfcommWaiters.values { waiter.resume(throwing: error) }
        rfcommWaiters.removeAll()
    }

    private static func describe(_ object: xpc_object_t) -> String {
        let raw = xpc_copy_description(object)
        defer { free(raw) }
        return String(cString: raw)
    }
}

/// Resumes a continuation exactly once, whichever of reply or timeout comes first.
private final class ReplyBox: @unchecked Sendable {
    var continuation: CheckedContinuation<xpc_object_t, Error>?
    private let lock = NSLock()

    func finish(returning value: xpc_object_t) {
        take()?.resume(returning: value)
    }

    func finish(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<xpc_object_t, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}
