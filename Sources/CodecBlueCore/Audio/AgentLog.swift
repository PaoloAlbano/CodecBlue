// Keeping the agent's log small enough to be worth reading.
//
// Measured 2026-11-14: `/tmp/codecblue-agent.log` was 10 MB and 83 238 lines after 15 hours —
// 0.67 MB/h, 16 MB a day, 80 MB in five. Nothing rotated it: `StandardOutPath` and
// `StandardErrorPath` point at the same file and launchd appends forever. On an agent whose whole
// purpose is to run for days, that is not untidiness, it is a disk that fills up and a log that
// nobody can search.
//
// Two separate problems, and they need two separate answers:
//
//   * the file grows without bound — solved by rotating before each start;
//   * most of what goes into it is noise — solved where the noise is made, not here.
//
// The second is the important one. A rotation alone would keep the file small and still leave it
// useless: 47% of those 83 238 lines were the two-second `streaming:` report, and 1 194 were the
// same "headphones are not reachable" sentence repeated while they sat in their case.

import Foundation

public enum AgentLog {
    /// How large the log may get before a start moves it aside.
    ///
    /// 5 MB is about seven hours of the *old* volume and something like three days of the new one.
    /// Small enough that `grep` is instant, large enough to hold the last few sessions — which is
    /// what a bug report needs.
    public static let rotateAbove: Int = 5 * 1024 * 1024

    /// How many old logs to keep. One: the previous session is the one worth having, and a pile of
    /// numbered files is a pile nobody reads.
    public static let keep: Int = 1

    /// Moves the log aside if it has grown past `rotateAbove`.
    ///
    /// Called before the agent is loaded, never while it runs: the process holds the file open by
    /// path through launchd, so renaming it under a running process would send its writes to a file
    /// with no name. At start there is no writer yet.
    ///
    /// - Returns: the path it moved the old log to, or nil when there was nothing to do.
    @discardableResult
    public static func rotateIfNeeded(path: String = LaunchAgent.logPath) -> String? {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int,
            size >= rotateAbove
        else { return nil }
        let previous = path + ".1"
        // Replacing the previous one, not numbering upwards: see `keep`.
        try? manager.removeItem(atPath: previous)
        do {
            try manager.moveItem(atPath: path, toPath: previous)
            return previous
        } catch {
            // A rotation that fails must not stop the stream: a large log is a nuisance, a stream
            // that will not start is the product not working.
            return nil
        }
    }

    /// The size in bytes, or 0 when there is no log yet.
    public static func size(path: String = LaunchAgent.logPath) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int
        else { return 0 }
        return size
    }
}
