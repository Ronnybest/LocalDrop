import Foundation
import UniformTypeIdentifiers

/// A file to send: already a local file of known size. Photos and iCloud files must be copied
/// out before the request: once the Mac accepts, it waits at most 150 s for the first file and
/// 30 s between frames.
nonisolated struct OutgoingItem: Sendable {
    /// A readable local file (copied into a temporary directory by the caller).
    let url: URL
    /// File name with its real extension (".heic", ".mov", ".pdf"): the Mac's "Photos and videos"
    /// policy checks it together with the MIME type.
    let name: String
    /// From the name's extension, else the file's type; `application/octet-stream` otherwise.
    let mimeType: String
    let size: Int64
    let modified: Date?

    /// Reads size, type and modification date. `name` defaults to the file's own; either way it is
    /// made safe the way the Mac would (no separators, at most 255 bytes).
    static func file(_ url: URL, name: String? = nil) throws(ClientError) -> OutgoingItem {
        let name = FileNames.sanitize(name ?? url.lastPathComponent)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey]),
              values.isRegularFile == true, let size = values.fileSize else {
            throw .sourceUnavailable(name: name)
        }
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? values.contentType
        return OutgoingItem(url: url, name: name, mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                            size: Int64(size), modified: values.contentModificationDate)
    }
}

/// Files the Mac offers this iPhone, for the accept / decline question.
nonisolated struct IncomingOffer: Sendable, Equatable {
    let macName: String
    let fileCount: Int
    let totalSize: Int64
    let firstName: String
}

nonisolated enum ReceivedItem: Sendable {
    /// Saved in the receive directory under `name` (made unique there).
    case file(url: URL, name: String, mimeType: String, size: Int64)
    /// For the pasteboard; the Mac was told it was copied.
    case text(String)
}

/// There are no progress messages on the wire: each side counts what it handed to the socket
/// or wrote to disk.
nonisolated struct TransferProgress: Sendable, Equatable {
    var bytesDone: Int64
    var totalBytes: Int64
    var fileName: String
    var fileIndex: Int
    var fileCount: Int
    /// Over the last 2 seconds.
    var bytesPerSecond: Double
    var phase: Phase

    enum Phase: Sendable, Equatable {
        case waitingForAcceptance
        case transferring
        /// Everything sent; the Mac checks the last file's SHA-256 and saves it.
        case verifying
    }

    var fraction: Double {
        guard totalBytes > 0 else { return phase == .verifying ? 1 : 0 }
        return min(1, Double(bytesDone) / Double(totalBytes))
    }
}

/// Builds `TransferProgress` for one operation and reports it at most every 100 ms, and at once
/// when forced (each file's end, phase changes).
nonisolated struct ProgressMeter {
    private static let interval: Duration = .milliseconds(100)
    private static let speedWindow: Duration = .seconds(2)

    private(set) var progress: TransferProgress
    private let report: @Sendable (TransferProgress) -> Void
    private var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []
    private var lastReport: ContinuousClock.Instant?

    init(totalBytes: Int64, fileCount: Int, firstName: String, report: @escaping @Sendable (TransferProgress) -> Void) {
        progress = TransferProgress(bytesDone: 0, totalBytes: totalBytes, fileName: firstName, fileIndex: 0,
                                    fileCount: fileCount, bytesPerSecond: 0, phase: .waitingForAcceptance)
        self.report = report
    }

    mutating func update(adding bytes: Int64 = 0, file: (index: Int, name: String)? = nil, phase: TransferProgress.Phase? = nil, force: Bool = false) {
        progress.bytesDone += bytes
        if let file {
            progress.fileIndex = file.index
            progress.fileName = file.name
        }
        if let phase { progress.phase = phase }
        let now = ContinuousClock.now
        if !force, let lastReport, now - lastReport < Self.interval { return }
        lastReport = now
        samples.append((now, progress.bytesDone))
        samples.removeAll { now - $0.time > Self.speedWindow }
        if let oldest = samples.first, now > oldest.time {
            let elapsed = now - oldest.time
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            progress.bytesPerSecond = Double(progress.bytesDone - oldest.bytes) / seconds
        }
        report(progress)
    }
}
