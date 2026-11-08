import Foundation

/// What `scripts/version.sh` writes before a build, and what `Version` reads.
///
/// This file is the *committed* fallback: it is what a checkout gets when nobody ran the script, and
/// it says so in the string rather than pretending to be a release. `scripts/version.sh` overwrites
/// it in place, and `git` is told to ignore the change (`scripts/version.sh` restores it after the
/// build), so a tagged build and a checkout build use the same compile-time mechanism.
///
/// The alternative — reading the tag at run time — does not work: the binary has to know its own
/// version on a machine that has no git, no checkout, and no network, which is every machine that
/// runs a release.
public enum GeneratedVersion {
    /// Written by `scripts/version.sh`: the tag, or `<tag>-<n>-g<sha>` between tags, or
    /// `0.0.0-development` when the script was never run.
    public static let tag = "0.0.0-development"
    /// The short commit hash, or empty when unknown.
    public static let commit = ""
}
