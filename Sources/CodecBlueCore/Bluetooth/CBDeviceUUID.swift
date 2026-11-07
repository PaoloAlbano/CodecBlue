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
    public static func find(for address: String, preferring name: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "30m", "--predicate", "process == \"bluetoothd\"",
            "--style", "compact",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text, preferring: name)
    }

    /// Exposed for the self-test: the log lines are the only input.
    public static func parse(_ text: String, preferring name: String? = nil) -> String? {
        var candidates: [String] = []
        for line in text.split(separator: "\n") {
            guard line.contains("CBDevice "), line.contains("A2DP") else { continue }
            if let name, !line.contains(name) { continue }
            guard let range = line.range(of: "CBDevice ") else { continue }
            let rest = line[range.upperBound...]
            let uuid = rest.prefix(36)
            guard uuid.count == 36, uuid.filter({ $0 == "-" }).count == 4 else { continue }
            let value = String(uuid)
            if !candidates.contains(value) { candidates.append(value) }
        }
        return candidates.last
    }
}
