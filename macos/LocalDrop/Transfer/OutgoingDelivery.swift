import Foundation
import UniformTypeIdentifiers

/// Files this Mac sends to one paired phone. They wait until the phone connects and asks
/// (`receive_ready`, protocol.md §2.8); meanwhile the Mac advertises a pending delivery.
@Observable
final class OutgoingDelivery: Identifiable {
    enum Phase: Equatable {
        /// Waiting for the phone to wake up and connect.
        case waiting
        /// The phone has the request and shows it to its user.
        case awaitingAcceptance
        case sending
    }

    let id: UUID
    let deviceId: String
    let deviceName: String
    private(set) var files: [URL]
    /// Text for the phone's clipboard instead of files (messages.md `text`).
    let text: String?
    let createdAt: Date
    var phase: Phase = .waiting
    var bytesSent: Int64 = 0
    /// Lets the menu cancel a running send; checked by the sender between chunks.
    let cancelToken = TransferCancelToken()

    init(id: UUID = UUID(), deviceId: String, deviceName: String, files: [URL] = [], text: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.files = files
        self.text = text
        self.createdAt = createdAt
    }

    var totalBytes: Int64 {
        if let text { return Int64(text.utf8.count) }
        return files.reduce(0) { $0 + OutgoingFile.size(of: $1) }
    }
    var fraction: Double {
        let total = totalBytes
        return total > 0 ? min(1, Double(bytesSent) / Double(total)) : 0
    }

    var title: String {
        if let text { return TextPreview.make(text) }
        return files.count == 1 ? files[0].lastPathComponent : String(localized: "\(files.count) files")
    }

    /// More files while still waiting: one request for everything, like on the phone.
    func add(_ urls: [URL]) {
        files += urls.filter { !files.contains($0) }
    }
}

/// What a file is announced as in `transfer_request`.
nonisolated enum OutgoingFile {
    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func info(_ url: URL, fileId: Int) throws -> TransferFileInfo {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw SessionError.writeFailed("\(url.lastPathComponent) is not a readable file")
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let modified = values.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        return TransferFileInfo(fileId: fileId, name: url.lastPathComponent, mimeType: mime, size: Int64(size), lastModified: modified)
    }
}

/// Deliveries kept across restarts of LocalDrop or the Mac, like the phone's queue: files as
/// security-scoped bookmarks, so files picked or dropped by the user stay readable. Older than
/// a week, or whose files are gone, they are dropped.
struct DeliveryStore {
    private struct Record: Codable {
        let id: UUID
        let deviceId: String
        let deviceName: String
        let files: [Data]
        let text: String?
        let createdAt: Date
    }

    static let maxAge: TimeInterval = 7 * 24 * 3600
    private let fileURL: URL
    /// Bookmarks already made, by file: saving happens on every change to the queue.
    private var bookmarks: [URL: Data] = [:]

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("deliveries.json")
    }

    mutating func save(_ deliveries: [OutgoingDelivery]) {
        let records = deliveries.map { delivery in
            Record(
                id: delivery.id, deviceId: delivery.deviceId, deviceName: delivery.deviceName,
                files: delivery.files.compactMap { bookmark(for: $0) }, text: delivery.text, createdAt: delivery.createdAt
            )
        }
        bookmarks = bookmarks.filter { url, _ in deliveries.contains { $0.files.contains(url) } }
        do {
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            Log.transfer.error("Could not save the delivery queue: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The saved deliveries, with their files opened for reading (security scope started).
    mutating func load() -> [OutgoingDelivery] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records.compactMap { record in
            guard Date().timeIntervalSince(record.createdAt) < Self.maxAge else { return nil }
            let files = record.files.compactMap { data -> URL? in
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
                      url.startAccessingSecurityScopedResource() else { return nil }
                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    url.stopAccessingSecurityScopedResource()
                    return nil
                }
                bookmarks[url] = stale ? nil : data
                return url
            }
            guard record.text != nil || !files.isEmpty else { return nil }
            return OutgoingDelivery(id: record.id, deviceId: record.deviceId, deviceName: record.deviceName,
                                    files: files, text: record.text, createdAt: record.createdAt)
        }
    }

    private mutating func bookmark(for url: URL) -> Data? {
        if let data = bookmarks[url] { return data }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            bookmarks[url] = data
            return data
        } catch {
            Log.transfer.error("Could not keep \(url.lastPathComponent, privacy: .public) for later: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
