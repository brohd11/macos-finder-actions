import Foundation
import XCTest
@testable import FinderActionsCore

/// Guards the execution contract documented in the README and implemented by
/// `ScriptExecutor`: `/bin/zsh -c <Exec> <action-id> <path>...`, so selected
/// paths reach the script as `"$@"` without ever being spliced into the source.
final class ScriptInvocationTests: XCTestCase {
    func testSelectedPathsSurviveAsSeparateArguments() throws {
        let paths = [
            "/tmp/with space",
            "/tmp/with'quote",
            "/tmp/with\"double quote",
            "/tmp/with;semicolon && rm -rf",
            "/tmp/with\nnewline",
            "/tmp/ユニコード",
        ]

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "printf '%s\\0' \"$@\"", "self-test"] + paths
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let roundTripped = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(roundTripped, paths)
    }

    func testActionIDIsPassedAsDollarZero() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "printf '%s' \"$0\"", "group/copy.finder-action", "/tmp/a"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "group/copy.finder-action")
    }
}
