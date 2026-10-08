import Foundation
import os

/// Hand-off between the Share extension and the LocalDrop app through their App Group container:
/// the app publishes the phones files can go to; the extension drops files with the chosen phone
/// and pokes the app, which queues them like files picked in its menu.
nonisolated enum ShareInbox {
    /// A paired phone that can receive, as the extension shows it.
    struct Phone: Codable, Hashable, Identifiable, Sendable {
        let deviceId: String
        let name: String
        var id: String { deviceId }
    }

    /// One share: copies of the files (in the request's directory) and the phone they go to.
    struct Request: Codable, Sendable {
        let deviceId: String
        let files: [String]
    }

    private static let log = Logger(subsystem: "dev.localdrop.mac", category: "share")

    /// Posted (Darwin notification) after a request is complete on disk.
    static let requestNotification = "dev.localdrop.share.request"

    /// `$(TeamIdentifierPrefix)dev.localdrop`, from Info.plist (the same key in both bundles).
    private static var groupID: String? { Bundle.main.object(forInfoDictionaryKey: "LocalDropAppGroup") as? String }

    static var container: URL? {
        groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    private static var phonesFile: URL? { container?.appendingPathComponent("phones.json") }
    static var inbox: URL? { container?.appendingPathComponent("Inbox", isDirectory: true) }

    // MARK: App side

    static func publish(_ phones: [Phone]) {
        guard let url = phonesFile else { return }
        do {
            try JSONEncoder().encode(phones).write(to: url, options: .atomic)
        } catch {
            log.error("Could not publish phones for the Share extension: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Complete requests, oldest first; each comes with its directory, removed by the caller when done.
    static func pendingRequests() -> [(request: Request, directory: URL)] {
        guard let inbox, let entries = try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .sorted { creationDate($0) < creationDate($1) }
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
                      let request = try? JSONDecoder().decode(Request.self, from: data) else { return nil }
                return (request, directory)
            }
    }

    private static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    // MARK: Extension side

    static func phones() -> [Phone] {
        guard let url = phonesFile, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Phone].self, from: data)) ?? []
    }

    /// Copies [files] into a new request for [deviceId] — on APFS a clone, instant and free —
    /// writes the request last, then tells the app.
    static func submit(_ files: [URL], to deviceId: String) throws {
        guard let inbox else { throw CocoaError(.fileNoSuchFile) }
        let directory = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var names: [String] = []
            for file in files {
                var name = file.lastPathComponent
                var counter = 1
                while names.contains(name) {
                    counter += 1
                    name = "\(file.deletingPathExtension().lastPathComponent) \(counter)" + (file.pathExtension.isEmpty ? "" : ".\(file.pathExtension)")
                }
                try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(name))
                names.append(name)
            }
            let request = try JSONEncoder().encode(Request(deviceId: deviceId, files: names))
            try request.write(to: directory.appendingPathComponent("request.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(requestNotification as CFString), nil, nil, true
        )
    }
}
