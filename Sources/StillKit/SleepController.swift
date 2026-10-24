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

    public static func line(userID: uid_t) -> String {
        "#\(userID) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
    }

    /// All privileged input is generated from a numeric UID. No user-writable
    /// file is consumed after authorization; validation and replacement occur
    /// within the same root shell, on the same filesystem.
    public static func installationScript(userID: uid_t) -> String? {
        guard userID != 0 else { return nil }
        return """
        set -eu
        umask 077
        [ "$(/usr/bin/id -u)" = 0 ]
        for directory in /private/etc /private/etc/sudoers.d; do
            [ -d "$directory" ] && [ ! -L "$directory" ]
            [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$directory")" = '0:0:755' ]
        done
        destination=/private\(installPath)
        [ ! -L "$destination" ]
        if [ -e "$destination" ]; then
            [ -f "$destination" ]
            [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$destination")" = '0:0:440' ]
        fi
        /usr/sbin/visudo -c >/dev/null
        staging=$(/usr/bin/mktemp -d /private/etc/still-install.XXXXXXXX)
        trap '/bin/rm -rf "$staging"' EXIT HUP INT TERM
        /usr/bin/printf '%s\\n' '\(line(userID: userID))' > "$staging/rule"
        /usr/sbin/visudo -cf "$staging/rule" >/dev/null
        /usr/sbin/chown root:wheel "$staging/rule"
        /bin/chmod 0440 "$staging/rule"
        /bin/mv -f "$staging/rule" "$destination"
        """
    }

    public static func administratorAppleScript(command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    public static func validate(rule: String) -> Bool {
        let temp = NSTemporaryDirectory() + "still-sudoers-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: temp, contents: Data(rule.utf8)) else { return false }
        defer { try? FileManager.default.removeItem(atPath: temp) }
        return ProcessRunner.run("/usr/sbin/visudo", ["-cf", temp], timeout: 10).exitCode == 0
    }

    /// The rule file is root-only (0440), so the app cannot read it. Ask sudo
    /// what this user may run without a password instead.
    public static func installedAndMatching() -> Bool {
        let result = ProcessRunner.run("/usr/bin/sudo", ["-n", "-l"], timeout: 5)
        guard result.exitCode == 0 else { return false }
        return listingGrantsHold(result.stdout)
    }

    public static func listingGrantsHold(_ listing: String) -> Bool {
        // Do not combine an unrelated NOPASSWD tag with password-protected
        // commands, accept argument suffixes, or overlook a negated rule.
        // Ignore the "Matching Defaults entries" block (which on macOS contains
        // flags such as "!log_allowed") and unfold wrapped continuation lines.
        let required: Set<String> = ["/usr/bin/pmset -a disablesleep 1", "/usr/bin/pmset -a disablesleep 0"]
        var entries: [String] = []
        var inDefaults = false
        for rawLine in listing.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                inDefaults = false
                continue
            }
            if trimmed.hasPrefix("Matching Defaults entries") {
                inDefaults = true
                continue
            }
            if trimmed.hasPrefix("User "), trimmed.hasSuffix(":") {
                inDefaults = false
                continue
            }
            if inDefaults, !trimmed.hasPrefix("(") {
                continue
            }
            inDefaults = false
            guard !trimmed.contains("!") else { return false }
            if trimmed.hasPrefix("(") {
                entries.append(trimmed)
            } else if !entries.isEmpty, rawLine.first?.isWhitespace == true {
                entries[entries.count - 1] += " " + trimmed
            } else {
                return false
            }
        }
        var granted: Set<String> = []
        let prefix = "(root) NOPASSWD:"
        for entry in entries {
            guard entry.hasPrefix(prefix) else { continue }
            let commands = entry.dropFirst(prefix.count).split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard !commands.isEmpty, commands.allSatisfy({ required.contains($0) }) else { continue }
            granted.formUnion(commands)
        }
        return required.isSubset(of: granted)
    }
}

/// Fixed descriptors and file-backed output avoid Foundation Process/Pipe's
/// descriptor lifetime failures in a long-lived menu-bar process. No shell is used.
public enum ProcessRunner {
    public struct Result {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
    }

