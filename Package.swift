// swift-tools-version: 6.0
// CodecBlue: hi-res Bluetooth codecs (LDAC, aptX, AAC, SBC XQ) for Apple Silicon Macs.
// Builds with the Xcode Command Line Tools alone (no Xcode, no Bazel).
import PackageDescription

let package = Package(
    name: "CodecBlue",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "CodecBlueCore", targets: ["CodecBlueCore"]),
        .executable(name: "codecblue", targets: ["codecblue"]),
        // The only program that needs Accessibility permission: it posts media key events and
        // does nothing else. See Sources/codecblue-keys/main.swift for why it is separate.
        .executable(name: "codecblue-keys", targets: ["codecblue-keys"]),
        // The menu bar app. A thin client of the control channel: no audio code, no second copy
        // of the rules.
        .executable(name: "CodecBlueMenu", targets: ["CodecBlueMenu"]),
    ],
    targets: [
        // AOSP libldac (git submodule, unmodified). ldaclib.c and ldacBT.c are unity
        // builds that include the other sources.
        .target(
            name: "CLDAC",
            path: "third_party/libldac",
            // `abr/` is Sony's Adaptive Bit Rate controller, which is a separate module in the
            // upstream tree. Including it is what makes a bitrate between the three fixed levels
            // possible at all: LDAC itself has only 330 / 660 / 990 kbps at 48 kHz.
            sources: ["src/ldaclib.c", "src/ldacBT.c", "abr/src/ldacBT_abr.c"],
            publicHeadersPath: "inc",
            cSettings: [
                .headerSearchPath("src"), .headerSearchPath("abr/inc"),
                .unsafeFlags(["-w"]),
            ]
        ),
        // Engine: bluetoothd channel broker, AVDTP/AVRCP, codecs, session state machine.
        .target(name: "CodecBlueCore", dependencies: ["CLDAC"]),
        // Command-line tool for probing headphones and testing codecs.
        .executableTarget(name: "codecblue", dependencies: ["CodecBlueCore"]),
        // Media key helper. Deliberately depends on nothing of ours: it is the one binary the
        // user grants Accessibility to, so it should be the smallest thing that can do the job.
        .executableTarget(name: "codecblue-keys"),
        .executableTarget(name: "CodecBlueMenu", dependencies: ["CodecBlueCore"]),
        // Unit tests as an executable (XCTest/Swift Testing need Xcode): swift run codecblue-selftest
        .executableTarget(name: "codecblue-selftest", dependencies: ["CodecBlueCore"]),
    ]
)
