import Foundation
import Darwin

/// Per-user durable mailbox. No TCP listener, Accessibility access, or agent output.
public enum FocusInbox {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Still/FocusEvents", isDirectory: true)
    }
    public static func prepare(_ directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    @discardableResult public static func write(_ event: FocusEvent, to directory: URL = directory) throws -> URL {
        try prepare(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.count < 512 else { throw CocoaError(.fileWriteOutOfSpace) }
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        let data = try JSONEncoder().encode(event)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
    public static func read(_ url: URL) -> FocusEvent? {
        guard url.pathExtension == "json",
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = attributes[.size] as? NSNumber, size.intValue <= 8192,
              let data = try? Data(contentsOf: url),
              let event = try? JSONDecoder().decode(FocusEvent.self, from: data),
              UUID(uuidString: event.id) != nil, event.key.count <= 128, event.session.count <= 128,
              event.project.count <= 80 else { return nil }
        return event
    }

    /// A passive hook always emits no stdout and never supplies an approval decision.
    public static func runHookIfRequested() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--focus-gui"), args.indices.contains(index + 1) {
            let value = args[index + 1]
            guard value == "begin" || value == "end" else { exit(1) }
            do {
                let url = try write(FocusEvent(key: UUID().uuidString, provider: .codex, session: "gui-compatibility",
                                     kind: value == "begin" ? .guiBegin : .guiEnd))
                // Acknowledged only after the main app has removed the overlay.
                let deadline = Date().addingTimeInterval(3)
                while FileManager.default.fileExists(atPath: url.path), Date() < deadline { usleep(50_000) }
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    fputs("Still Focus: no acknowledgement. Start Still and confirm Focus is paused before automation.\n", stderr)
                    exit(1)
                }
            } catch { fputs("Still Focus: compatibility signal could not be stored.\n", stderr); exit(1) }
            exit(0)
        }
        guard let index = args.firstIndex(of: "--focus-hook"), args.indices.contains(index + 1),
              let provider = FocusProvider(rawValue: args[index + 1]) else { return }
        let data = FileHandle.standardInput.readData(ofLength: 1_048_577)
        guard let event = HookEventProvider(provider).event(from: data,
                    terminal: ProcessInfo.processInfo.environment["TERM_PROGRAM"],
                    userApprovals: args.contains("--user-approvals")) else { exit(0) }
        do { try write(event) }
        catch { fputs("Still Focus: event could not be stored.\n", stderr) }
        exit(0)
    }
}
