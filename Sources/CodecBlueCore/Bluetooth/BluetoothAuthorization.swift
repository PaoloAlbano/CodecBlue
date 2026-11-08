import CoreBluetooth
import Foundation

/// Asks macOS for the Bluetooth permission, so that bluetoothd will talk to us at all.
///
/// This exists because of a failure that took an afternoon to see and one line to fix.
///
/// `codecblue` does not use CoreBluetooth: it talks to bluetoothd over the *classic* XPC channel,
/// the one IOBluetooth uses, and takes the headphones' link over from there. That channel is
/// subject to the Bluetooth permission (TCC, `kTCCServiceBluetoothAlways`) exactly like
/// CoreBluetooth is — but nothing in it ever asks for that permission. Only CoreBluetooth asks.
///
/// So the permission was granted to whatever asked: launching from a terminal, macOS asked on
/// behalf of the terminal, and it worked. Launched by launchd — which is how the menu bar app
/// keeps the stream alive — nobody asks, bluetoothd finds no approval, and answers
///
///     TCC approval status for session <private>: 1
///     Sending 'state updated' event with state "Unsupported"
///
/// "Unsupported" reads as "this Mac has no Bluetooth", and the stream died in a restart loop with
/// `bluetoothd did not answer: check-in / power state`. Measured 2026-11-08: the same binary, same
/// arguments, worked from a terminal (`status: 2`, state "On") and failed under launchd
/// (`status: 1`, state "Unsupported") — four times out of four, in both directions.
///
/// The fix is to make the asking happen from inside this process, so the permission is granted to
/// `codecblue` and not to whatever launched it: create a `CBCentralManager`, which triggers the
/// prompt, and wait for it to reach *any* settled state before touching the classic channel.
/// Creating it is the whole point — the manager is not used for anything afterwards.
///
/// Verified: under launchd, with this warm-up, `state "On"` and the stream starts.
public final class BluetoothAuthorization: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private var manager: CBCentralManager?
    private let ready = DispatchSemaphore(value: 0)
    private var settled = false

    /// How long to wait for CoreBluetooth to settle.
    ///
    /// Short on purpose, and it does not need to be long: the authorisation is requested when the
    /// manager is *created*, not when the delegate answers. Measured 2026-11-08 under launchd: the
    /// delegate never fires at all — a bare binary has no run loop for the main queue to spin —
    /// yet bluetoothd's `TCC approval status` goes from 1 to 2 and the classic channel works.
    /// Waiting for the callback would have meant waiting forever for something not required.
    public static let timeout: TimeInterval = 2

    /// Creates the manager and waits for the permission to be resolved.
    ///
    /// - Returns: the state CoreBluetooth settled on, for the log. `nil` means it never answered.
    @discardableResult
    public static func request(log: (String) -> Void) -> CBManagerState? {
        let authorization = BluetoothAuthorization()
        return authorization.run(log: log)
    }

    private func run(log: (String) -> Void) -> CBManagerState? {
        // `.main` is not used: the caller is inside an async task, and a delegate on the main
        // queue would wait for a run loop that is busy elsewhere.
        manager = CBCentralManager(delegate: self, queue: nil)
        let waited = ready.wait(timeout: .now() + Self.timeout)
        guard waited == .success else {
            // Not a failure. The request has been made; the answer arrives whenever it arrives,
            // and macOS remembers it. Saying so is still worth a line, because "no answer" and
            // "refused" look identical from the outside and only one of them is a problem.
            log("bluetooth permission: asked (CoreBluetooth has not answered yet; carrying on)")
            manager = nil
            return nil
        }
        let state = manager?.state ?? .unknown
        switch state {
        case .poweredOn:
            log("bluetooth permission: granted")
        case .unauthorized:
            log(
                "bluetooth permission: REFUSED. Grant it in System Settings > Privacy & Security > "
                    + "Bluetooth, or the stream cannot take the link over.")
        case .unsupported:
            log("bluetooth permission: this Mac reports no Bluetooth")
        case .poweredOff:
            log("bluetooth permission: Bluetooth is switched off")
        default:
            log("bluetooth permission: state \(state.rawValue)")
        }
        manager = nil
        return state
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Every state is settled except `.unknown` and `.resetting`, which are the two that mean
        // "ask again in a moment". Waiting for `.poweredOn` specifically would hang on a Mac with
        // Bluetooth off, which is not this function's business.
        guard central.state != .unknown, central.state != .resetting else { return }
        guard !settled else { return }
        settled = true
        ready.signal()
    }
}