    private final class ExitStatus: @unchecked Sendable {
        var value: Int32 = 0 // published by the semaphore before being read
    }

    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("still-command-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            return Result(exitCode: -1, stdout: "", stderr: "Cannot initialize command descriptors")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            return Result(exitCode: -1, stdout: "", stderr: "Cannot initialize command attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every inherited descriptor except the three explicitly opened
        // below. The child cannot keep an inbox or another child's pipe alive.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let descriptorErrors = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdoutURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderrURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        ]
        if let error = descriptorErrors.first(where: { $0 != 0 }) {
            return Result(exitCode: -1, stdout: "", stderr: String(cString: strerror(error)))
        }
        let strings = ([path] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { environment.forEach { free($0) } }
        var argv = strings + [nil]
        var envp = environment + [nil]
        var pid: pid_t = 0
        let error = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        guard error == 0 else {
            return Result(exitCode: -1, stdout: "", stderr: String(cString: strerror(error)))
        }
        let status = ExitStatus()
        let exited = DispatchSemaphore(value: 0)
        let childPID = pid
        DispatchQueue.global(qos: .utility).async {
            var value: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(childPID, &value, 0) } while result == -1 && errno == EINTR
            status.value = result == childPID ? value : -1
            exited.signal()
        }
        let timedOut = exited.wait(timeout: .now() + max(0.01, timeout)) == .timedOut
        if timedOut {
            kill(pid, SIGTERM)
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(pid, SIGKILL)
                // Reap the owned child before returning; no lingering writer.
                exited.wait()
            }
        }
        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let value = status.value
        let code: Int32 = value == -1 ? -1 : ((value & 0x7f) == 0 ? (value >> 8) & 0xff : 128 + (value & 0x7f))
        return Result(exitCode: timedOut ? -1 : code, stdout: stdout, stderr: timedOut ? "timed out" : stderr)
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
        SudoersRule.installedAndMatching()
    }

    public func readSleepDisabled() -> Bool? {
        if let value = RootDomain.boolProperty("SleepDisabled") {
            return value
        }
        let result = ProcessRunner.run(pmsetPath, ["-g"], timeout: 5)
        if result.exitCode == 0, let value = SleepFlagParser.parse(result.stdout) {
            return value
        }
        return nil // stale preference files are not proof of the live kernel state
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
        // Recovery only. Enabling this global setting can block Apple-menu
        // sleep before any notification is delivered. Never enable it again.
        guard !disabled, didSetFlag else { return false }
        let result = ProcessRunner.run(
            sudoPath,
            ["-n", pmsetPath, "-a", "disablesleep", "0"],
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
        lastWriteSucceeded = false
        Self.log.error("write SleepDisabled=\(disabled ? "1" : "0", privacy: .public) failed exit=\(result.exitCode, privacy: .public) err=\(result.stderr, privacy: .public)")
        return false
    }

    /// One interactive recovery command, without installing a sudoers rule.
    public func restoreLegacyWithAuthorization() -> Bool {
        guard didSetFlag else { return true }
        var error: NSDictionary?
        NSAppleScript(source: SudoersRule.administratorAppleScript(
            command: "/usr/bin/pmset -a disablesleep 0"
        ))?.executeAndReturnError(&error)
        guard error == nil, readSleepDisabled() == false else { return false }
        didSetFlag = false
        lastWriteSucceeded = true
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
    var isActive: Bool { assertionID != 0 }
    private let create: (String, inout IOPMAssertionID) -> IOReturn
    private let release: (IOPMAssertionID) -> IOReturn
    private let now: () -> Date
    private var expiry: Date?

    init(create: @escaping (String, inout IOPMAssertionID) -> IOReturn = { reason, id in
        IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            reason as CFString, nil, nil, nil,
            3 * 3600, kIOPMAssertionTimeoutActionRelease as CFString, &id
        )
    }, release: @escaping (IOPMAssertionID) -> IOReturn = { IOPMAssertionRelease($0) },
         now: @escaping () -> Date = Date.init) {
        self.create = create
        self.release = release
        self.now = now
    }

    isolated deinit {
        if assertionID != 0 { _ = release(assertionID) }
    }

    @discardableResult
    func setActive(_ active: Bool, reason: String) -> Bool {
        if active {
            if let expiry, now() >= expiry {
                _ = setActive(false, reason: "")
                return false // do not renew a kernel-expired session
            }
            guard assertionID == 0 else { return true }
            var id: IOPMAssertionID = 0
            let success = create(reason, &id)
            assertionID = (success == kIOReturnSuccess) ? id : 0
            if success == kIOReturnSuccess { expiry = now().addingTimeInterval(3 * 3600) }
            return success == kIOReturnSuccess
        } else {
            guard assertionID != 0 else { return true }
            let result = release(assertionID)
            // A kernel timeout may already have released this assertion.
            guard result == kIOReturnSuccess || result == kIOReturnNotFound else { return false }
            assertionID = 0
            expiry = nil
            return true
        }
    }
}
