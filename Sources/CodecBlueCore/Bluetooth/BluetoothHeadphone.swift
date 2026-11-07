import Foundation

/// The headphones macOS knows about, as the menu bar app needs to show them.
///
/// `system_profiler SPBluetoothDataType` is the only public way to list them: bluetoothd's XPC
/// services can be asked about one address at a time, but not enumerated, and the private
/// frameworks that would do it are exactly the ones that crash bluetoothd when touched
/// (see notes/findings §13.28).
///
/// The output is a plain-text tree with two sections, `Connected:` and `Not Connected:`, and a
/// device appears in exactly one of them. That matters: counting a `grep` over the whole file
/// says a pair of headphones is present when it is switched off, because `Not Connected` lists
/// them too. That mistake cost a whole evening once, so the parser tracks the section it is in.
public struct BluetoothHeadphone: Sendable, Equatable, Identifiable {
    public let name: String
    public let address: String
    public let isConnected: Bool
    /// `Minor Type` from system_profiler: "Headphones", "Keyboard", "Mouse", …
    public let kind: String

    public var id: String { address }

    /// Whether this is the kind of device we can stream to.
    ///
    /// LDAC is only implemented, so the honest test is "it is audio and it is not obviously
    /// something else". A headset that speaks SBC only will appear here and then fail at stream
    /// setup with a message that says so — better than hiding it and leaving the user wondering
    /// why their headphones are missing from the list.
    public var isAudio: Bool {
        let k = kind.lowercased()
        return k.contains("headphone") || k.contains("headset") || k.contains("speaker")
            || k.contains("earbud") || k.contains("airpod")
    }

    public init(name: String, address: String, isConnected: Bool, kind: String) {
        self.name = name
        self.address = address
        self.isConnected = isConnected
        self.kind = kind
    }

    /// Parses the tree `system_profiler` prints.
    ///
    /// Structure, with the indentation that matters:
    ///
    ///     Connected:
    ///         HUAWEI FreeBuds 5:
    ///             Address: 40:DC:A5:0E:14:48
    ///             Minor Type: Headphones
    ///     Not Connected:
    ///         FreeBuds 3:
    ///             Address: ...
    ///
    /// A device is a line ending in `:` at one indent level, its fields at a deeper one. The
    /// section header is the line whose text is exactly `Connected:` or `Not Connected:`.
    public static func parse(_ text: String) -> [BluetoothHeadphone] {
        var result: [BluetoothHeadphone] = []
        // The section we are in, and the indent its header sits at. Everything else in the file
        // — the `Bluetooth:` block, the `Devices (Paired, Configured, etc.):` block — is ignored,
        // because those list the same headphones again and counting them twice is exactly the
        // mistake this parser exists to avoid.
        var section: String?
        var sectionIndent = 0
        var currentName: String?
        var currentAddress: String?
        var currentKind = ""

        func flush() {
            if let name = currentName, let address = currentAddress, let section {
                result.append(BluetoothHeadphone(name: name, address: address,
                                                 isConnected: section == "Connected",
                                                 kind: currentKind))
            }
            currentName = nil
            currentAddress = nil
            currentKind = ""
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = line.prefix { $0 == " " }.count

            if trimmed == "Connected:" || trimmed == "Not Connected:" {
                flush()
                section = String(trimmed.dropLast())
                sectionIndent = indent
                continue
            }
            // Any other header at the section's own level ends the section.
            if section != nil, indent <= sectionIndent, trimmed.hasSuffix(":") {
                flush()
                section = nil
                continue
            }
            guard section != nil else { continue }

            // A device header sits one level in from the section header; its fields one deeper.
            if indent == sectionIndent + 4, trimmed.hasSuffix(":") {
                flush()
                currentName = String(trimmed.dropLast())
                continue
            }
            if trimmed.hasPrefix("Address: ") {
                currentAddress = String(trimmed.dropFirst("Address: ".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Minor Type: ") {
                currentKind = String(trimmed.dropFirst("Minor Type: ".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return result
    }

    /// Runs system_profiler and parses it. Blocking: a few hundred milliseconds.
    public static func all() -> [BluetoothHeadphone] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Only the ones we could stream to.
    public static func audioDevices() -> [BluetoothHeadphone] {
        all().filter(\.isAudio)
    }
}
