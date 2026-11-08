// A tiny test harness. Neither XCTest nor Swift Testing is usable with the Command Line
// Tools alone (XCTest is missing; Swift Testing needs macro plugins that ship with Xcode),
// so unit tests are plain functions run by this executable: `swift run codecblue-selftest`.
import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func check(
    _ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #fileID, line: UInt = #line
) {
    checks += 1
    if !condition() {
        failures += 1
        print("  ✘ \(currentTest) \(file):\(line) \(message())")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    let before = failures
    do { try body() } catch {
        failures += 1
        print("  ✘ \(name) threw \(error)")
    }
    print(failures == before ? "  ✔ \(name)" : "  ✘ \(name)")
}
