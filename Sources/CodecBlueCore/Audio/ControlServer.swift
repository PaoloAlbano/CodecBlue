import Foundation

/// A one-line command channel to a stream that is already running.
///
/// It exists because the settings that matter are the ones you want to change *while listening*:
/// the quality level, the cushion. Before this, changing either meant stopping the stream,
/// editing a command line and starting again — a gap of several seconds, and the whole point of
/// the exercise is that the audio keeps playing.
///
/// A unix socket in `/tmp`, not a distributed notification or an XPC service: the stream is an
/// ordinary foreground process, and a socket is the smallest thing that lets another ordinary
/// process talk to it. No daemon, no launchd registration, no code signing.
///
/// Protocol: one line in, one line out, then the connection closes.
///
///     status              → key=value pairs, one per line, then "end"
///     quality HQ|SQ|MQ    → ok quality=HQ   (or error=...)
///     adapt on|off        → ok adapt=on
///     quit                → ok quitting, and the stream stops
///
/// It is deliberately textual: a person can talk to it with `nc -U`, and a bug in the client
/// cannot corrupt the stream's state.
public final class ControlServer: @unchecked Sendable {
    /// Where the socket lives. A fixed path, because the client has to find it without being
    /// told: `/tmp` is per-machine and cleared on reboot, which is exactly the lifetime wanted.
    public static let defaultPath = "/tmp/codecblue-control"

    public struct Command: Sendable {
        public let name: String
        public let argument: String?
    }

    private let path: String
    private let queue = DispatchQueue(label: "codecblue.control")
    private var descriptor: Int32 = -1
    private let lock = NSLock()
    /// Answers a command. Returns the reply lines; an empty array means "nothing to say".
    private let handler: @Sendable (Command) -> [String]

    public init(path: String = ControlServer.defaultPath,
                handler: @escaping @Sendable (Command) -> [String]) {
        self.path = path
        self.handler = handler
    }

    /// Binds and starts accepting. Returns false if the socket cannot be created, which is not
    /// fatal: the stream works without a control channel, it just cannot be steered.
    @discardableResult
    public func start() -> Bool {
        // A socket left behind by a process that was killed: unlink it, or bind fails with
        // EADDRINUSE forever and the only fix is a reboot.
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return false
        }
        // Only the user who started the stream may steer it: the socket is in /tmp, which
        // everyone can write to.
        chmod(path, 0o600)
        lock.lock()
        descriptor = fd
        lock.unlock()
        queue.async { [weak self] in self?.acceptLoop() }
        return true
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = descriptor
            lock.unlock()
            guard fd >= 0 else { return }
            // `accept` is also the name of this type's own method, so the C function needs its
            // module spelled out.
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else {
                // EINTR is not a reason to stop listening.
                if errno == EINTR { continue }
                return
            }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = Command(name: parts.first?.lowercased() ?? "",
                              argument: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil)
        let reply = handler(command)
        guard !reply.isEmpty else { return }
        let out = reply.joined(separator: "\n") + "\n"
        _ = out.withCString { write(client, $0, strlen($0)) }
    }

    public func stop() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    deinit { stop() }
}

/// The client side, used by the `codecblue status` / `codecblue quality` commands.
public enum ControlClient {
    /// Sends one line and returns everything the server said, or nil if nothing is listening.
    ///
    /// nil is not an error worth a stack trace: it means no stream is running, which is the
    /// normal state of the machine most of the time.
    public static func send(_ line: String, path: String = ControlServer.defaultPath) -> [String]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return nil }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        var reply = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: reply, as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }
}
