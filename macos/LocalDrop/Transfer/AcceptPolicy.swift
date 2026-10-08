import Foundation
import UniformTypeIdentifiers

/// What this Mac does with transfers from one trusted device. Applies only after the device
/// proved its identity in the handshake; unknown devices can never send.
nonisolated enum AcceptPolicy: String, Codable, CaseIterable, Sendable {
    case ask
    /// Photos and videos are saved without asking; anything else asks.
    case photosOnly
    /// Transfers up to `smallTransferLimit` in total are saved without asking; larger ones ask.
    case under100MB
    case always
    /// Everything from this device is declined without asking.
    case never

    static let smallTransferLimit: Int64 = 100_000_000

    enum Decision: Equatable {
        case accept
        case ask
        case decline
    }

    var title: String {
        switch self {
        case .ask: String(localized: "Ask every time")
        case .photosOnly: String(localized: "Photos and videos")
        case .under100MB: String(localized: "Files under 100 MB")
        case .always: String(localized: "Everything")
        case .never: String(localized: "Nothing — decline")
        }
    }

    func decision(for files: [TransferFileInfo], totalSize: Int64) -> Decision {
        switch self {
        case .ask: .ask
        case .never: .decline
        case .always: .accept
        case .under100MB: totalSize <= Self.smallTransferLimit ? .accept : .ask
        case .photosOnly: files.allSatisfy(Self.isPhotoOrVideo) ? .accept : .ask
        }
    }

    /// Both the announced MIME type and the name the file will be saved under must say photo or
    /// video, so a file named like an app or script never slips through as a "photo".
    static func isPhotoOrVideo(_ file: TransferFileInfo) -> Bool {
        let mime = file.mimeType.lowercased()
        guard mime.hasPrefix("image/") || mime.hasPrefix("video/") else { return false }
        let fileExtension = (FileNames.sanitize(file.name) as NSString).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }
}
