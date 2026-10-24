import XCTest
@testable import StillKit

final class SudoersSecurityTests: XCTestCase {
    private let hold = "/usr/bin/pmset -a disablesleep 1"
    private let release = "/usr/bin/pmset -a disablesleep 0"

    func testOnlyExactPasswordlessRootCommandsGrantAccess() {
        XCTAssertTrue(SudoersRule.listingGrantsHold("    (root) NOPASSWD: \(hold), \(release)"))
        XCTAssertTrue(SudoersRule.listingGrantsHold("(root) NOPASSWD: \(hold)\n(root) NOPASSWD: \(release)"))
        let macOSOutput = """
        Matching Defaults entries for user on Mac:
            env_reset, env_keep+=BLOCKSIZE, lecture_file=/etc/sudo_lecture, !log_allowed

        User user may run the following commands on Mac:
            (ALL) ALL
            (root) NOPASSWD: \(hold), /usr/bin/pmset -a
                disablesleep 0
        """
        XCTAssertTrue(SudoersRule.listingGrantsHold(macOSOutput))
        for listing in [
            "(root) NOPASSWD: /bin/true\n(root) PASSWD: \(hold), \(release)",
            "(root) NOPASSWD: \(hold)0, \(release)",
            "(root) NOPASSWD: \(hold), \(release) --extra",
            "(nobody) NOPASSWD: \(hold), \(release)",
            "(root) NOPASSWD: \(hold), \(release)\n(root) !\(hold)",
            "(root) NOPASSWD: \(hold), PASSWD: \(release)"
        ] { XCTAssertFalse(SudoersRule.listingGrantsHold(listing), listing) }
    }

    func testNumericRuleAndAppleScriptCompile() {
        XCTAssertTrue(SudoersRule.validate(rule: SudoersRule.line(userID: 501)))
        XCTAssertNil(SudoersRule.installationScript(userID: 0))
        let command = SudoersRule.installationScript(userID: 501)!
        XCTAssertEqual(ProcessRunner.run("/bin/sh", ["-n", "-c", command]).exitCode, 0)
        var error: NSDictionary?
        let script = NSAppleScript(source: SudoersRule.administratorAppleScript(command: command))!
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
        // Compile only: never execute authorization or the production root script.
    }

    func testInstallationTransactionInIsolatedFilesystem() throws {
        // Exercise the actual transaction with real visudo, replacing only the
        // root boundary/ownership and /private/etc. No system file is modified.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("still-security-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sudoers.d")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let baseline = root.appendingPathComponent("baseline")
        try "root ALL=(ALL) ALL\n".write(to: baseline, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("still")
        let script = SudoersRule.installationScript(userID: 501)!
            .replacingOccurrences(of: "/private/etc", with: root.path)
            .replacingOccurrences(of: "[ \"$(/usr/bin/id -u)\" = 0 ]", with: ":")
            .replacingOccurrences(of: "'0:0:755'", with: "'\(getuid()):\(getgid()):755'")
            .replacingOccurrences(of: "'0:0:440'", with: "'\(getuid()):\(getgid()):440'")
            .replacingOccurrences(of: "/usr/sbin/chown root:wheel", with: "/usr/bin/true")
            .replacingOccurrences(of: "/usr/sbin/visudo -c >/dev/null", with: "/usr/sbin/visudo -cf '\(baseline.path)' >/dev/null")
        func run(_ command: String) -> ProcessRunner.Result { ProcessRunner.run("/bin/sh", ["-c", command]) }
        let installed = run(script)
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), SudoersRule.line(userID: 501) + "\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o440)
        XCTAssertEqual(run(script).exitCode, 0) // upgrade/atomic replacement
        let before = try Data(contentsOf: destination)
        let failed = run(script.replacingOccurrences(of: "-cf \"$staging/rule\"", with: "-cf \"$staging/missing\""))
        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: destination), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("still-install.") })
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: baseline)
        XCTAssertNotEqual(run(script).exitCode, 0)
        XCTAssertEqual(try String(contentsOf: baseline, encoding: .utf8), "root ALL=(ALL) ALL\n")
    }
}
