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
    ],
    targets: [
        // AOSP libldac (git submodule, unmodified). ldaclib.c and ldacBT.c are unity
        // builds that include the other sources.
        .target(
            name: "CLDAC",
            path: "third_party/libldac",
            sources: ["src/ldaclib.c", "src/ldacBT.c"],
            publicHeadersPath: "inc",
            cSettings: [.headerSearchPath("src"), .unsafeFlags(["-w"])]
        ),
        // Engine: bluetoothd channel broker, AVDTP/AVRCP, codecs, session state machine.
        .target(name: "CodecBlueCore", dependencies: ["CLDAC"]),
        // Command-line tool for probing headphones and testing codecs.
        .executableTarget(name: "codecblue", dependencies: ["CodecBlueCore"]),
        // Unit tests as an executable (XCTest/Swift Testing need Xcode): swift run codecblue-selftest
        .executableTarget(name: "codecblue-selftest", dependencies: ["CodecBlueCore"]),
    ]
)
