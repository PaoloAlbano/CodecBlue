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
        case .launchctlFailed(let status):
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
    public static func plist(
        executable: String, address: String,
        arguments: [String] = []
    ) -> String {
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
                <!-- How long launchd waits for the process to exit after SIGTERM before it sends
                     SIGKILL. The default is 20 seconds, and it is a trap here: a teardown that
                     hands the headphones back takes a few seconds, but a teardown that is *stuck*
                     — the link not falling, macOS not answering — would be killed mid-way, and
                     the headphones would be left taken with nothing left to give them back.
                     Measured 2026-11-09: `codecblue stop` reported "unloaded" and the log stopped
                     at "asking macOS to reconnect the headphones", with no line after it. That is
                     the signature of a SIGKILL, and the default 20 s is why the wait looked like
                     a hang. 30 gives a slow hand-back room and still bounds it. -->
                <key>ExitTimeOut</key>
                <integer>30</integer>
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

    /// The arguments that carry the listener's choices into the stream.
    ///
    /// The agent is the only way the stream is ever started in normal use, so a setting that lives
    /// only in the menu is a setting that is forgotten at the next login — and worse, at the next
    /// crash, which `KeepAlive` restarts with the command line it was loaded with. The quality and
    /// the cushion are therefore written into the plist, with the same names the command line uses.
    ///
    /// `quality` is omitted when the adapter is on: the level is then the adapter's business, and
    /// pinning one would silently turn the adapter off (see the `quality` command). When a level
    /// *is* pinned, `--no-adapt` has to go with it, or the restarted stream would start with the
    /// adapter on and climb away from the level the listener chose.
    ///
    /// Since 2026-11-08 the level is a *ceiling* and the stream settles below it when the link
    /// cannot carry it, so a pinned level no longer implies `--no-adapt`: the adapter is what
    /// makes the ceiling safe. `--no-adapt` is written only when the listener turned the adapter
    /// off on purpose.
    public static func arguments(
        quality: String?, adapt: Bool, cushionMilliseconds: Int?, capacityKbps: Int? = nil
    ) -> [String] {
        var out: [String] = []
        if let quality { out += ["--quality", quality] }
        if !adapt { out += ["--no-adapt"] }
        if let cushionMilliseconds, cushionMilliseconds > 0 {
            out += ["--queue-ms", String(cushionMilliseconds)]
        }
        // A ceiling measured once, at rest, and remembered.
        //
        // The alternative is a probe during playback, and a probe is not free: a level change makes
        // the encoder produce a different frame size, so the queued packets — both stale and the
        // wrong shape — are dropped, which is a hole of 30-60 ms, and the higher level then drops
        // 40% of the audio for a second or two before settling back. Measured 2026-11-07 and
        // 2026-11-08, and the second measurement is why the old time-expiring block was removed.
        //
        // `codecblue flood` measures the same thing with no audio at all in 15 seconds, so the
        // number can be known before the first note instead of guessed during it.
        if let capacityKbps, capacityKbps > 0 {
            out += ["--capacity", String(capacityKbps)]
        }
        return out
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

    /// Removes the plist, so nothing starts at the next login.
    ///
    /// `unload` and `remove` are two different acts and the difference matters: unloading stops the
    /// agent now, removing the file stops it from ever coming back. `codecblue stop` does the first
    /// and deliberately not the second — stopping a stream should not silently opt a person out of
    /// an arrangement they chose. But the file left behind is a loaded gun at the next login: with
    /// the headphones in their case it is a five-second retry loop for as long as the Mac is on,
    /// and every attempt used to change the system output.
    ///
    /// So this is its own verb, `codecblue login off`, and it says what it did.
    public static func remove() {
        run("/bin/launchctl", ["unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// The `--capacity` already written into the plist, or nil.
    ///
    /// Read back so that a setting the menu rewrites does not silently drop a measurement it did not
    /// choose. `rememberQuality` rebuilds the whole argument list from the values the menu holds,
    /// and the capacity is not one of them — it was measured once by `codecblue flood` and belongs
    /// to the machine, not to the menu. Without this, changing the level would erase it and the menu
    /// would go back to learning the ceiling by dropping audio, which is heard as crackle.
    public static func knownCapacityKbps() -> Int? {
        knownArgument("--capacity").flatMap(Int.init)
    }

    /// Any flag's value already written into the plist, or nil.
    ///
    /// Generalised from `knownCapacityKbps` on 2026-11-13, when the same erasure bit a second
    /// setting: `codecblue start ADDR` rebuilt the argument list from its own command line and
    /// dropped both the measured `--capacity` and the `--quality` the menu had written, so a
    /// restart silently went back to the default level and the menu showed nothing selected.
    ///
    /// A setting written into the plist is a decision somebody made. A command that did not mention
    /// it has no business discarding it.
    public static func knownArgument(_ flag: String) -> String? {
        guard let text = try? String(contentsOf: plistURL, encoding: .utf8),
            let range = text.range(of: "<string>\(flag)</string>")
        else { return nil }
        // The value is the next <string> after the flag. Parsing the XML properly would mean
        // PropertyListSerialization and a dictionary walk; the file is written by `plist(…)` in this
        // same type, so the shape is known.
        let rest = text[range.upperBound...]
        guard let open = rest.range(of: "<string>"),
            let close = rest.range(of: "</string>", range: open.upperBound..<rest.endIndex)
        else { return nil }
        return String(rest[open.upperBound..<close.lowerBound])
    }

    /// Whether the plist is on disk, which is what decides whether the next login starts us.
    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The stable path to the binary, not SwiftPM's internal one.
    ///
    /// `CommandLine.arguments[0]` and `Bundle.main.executableURL` both point into
    /// `.build/out/Products/Debug`, which `swift package clean` deletes: the agent would then fail
    /// at login with nothing in its log but "no such file". `.build/debug` is the symlink SwiftPM
    /// maintains. This mistake has been made once already, in the CLI, so it lives in one place.
    static func resolveExecutable(from invoked: URL, installed: URL? = nil) -> String {
        // The installed copy wins. `scripts/install.sh` puts the CLI in ~/Applications/CodecBlue,
        // and that copy is the one that survives `swift package clean` — pointing the agent at a
        // build directory means the agent breaks the next time anyone cleans the build.
        //
        // `installed` is a parameter and not a constant because this function has two callers with
        // two different questions. The stream asks "where is the program that will still be here at
        // the next login?", and the answer depends on this machine. The self-test asks "what does
        // the rule *do*?", and it has to be able to answer without a machine that happens to have
        // the app installed — otherwise the rule is only tested on the developer's Mac, and CI
        // fails on a test that is right about the code and wrong about the machine. Measured
        // 2026-11-08: the GitHub runner has no ~/Applications/CodecBlue, so the fallback branch ran
        // and the assertion about the installed copy could not hold.
        let installed =
            installed
            ?? FileManager.default.homeDirectoryForCurrentUser
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

    /// `launchctl` for the menu bar item, which is a different label with a different plist.
    static func unloadMenuBarItem() {
        run(
            "/bin/launchctl",
            ["unload", MenuBarLoginItem.plistURL.path])
    }

    static func runLaunchctl(_ arguments: [String]) -> Int32 {
        run("/bin/launchctl", arguments)
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
            let modified = attributes[.modificationDate] as? Date
        else {
            return false
        }
        return Date().timeIntervalSince(modified) < 2
    }
}
