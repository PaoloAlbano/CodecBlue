// How long bluetoothd has been up, and what that has to do with the stream that stopped.
//
// The symptom, measured 2026-11-13: after five days of uptime, `codecblue` began failing with
// `bluetoothd did not answer: check-in / power state` while macOS still showed the headphones
// connected and playing. `sudo killall bluetoothd` fixed it instantly, and the daemon came back
// with a new pid — so the fault was in bluetoothd's state, not in ours.
//
// That is the whole diagnosis that exists. What is missing is *when* it starts: five days is one
// data point, and a single point cannot tell "after N days" from "after N takeovers" from "after
// the machine slept 40 times". So this type does the only useful thing available without a
// reproduction — it records the evidence at the moment of failure, so that the next occurrence is
// a data point instead of a memory.
//
// It deliberately does not try to *fix* anything. A `killall bluetoothd` from inside the stream
// would take down every other Bluetooth device on the machine to rescue one, and rule 4 says never
// break the user's Bluetooth. Reporting is the correct size of intervention.

import Foundation

/// bluetoothd's process facts, read from `ps` — the only interface macOS offers for "how long has
/// this daemon been running".
public struct DaemonUptime: Sendable, Equatable {
    /// Whole seconds of uptime, from `ps -o etime`.
    public let seconds: Int
    /// The pid, so two reports can be told apart.
    public let pid: Int

    public init(seconds: Int, pid: Int) {
        self.seconds = seconds
        self.pid = pid
    }

    /// "5d 4h", "3h 12m", "47s" — short, because it goes in a log line beside other things.
    public var humanAge: String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// Whether this is old enough to be the fault being investigated.
    ///
    /// Three days, chosen from one observation of five — deliberately below it, because the point
    /// is to catch the *approach* to the failure rather than the failure: a report at 3d 4h and a
    /// crash at 5d would say the daemon was already old when it started going wrong.
    public var isSuspiciouslyOld: Bool { seconds >= 3 * 86_400 }

    /// Parses `ps -o pid=,etime=` output. Format is `[[dd-]hh:]mm:ss`.
    ///
    /// Written out rather than parsed with a formatter because the shape is small and the failure
    /// mode of getting it wrong is a wrong number in a diagnostic, which is worse than no number.
    public static func parse(_ text: String) -> DaemonUptime? {
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard fields.count >= 2, let pid = Int(fields[0]) else { return nil }
        var clock = String(fields[1])
        var days = 0
        if let dash = clock.firstIndex(of: "-") {
            guard let parsed = Int(clock[clock.startIndex..<dash]) else { return nil }
            days = parsed
            clock = String(clock[clock.index(after: dash)...])
        }
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        // hh:mm:ss or mm:ss, depending on how long it has been up.
        let (hours, minutes, seconds) =
            parts.count >= 3 ? (parts[0], parts[1], parts[2]) : (0, parts[0], parts[1])
        return DaemonUptime(
            seconds: days * 86_400 + hours * 3_600 + minutes * 60 + seconds, pid: pid)
    }

    /// Reads the running bluetoothd, or nil when it cannot be found.
    ///
    /// `pgrep` first and `ps` second rather than one `ps aux | grep`: the grep form matches its own
    /// command line, which is how a diagnostic comes to report a daemon that is not there.
    public static func current() -> DaemonUptime? {
        guard let pid = pgrep("bluetoothd") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,etime=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func pgrep(_ name: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // `-x` matches the process name exactly: `pgrep bluetoothd` would also match a shell
        // running a script with that word in its arguments.
        process.arguments = ["-x", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Int(text.split(separator: "\n").first.map(String.init) ?? "")
    }
}
