import Foundation

/// AVDTP signaling over a channel socket: commands with replies matched by transaction
/// label and a timeout each, plus delivery of commands the headphones send us.
public final class SignalingChannel: @unchecked Sendable {
    public let socket: ChannelSocket
    /// Commands from the headphones (we are also an acceptor): answer them.
    public var onCommand: (@Sendable (AVDTP.Message) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var framer = AVDTPFramer()
    private var nextLabel: UInt8 = 0
    private var waiters: [UInt8: CheckedContinuation<AVDTP.Message, Error>] = [:]

    public init(socket: ChannelSocket) {
        self.socket = socket
        socket.onData = { [weak self] data in self?.receive(data) }
        socket.onClose = { [weak self] in self?.closed() }
        socket.start()
    }

    public enum SignalingError: Error, CustomStringConvertible {
        case timeout(AVDTP.Signal)
        case rejected(AVDTP.Signal, Data)
        case closed

        public var description: String {
            switch self {
            case .timeout(let s): "no answer to AVDTP \(s)"
            case .rejected(let s, let why):
                "AVDTP \(s) rejected (\(why.map { String(format: "%02x", $0) }.joined()))"
            case .closed: "signaling channel closed"
            }
        }
    }

    /// Sends a command and waits for the accept (returns it) or reject (throws).
    public func command(_ signal: AVDTP.Signal, _ payload: Data = Data(), timeout: TimeInterval = 5)
        async throws -> AVDTP.Message
    {
        let label: UInt8 = lock.withLock {
            let label = nextLabel
            nextLabel = (nextLabel + 1) & 0x0F
            return label
        }
        let reply: AVDTP.Message = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiters[label] = continuation }
            guard
                socket.send(
                    AVDTP.Message(label: label, type: .command, signal: signal, payload: payload)
                        .bytes)
            else {
                return fail(label, SignalingError.closed)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.fail(label, SignalingError.timeout(signal))
            }
        }
        if reply.type != .accept { throw SignalingError.rejected(signal, reply.payload) }
        return reply
    }

    /// Answers a command from the headphones.
    public func reply(to command: AVDTP.Message, accept: Bool, payload: Data = Data()) {
        var message = command
        message.type = accept ? .accept : .reject
        message.payload = payload
        socket.send(message.bytes)
    }

    public func close() { socket.close() }

    private func receive(_ data: Data) {
        let messages = lock.withLock { framer.feed(data) }
        for message in messages {
            if message.type == .command {
                if let onCommand {
                    onCommand(message)
                } else {
                    // 0x13 is NOT_SUPPORTED_COMMAND: the reply a sink must give to a command it
                    // does not implement, and the one the headphones expect for the ones we do not.
                    reply(to: message, accept: false, payload: Data([0x13]))
                }
                continue
            }
            let waiter = lock.withLock { waiters.removeValue(forKey: message.label) }
            waiter?.resume(returning: message)
        }
    }

    private func fail(_ label: UInt8, _ error: Error) {
        let waiter = lock.withLock { waiters.removeValue(forKey: label) }
        waiter?.resume(throwing: error)
    }

    private func closed() {
        let pending = lock.withLock {
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in pending { waiter.resume(throwing: SignalingError.closed) }
        onClose?()
    }
}
