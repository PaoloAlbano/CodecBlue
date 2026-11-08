import Foundation

/// The LaunchAgent that starts `codecblue system` at login.
///
/// Written as a real file the user installs, not as something this program does behind their
/// back: a LaunchAgent runs outside any terminal, so its failures have nowhere to be seen. The
/// plist therefore logs to a file, and `codecblue start` says where that file is.
///
/// The reason it exists at all: without it, the audio device "CodecBlue" is present and selected
/// but nothing is feeding it, so every app plays into silence and nothing says why. That cost
/// real time once already.
public enum LaunchAgentError: Error, LocalizedError {
    case launchctlFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .launchctlFailed(status):
            return "launchctl refused to load the agent (exit \(status))"
        }
    }
}

public enum LaunchAgent {
    public static let label = "com.codecblue.system"
    public static let logPath = "/tmp/codecblue-agent.log"

    /// Where launchd looks for per-user agents.
    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The plist for a given executable and headphone address.
    ///
    /// `KeepAlive` is on: the streamer exits when the headphones disconnect, and coming back when
    /// they return is the whole point of running at login. `ThrottleInterval` keeps a crash loop
    /// from spinning: five seconds between attempts.
    public static func plist(executable: String, address: String,
                             arguments: [String] = []) -> String {
        let allArguments = ([executable, "system", address] + arguments)
            .map { "<string>\(escape($0))</string>" }
            .joined(separator: "\n        ")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                \(allArguments)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
        </dict>
        </plist>

        """
    }

    /// XML-escapes a value. The address has colons and the paths have slashes, none of which need
    /// escaping, but an argument could carry `&` or `<` and a plist that will not parse is a
    /// LaunchAgent that silently does nothing.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Writes the plist for a pair of headphones, replacing any previous one.
    ///
    /// The menu bar app calls this when the user picks a pair: the address lives in the plist, so
    /// choosing headphones means rewriting it. That is uglier than a preference file the stream
    /// reads, but the plist is already tested and a preferences file would mean the stream had two
    /// ways to learn its address.
    public static func install(address: String, arguments: [String] = []) throws {
        let invoked = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executable = resolveExecutable(from: invoked)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist(executable: executable, address: address, arguments: arguments)
            .write(to: plistURL, atomically: true, encoding: .utf8)
    }

    /// The stable path to the binary, not SwiftPM's internal one.
    ///
    /// `CommandLine.arguments[0]` and `Bundle.main.executableURL` both point into
    /// `.build/out/Products/Debug`, which `swift package clean` deletes: the agent would then fail
    /// at login with nothing in its log but "no such file". `.build/debug` is the symlink SwiftPM
    /// maintains. This mistake has been made once already, in the CLI, so it lives in one place.
    static func resolveExecutable(from invoked: URL) -> String {
        // The installed copy wins. `scripts/install.sh` puts the CLI in ~/Applications/CodecBlue,
        // and that copy is the one that survives `swift package clean` — pointing the agent at a
        // build directory means the agent breaks the next time anyone cleans the build.
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/CodecBlue/codecblue")
        if FileManager.default.isExecutableFile(atPath: installed.path) {
            return installed.path
        }
        var directory = invoked.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent(".build/debug/codecblue")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
            if directory.path == "/" { break }
            directory = directory.deletingLastPathComponent()
        }
        return invoked.path
    }

    /// Loads the agent, replacing one that is already loaded.
    ///
    /// `unload` first because `load` on an already-loaded label is a no-op: after rewriting the
    /// plist for a different pair of headphones, loading alone would keep the old address running.
    public static func load() throws {
        run("/bin/launchctl", ["unload", plistURL.path])
        let status = run("/bin/launchctl", ["load", plistURL.path])
        guard status == 0 else {
            throw LaunchAgentError.launchctlFailed(status)
        }
    }

    public static func unload() throws {
        run("/bin/launchctl", ["unload", plistURL.path])
    }

    /// Whether launchd currently has the agent loaded.
    public static func isLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains(label)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Whether the device is being fed right now. The driver writes into the ring; if the ring
    /// has not moved, nothing is playing into it.
    public static func isRingMoving(path: String = "/tmp/codecblue-ring") -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modified) < 2
    }
}
