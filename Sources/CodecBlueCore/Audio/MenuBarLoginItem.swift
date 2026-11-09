import Foundation

/// Starts the menu bar icon at login, so that "the icon is gone" stops being a thing that happens.
///
/// Why it is needed: the icon is the only way to start a stream, and it is an ordinary app — it
/// runs until it is quit, and nothing brings it back. Measured 2026-11-09: the icon was missing
/// while the audio device was still in the output list, and the two facts look like a contradiction
/// until you know they are three separate things (the driver publishes the device, the agent feeds
/// it, the icon is a remote control). The device being there with no icon is the normal state after
/// a reboot; the icon coming back by itself is the fix.
///
/// A LaunchAgent that runs `open`, not `SMAppService`: `SMAppService.mainApp` needs the bundle to be
/// where the system expects it and to be signed in a way this project cannot do without an Apple
/// Developer account, and its failures are silent. A plist that runs `open -a` is the same
/// mechanism the stream's own agent uses, it can be read and edited by hand, and `open` on an
/// already-running app does nothing — which is exactly the behaviour wanted at login.
public enum MenuBarLoginItem {
    public static let label = "com.codecblue.menu"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The app bundle this process is running from.
    ///
    /// `Bundle.main.bundleURL` is the `.app` itself when running from one, which is the only case
    /// that matters: a menu bar app launched from a terminal would register the terminal's idea of
    /// where it lives, and the next login would find nothing.
    public static var appURL: URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        return bundle
    }

    public static func plist(appPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(LaunchAgent.escape(appPath))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>

        """
    }

    /// Writes and loads the item. Idempotent: installing twice is the same as installing once.
    public static func install() throws {
        guard let app = appURL else { throw LoginItemError.notInAnApp }
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist(appPath: app.path).write(to: plistURL, atomically: true, encoding: .utf8)
        // `load` on an already-loaded label is a no-op, so the unload is what makes a reinstall
        // take effect — the same reason `LaunchAgent.load` does it.
        LaunchAgent.unloadMenuBarItem()
        let status = LaunchAgent.runLaunchctl(["load", plistURL.path])
        guard status == 0 else { throw LoginItemError.launchctlFailed(status) }
    }

    public static func remove() {
        LaunchAgent.unloadMenuBarItem()
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Whether the item is installed *and* loaded. Two questions, and the answer to the second is
    /// the one that matters: a plist on disk that launchd has not read does nothing at login.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public enum LoginItemError: Error, LocalizedError {
        case notInAnApp
        case launchctlFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .notInAnApp:
                "CodecBlue is not running from an application bundle, so there is nothing to start "
                    + "at login"
            case .launchctlFailed(let status):
                "launchctl refused the login item (exit \(status))"
            }
        }
    }
}
