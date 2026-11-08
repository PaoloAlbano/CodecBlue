import Foundation

/// The socket bluetoothd hands over for an L2CAP or RFCOMM channel.
///
/// It is a SOCK_STREAM socket: writes are not packets, so a partial write must be resumed
/// from where it stopped (resending the whole packet would corrupt the stream), and reads
/// do not preserve message boundaries (callers frame their protocol).
public final class ChannelSocket: @unchecked Sendable {
    public let outMTU: UInt16
    /// Called on the socket queue with whatever arrived.
    public var onData: (@Sendable (Data) -> Void)?
    /// Called once on the socket queue when the peer or bluetoothd closes the channel.
    public var onClose: (@Sendable () -> Void)?

    private let queue: DispatchQueue
    /// Marks `queue`, so calls made from our own callbacks (which run on it) do not
    /// dispatch_sync onto it and deadlock.
    private let onQueueKey = DispatchSpecificKey<Bool>()
    private var fd: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pending = Data()  // bytes accepted by send() but not yet written
    private var closed = false

    public init(channel: OpenedChannel, label: String) {
        fd = channel.fd
        outMTU = channel.outMTU
        queue = DispatchQueue(label: "codecblue.socket.\(label)", qos: .userInteractive)
        queue.setSpecific(key: onQueueKey, value: true)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    public func start() {
        queue.async { [self] in
            guard readSource == nil, !closed else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.resume()
            readSource = source
        }
    }

    /// Queues `data` for writing. Returns false if the channel is closed.
    @discardableResult
    public func send(_ data: Data) -> Bool {
        onQueue {
            guard !closed else { return false }
            pending.append(data)
            flush()
            return true
        }
    }

    /// Bytes waiting to be written (back-pressure signal for the media path).
    public var queuedBytes: Int { onQueue { pending.count } }

    public func close() {
        onQueue { shutdown(notify: false) }
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: onQueueKey) == true ? body() : queue.sync(execute: body)
    }

    // MARK: - Queue-confined

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !closed {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                onData?(Data(buffer[0..<count]))
                continue
            }
            if count == 0 || (errno != EAGAIN && errno != EINTR) { shutdown(notify: true) }
            return
        }
    }

    private func flush() {
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress, pending.count, 0)
            }
            if written > 0 {
                pending.removeFirst(written)
            } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                armWriteSource()
                return
            } else {
                shutdown(notify: true)
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func armWriteSource() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flush() }
        source.resume()
        writeSource = source
    }

    private func shutdown(notify: Bool) {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
        pending.removeAll()
        Darwin.close(fd)
        fd = -1
        if notify { onClose?() }
    }
}
