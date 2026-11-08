import Foundation

/// Runs the media key helper and talks to it over a pipe.
///
/// The permission to post media keys belongs to a *program*, and macOS names it after whatever
/// binary asked. If `codecblue` asked, the name would be the terminal that launched it — a
/// permission far wider than this feature needs, and one people are right to refuse. So the
/// asking is done by `codecblue-keys`, which does nothing else, and this type is the pipe to it.
///
/// It is started once per stream and kept: the first press triggers the permission dialog, and
/// every press after that is instant. Starting a process per press would show the dialog again
/// (or, worse, fail quietly) on every button.
public final class MediaKeyHelper: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    /// Set when the helper says it has no permission, so the log can say so once instead of on
    /// every press.
    public private(set) var permissionDenied = false

    /// Where the helper lives, or nil if it was not built.
    ///
    /// It sits next to `codecblue` in the build directory. `Bundle.main.executableURL` is not
    /// used: it points into `.build/out/Products/Debug`, which `swift package clean` deletes and
    /// which is not where the binary actually runs from (this exact mistake broke the
    /// LaunchAgent once).
    public static func locate() -> URL? {
        // `selfURL`, not `self_`: `self` is a keyword and the underscore was the old dodge, but a
        // name that has to be explained is worse than a longer one that does not.
        let selfURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let beside = selfURL.deletingLastPathComponent().appendingPathComponent("codecblue-keys")
        if FileManager.default.isExecutableFile(atPath: beside.path) { return beside }
        return nil
    }

    /// Starts the helper, or returns nil if it is not there.
    ///
    /// - Parameter log: called with anything the helper says that is not a plain `ok`.
    public init?(log: @escaping @Sendable (String) -> Void) {
        guard let url = Self.locate() else { return nil }
        let process = Process()
        process.executableURL = url
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        self.process = process
        self.input = stdin.fileHandleForWriting
        // Read the answers on a queue of its own: the audio loop must never wait for a subprocess.
        let handle = stdout.fileHandleForReading
        DispatchQueue(label: "codecblue.media-keys").async { [weak self] in
            while let line = try? handle.read(upToCount: 4096), !line.isEmpty {
                let text = String(decoding: line, as: UTF8.self)
                    .split(separator: "\n").map(String.init)
                for answer in text {
                    if answer == "denied" {
                        self?.lock.withLock { self?.permissionDenied = true }
                        log(
                            "media keys: macOS has not granted Accessibility permission to "
                                + "codecblue-keys, so the headphones' play/pause/next do nothing. "
                                + "Grant it in System Settings > Privacy & Security > Accessibility."
                        )
                    } else if answer.hasPrefix("unknown") {
                        log("media keys: helper did not understand \(answer)")
                    } else if answer.contains("no now-playing client") {
                        // The most useful line this feature can print. A media key is routed by
                        // mediaremoted to the registered Now Playing client; with none, the key
                        // is posted and goes nowhere, silently. Measured 2026-11-08: a video
                        // playing in a browser and `nowPlayingPID=0`.
                        log(
                            "media keys: the button was read and the key posted, but macOS has no "
                                + "now-playing client to send it to, so nothing can pause. This is "
                                + "the player's decision, not ours.")
                    }
                }
            }
        }
    }

    /// Sends one command. Never blocks: a press that cannot be delivered must not stall audio.
    public func send(_ command: String) {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        input.write(Data((command + "\n").utf8))
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        input.write(Data("quit\n".utf8))
        process.terminate()
    }

    deinit { stop() }
}
