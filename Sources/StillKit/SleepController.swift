import Foundation
import IOKit
import IOKit.pwr_mgt
import SystemConfiguration
import os.log

public protocol PowerManaging: Sendable {
    func readSleepDisabled() -> Bool?
    func writeSleepDisabled(_ disabled: Bool) -> Bool
}

public enum SleepFlagParser {
    public static func parse(_ output: String) -> Bool? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SleepDisabled") else { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let value = Int(parts[1]) else { continue }
            return value == 1
        }
        return nil
    }
}

public enum SudoersRule {
    public static let installPath = "/etc/sudoers.d/\(Brand.sudoersFileName)"

    public static func line(username: String) -> String {
        "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
    }

    public static func validate(rule: String) -> Bool {
        let temp = NSTemporaryDirectory() + "still-sudoers-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: temp, contents: Data(rule.utf8)) else { return false }
        defer { try? FileManager.default.removeItem(atPath: temp) }
        return ProcessRunner.run("/usr/sbin/visudo", ["-cf", temp], timeout: 10).exitCode == 0
    }

    /// The rule file is root-only (0440), so the app cannot read it. Ask sudo
    /// what this user may run without a password instead.
    public static func installedAndMatching(username: String) -> Bool {
        let result = ProcessRunner.run("/usr/bin/sudo", ["-n", "-l"], timeout: 5)
        guard result.exitCode == 0 else { return false }
        return listingGrantsHold(result.stdout)
    }

    public static func listingGrantsHold(_ listing: String) -> Bool {
        listing.contains("NOPASSWD:")
            && listing.contains("/usr/bin/pmset -a disablesleep 1")
            && listing.contains("/usr/bin/pmset -a disablesleep 0")
    }
}

public enum ProcessRunner {
    public struct Result {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }
        let timedOut = group.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        if timedOut {
            return Result(exitCode: -1, stdout: "", stderr: "timed out")
        }
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

public enum CurrentUser {
    public static var shortName: String {
        var uid: uid_t = 0
        if let cfName = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) {
            let name = cfName as String
            if !name.isEmpty, name != "loginwindow" {
                return name
            }
        }
        return ProcessInfo.processInfo.userName
    }
}

public enum RootDomain {
    public static func boolProperty(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceNameMatching("IOPMAppleRootDomain")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }
        if let boolean = property as? Bool { return boolean }
        if let number = property as? NSNumber { return number.boolValue }
        return nil
    }
}

@MainActor
public final class SleepController {
    private static let log = Logger(subsystem: Brand.logSubsystem, category: "sleep")

    private let defaults = UserDefaults.standard
    private let pmsetPath = "/usr/bin/pmset"
    private let sudoPath = "/usr/bin/sudo"

    public var didSetFlag: Bool {
        get { defaults.bool(forKey: "didSetFlag") }
        set { defaults.set(newValue, forKey: "didSetFlag") }
    }

    public private(set) var lastWriteSucceeded: Bool = true

    public init() {}

    public var privilegeGranted: Bool {
        SudoersRule.installedAndMatching(username: CurrentUser.shortName)
    }

    public func readSleepDisabled() -> Bool? {
        if let value = RootDomain.boolProperty("SleepDisabled") {
            return value
        }
        let result = ProcessRunner.run(pmsetPath, ["-g"], timeout: 5)
        if result.exitCode == 0, let value = SleepFlagParser.parse(result.stdout) {
            return value
        }
        return Self.readFromPlists()
    }

    private static func readFromPlists() -> Bool? {
        let base = "/Library/Preferences"
        var paths = [base + "/com.apple.PowerManagement.plist"]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: base) {
            paths += entries
                .filter { $0.hasPrefix("com.apple.PowerManagement.") && $0.hasSuffix(".plist") }
                .map { base + "/" + $0 }
        }
        var found: Bool?
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            if let value = recursiveBool(plist, key: "SleepDisabled") {
                found = value
            } else if found == nil {
                found = false
            }
        }
        return found
    }

    private static func recursiveBool(_ dict: [String: Any], key: String) -> Bool? {
        for (dictKey, value) in dict {
            if dictKey == key {
                if let boolean = value as? Bool { return boolean }
                if let number = value as? NSNumber { return number.boolValue }
                if let string = value as? String { return string == "1" || string.lowercased() == "true" }
            }
            if let nested = value as? [String: Any],
               let result = recursiveBool(nested, key: key) {
                return result
            }
        }
        return nil
    }

    public func writeSleepDisabled(_ disabled: Bool) -> Bool {
        if disabled {
            didSetFlag = true
        }
        let result = ProcessRunner.run(
            sudoPath,
            ["-n", pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"],
            timeout: 8
        )
        var readBack: Bool?
        for _ in 0..<6 {
            readBack = readSleepDisabled()
            if readBack == disabled { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let verified = readBack == disabled

        if verified {
            if !disabled { didSetFlag = false }
            lastWriteSucceeded = true
            Self.log.info("SleepDisabled=\(disabled ? "1" : "0", privacy: .public) verified (exit \(result.exitCode, privacy: .public))")
            return true
        }

        if !disabled, readBack == false {
            didSetFlag = false
            lastWriteSucceeded = true
            return true
        }
        if disabled, readBack != true {
            didSetFlag = false
        }
        lastWriteSucceeded = false
        Self.log.error("write SleepDisabled=\(disabled ? "1" : "0", privacy: .public) failed exit=\(result.exitCode, privacy: .public) err=\(result.stderr, privacy: .public)")
        return false
    }

    public func installPrivilege() -> Bool {
        let rule = SudoersRule.line(username: CurrentUser.shortName)
        guard SudoersRule.validate(rule: rule) else {
            Self.log.error("sudoers rule failed pre-validation")
            return false
        }
        let temp = NSTemporaryDirectory() + "still-rule-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: temp, contents: Data((rule + "\n").utf8)) else {
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: temp) }

        let escaped = temp
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = #"do shell script "/usr/bin/install -m 0440 -o root -g wheel \"\#(escaped)\" \#(SudoersRule.installPath)" with administrator privileges"#
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Self.log.error("privilege install declined: \(error)")
            return false
        }
        guard SudoersRule.installedAndMatching(username: CurrentUser.shortName) else { return false }
        Self.log.info("privileged access installed")
        return true
    }

    public func removePrivilege() {
        let source = #"do shell script "/bin/rm -f \#(SudoersRule.installPath)" with administrator privileges"#
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error == nil {
            Self.log.info("privileged access removed")
        }
    }
}

@MainActor
final class AssertionController {
    private var assertionID: IOPMAssertionID = 0

    func setActive(_ active: Bool, reason: String) {
        if active {
            guard assertionID == 0 else { return }
            var id: IOPMAssertionID = 0
            let success = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            assertionID = (success == kIOReturnSuccess) ? id : 0
        } else {
            guard assertionID != 0 else { return }
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
}
