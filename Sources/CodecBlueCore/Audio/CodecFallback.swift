import CoreAudio
import Foundation

/// What to do with a pair of headphones this program cannot drive.
///
/// Asked 2026-11-09: "so when the headphones do not support LDAC, fall back to AAC on the Mac".
/// Right, and it is the only honest answer. This program implements LDAC and nothing else — SBC
/// and AAC are not written here, and writing an AAC encoder to serve a pair of earbuds would be a
/// second codec, a second packetiser and a second set of bugs for a result macOS already produces.
///
/// macOS has an AAC encoder, it has the AVDTP endpoint, and it is already paired with the
/// headphones. So the fallback is not "encode AAC ourselves": it is **step aside and let macOS do
/// it**. CodecBlue gives the link back, selects the headphones as the system output, and stops
/// pretending it is the thing playing.
///
/// The one thing that must not happen is silence. Before this, a pair with no LDAC produced: the
/// link taken, macOS forced off it, an error, and a Mac with no audio at all — strictly worse than
/// not having pressed the button. Now it produces sound, and a sentence saying who is producing it.
public enum CodecFallback {
    /// A refusal that was measured, so it can be shown without asking again.
    ///
    /// Asking costs the link: the only way to learn which codecs a pair offers is to open an AVDTP
    /// signalling channel, and opening one forces macOS off the headphones for a second. That is
    /// acceptable once, when someone presses Start; it is not acceptable every two seconds to
    /// decorate a menu. So the answer is remembered, with the time it was measured, and the menu
    /// reads the memory.
    public struct Refusal: Codable, Sendable {
        public var address: String
        public var name: String
        /// The codecs the pair actually offered, as AVDTP names them: "SBC", "AAC".
        public var offered: [String]
        public var measuredAt: Date

        /// Explicit, because the memberwise initialiser of a public struct is internal and this
        /// type is constructed from another module. Without it the compiler reports the call as
        /// "extra arguments at positions #1, #2, #3, #4", which names the symptom and not the
        /// cause: there is no initialiser to match, so it looks for another `Refusal` in scope.
        public init(address: String, name: String, offered: [String], measuredAt: Date) {
            self.address = address
            self.name = name
            self.offered = offered
            self.measuredAt = measuredAt
        }
    }

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodecBlue/refusals.json")
    }

    /// Every refusal on record, keyed by address.
    public static func all() -> [String: Refusal] {
        guard let data = try? Data(contentsOf: storeURL),
            let records = try? JSONDecoder().decode([String: Refusal].self, from: data)
        else { return [:] }
        return records
    }

    public static func refusal(for address: String) -> Refusal? {
        all()[address.uppercased()]
    }

    public static func record(_ refusal: Refusal) {
        var records = all()
        records[refusal.address.uppercased()] = refusal
        write(records)
    }

    /// Forgets a refusal, because the pair has since offered LDAC.
    ///
    /// Called when a stream actually starts: the headphones' own app can be changed between
    /// sessions, and a memory that outlived its truth would hide a working pair behind a label
    /// saying it cannot work.
    public static func clear(address: String) {
        var records = all()
        guard records.removeValue(forKey: address.uppercased()) != nil else { return }
        write(records)
    }

    private static func write(_ records: [String: Refusal]) {
        let url = storeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Hands the headphones to macOS and makes them the output, so the fallback is audible.
    ///
    /// Returns the name of the device that is now playing, or nil if macOS did not publish one.
    /// The reconnect is asked for explicitly: a takeover that failed may have left the pair
    /// disconnected, and "let macOS do it" only works if macOS actually has the link.
    @discardableResult
    public static func driveWithMacOS(
        address: String, log: @escaping @Sendable (String) -> Void
    ) async -> String? {
        // Ask bluetoothd to bring its own profiles back. `connect` is idempotent: on a link that is
        // already up it does nothing, which is the common case here.
        if let session = try? await ClassicXPCSession(label: "fallback") {
            do {
                try await session.start()
                if let device = try? await session.lookup(address: address).uuid {
                    session.connect(device)
                }
            } catch {
                log("fallback: could not ask macOS to reconnect (\(error)); trying anyway")
            }
            session.invalidate()
        }

        // Wait for coreaudiod to publish the pair's output device. It appears when macOS's own
        // AVDTP channel is up, which is what the reconnect above is for.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let uid = SystemHeadphoneAudio.devices(address: address).first(where: {
                $0.lowercased().hasSuffix(":output")
            }), let device = DefaultOutput.device(withUID: uid) {
                let name = DefaultOutput.name(of: device) ?? uid
                if DefaultOutput.set(device) {
                    log("fallback: macOS is playing to \(name) instead")
                    return name
                }
                log("fallback: macOS published \(name) but the system refused to select it")
                return nil
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log("fallback: macOS did not publish an audio device for these headphones")
        return nil
    }
}
