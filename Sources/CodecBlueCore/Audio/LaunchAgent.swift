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
