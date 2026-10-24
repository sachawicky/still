import XCTest
@testable import StillKit

final class ProcessRunnerTests: XCTestCase {
    func testDrainsBothPipesBeforeTheyCanBlockChildExit() {
        let result = ProcessRunner.run("/bin/sh", ["-c", "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2"], timeout: 3)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 262144)
        XCTAssertEqual(result.stderr.utf8.count, 262144)
    }
    func testTimeoutTerminatesOwnedChildEvenWhenItIgnoresTerm() {
        let start = Date()
        let result = ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertEqual(result.stderr, "timed out")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testLaunchFailureIsReported() {
        XCTAssertEqual(ProcessRunner.run("/nonexistent/still-test", []).exitCode, -1)
    }
    func testInputIsEOFAndArgumentsAreNeverShellExpanded() {
        XCTAssertEqual(ProcessRunner.run("/bin/cat", [], timeout: 1).exitCode, 0)
        let value = "literal $(false); `false`\nsecond line"
        XCTAssertEqual(ProcessRunner.run("/usr/bin/printf", ["%s", value]).stdout, value)
    }
    func testRepeatedCommandsDoNotLoseDescriptors() {
        for index in 0..<40 {
            let result = ProcessRunner.run("/usr/bin/printf", ["%s", "run-\(index)"])
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdout, "run-\(index)")
        }
    }
}
