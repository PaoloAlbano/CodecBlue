import Foundation

/// bluetoothd's own UUID for a device, as it prints it in its log:
///
///     CBDevice 4379D275-655C-EEB8-BB72-643BF2534BE0, BDA <private>, … CnS 0x800019 < HFP AVRCP A2DP >
///
/// It is not the IOBluetooth UUID and not the CoreAudio UID: the audio channel of bluetoothd
/// matches on this one, and with the wrong value it answers `No device found for uid …` and
/// silently does nothing.
///
/// The address is redacted (`BDA <private>`) in the log, so the device is identified by the
/// services it advertises: a classic device with A2DP. When more than one such device is around,
/// `preferring` narrows it by the name bluetoothd printed.
public enum CBDeviceUUID {
    /// How far back to read.
    ///
    /// `log show` costs ~1.1 s on this Mac whatever the window (`--last 30s` and `--last 30m` are
    /// the same: the price is the process and the archive, not the lines), so the window is chosen
    /// for what it must contain and not for its cost. Five minutes covers a pair of headphones that
    /// connected a moment ago, which is the case a stream cares about.
    public static let defaultWindow = "5m"

    /// Both answers, from **one** read of the log.
    ///
    /// They used to be two functions, and the caller wrote `findRegistered(for:) ?? find(for:)`:
    /// two `log show` runs of 1.1 s each, back to back, on the path that starts a stream — 2.2 s of
    /// silence before the takeover even begins, for one line of log. Measured 2026-11-08.
    public struct Answer: Sendable, Equatable {
        /// The UUID of the audio device bluetoothd has registered for this address, if it has one.
        /// This is the true answer: it is bluetoothd saying "I have a device for these headphones".
        public let registered: String?
        /// The last `CBDevice … A2DP` UUID in the window, whatever it belongs to. A fallback for
        /// the moment before bluetoothd has published a device.
        public let anyA2DP: String?
        /// What to use: the registered one, or the fallback.
        public var best: String? { registered ?? anyA2DP }
    }

    public static func resolve(
        for address: String, preferring name: String? = nil,
        window: String = defaultWindow
    ) -> Answer {
        guard let text = BluetoothLog.text(window: window) else {
            return Answer(registered: nil, anyA2DP: nil)
        }
        return parse(text, address: address, preferring: name)
    }

    /// The fallback alone, for the diagnostics that only want it.
    public static func find(
        for address: String, preferring name: String? = nil,
        window: String = defaultWindow
    ) -> String? {
        resolve(for: address, preferring: name, window: window).anyA2DP
    }

    /// The registered device alone, for the diagnostics that only want it.
    public static func findRegistered(for address: String, window: String = defaultWindow)
        -> String?
    {
        resolve(for: address, window: window).registered
    }

    /// The rule, exposed for the self-test: the log lines are the only input.
    public static func parse(
        _ text: String, address: String,
        preferring name: String? = nil
    ) -> Answer {
        var lastA2DP: String?
        /// The UUID in force at the moment of the last registration: the `CBDevice` line for a
        /// pair of headphones is printed when it connects or is found, which can be minutes before
        /// or after the audio device is registered, so the nearest one is the best guess and the
        /// one at registration is the best of all.
        var atRegistration: String?
        var registered = false
        for line in text.split(separator: "\n") {
            // Only a classic device with A2DP can be the headphones. bluetoothd prints a
            // `CBDevice` line for every phone that advertises nearby — measured 2026-11-08:
            // eleven in thirty minutes, none of them ours — and without this filter "the last
            // CBDevice line" is whichever phone happened to advertise last.
            if line.contains("A2DP"), let found = uuid(in: line) { lastA2DP = found }
            guard line.contains(address) else { continue }
            if line.contains("Register audio device") {
                registered = true
                atRegistration = lastA2DP
            }
            if line.contains("Erased") && line.contains("audio device") { registered = false }
        }
        // `preferring` narrows the fallback by name, and only the fallback: the registered device
        // is identified by the address, which is stronger evidence than a name in a redacted log.
        var fallback = lastA2DP
        if let name {
            for line in text.split(separator: "\n") where line.contains(name) {
                if line.contains("A2DP"), let found = uuid(in: line) { fallback = found }
            }
        }
        return Answer(
            registered: registered ? (atRegistration ?? lastA2DP) : nil,
            anyA2DP: fallback)
    }
}

/// bluetoothd's log, read as text.
///
/// One place, because the cost is the process and not the lines: `log show` takes ~1.1 s on this
/// Mac whatever the window (`--last 30s` and `--last 30m` are the same), so every caller has to
/// think about *when* it reads rather than how much. Two callers had already grown their own copy
/// of this before it was extracted, which is how one of them came to run it twice in a row.
public enum BluetoothLog {
    /// The whole log for a window, or nil if `log` could not be run.
    ///
    /// The predicate is `process == "bluetoothd"` and nothing narrower: the address is redacted in
    /// the lines that matter (`BDA <private>`), so filtering on it would drop the very line the
    /// answer is in. The filtering happens in the parsers.
    public static func text(window: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", window, "--predicate", "process == \"bluetoothd\"",
            "--style", "compact",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

extension CBDeviceUUID {
    /// The UUID of a `CBDevice …` line, or nil if the line does not carry one.
    static func uuid(in line: Substring) -> String? {
        guard line.contains("CBDevice "), let range = line.range(of: "CBDevice ") else {
            return nil
        }
        let candidate = String(line[range.upperBound...].prefix(36))
        guard candidate.count == 36, candidate.filter({ $0 == "-" }).count == 4 else { return nil }
        return candidate
    }
}
