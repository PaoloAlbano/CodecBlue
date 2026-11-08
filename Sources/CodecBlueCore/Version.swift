import Foundation

/// The version this build calls itself.
///
/// It comes from the git tag, and it is baked into the binary at build time rather than read at run
/// time, because the two questions it answers have to be answerable on a machine that has no
/// checkout: "which release is this?" from someone reporting a bug, and "is this the build I just
/// packaged?" from the release script itself.
///
/// The mechanism is one Swift file written by `scripts/version.sh` before `swift build`:
/// `Sources/CodecBlueCore/GeneratedVersion.swift`, defining `GeneratedVersion.tag`. Generated and
/// not committed, because a committed version number is a version number that is wrong the moment
/// somebody tags — and wrong in the worst way, silently, in a shipped binary.
///
/// A build that never ran the script gets `0.0.0-development`, and the word matters: a build from a
/// checkout is not a release, and a version string that cannot say so makes every bug report
/// ambiguous.
public enum Version {
    /// The whole thing, e.g. `1.2.0`, or `1.2.0-3-gabc1234` between a tag and the next one, or
    /// `0.0.0-development` from a checkout that never ran the script.
    public static let string = GeneratedVersion.tag

    /// The commit this was built from, or empty if the build did not know it.
    public static let commit = GeneratedVersion.commit

    /// Just the release part, e.g. `1.2.0`. `0.0.0` when this is not a tagged build.
    ///
    /// This is what goes into `CFBundleShortVersionString`, which macOS wants to be a plain dotted
    /// number: a bundle claiming `1.2.0-3-gabc1234` is a bundle whose version the Finder and the
    /// update machinery cannot compare.
    public static let marketing: String = {
        let release = string.split(separator: "-").first.map(String.init) ?? string
        return release.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) != nil ? release : "0.0.0"
    }()

    /// Whether this is a build made from a tag — the only kind worth shipping.
    public static var isRelease: Bool { marketing != "0.0.0" }

    /// One line for `codecblue version` and for a bug report.
    public static var describe: String {
        if isRelease { return string }
        return commit.isEmpty ? "\(string) (no commit known)" : "\(string) (commit \(commit))"
    }
}
