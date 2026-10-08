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

    let id = UUID()
    let deviceId: String
    let deviceName: String
    private(set) var files: [URL]
    var phase: Phase = .waiting
    var bytesSent: Int64 = 0
    /// Lets the menu cancel a running send; checked by the sender between chunks.
    let cancelToken = TransferCancelToken()

    init(deviceId: String, deviceName: String, files: [URL]) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.files = files
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + OutgoingFile.size(of: $1) } }
    var fraction: Double {
        let total = totalBytes
        return total > 0 ? min(1, Double(bytesSent) / Double(total)) : 0
    }

    var title: String {
        files.count == 1 ? files[0].lastPathComponent : String(localized: "\(files.count) files")
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
