import Foundation

/// Every way reaching or talking to a Mac can fail, from this iPhone's side (Android
/// `ConnectionException`). Each case has one sentence for the UI.
nonisolated enum ClientError: Error, Sendable, Equatable {
    /// No Wi-Fi or Ethernet: Dewlet never sends over mobile data.
    case noLocalNetwork
    /// Local Network access is off for Dewlet in Settings: Bonjour answers PolicyDenied.
    case localNetworkDenied
    /// The Mac didn't answer at its last address and Bonjour didn't find it.
    case notFound
    case refused
    case unreachable
    case timeout(stage: String)
    /// EOF, reset or another transport error, also EOF before `server_hello` (the Mac may be at
    /// its 4-session limit, or still loading its keys).
    case connectionLost
    case incompatibleVersion
    /// `server_hello` from a different device or key than expected, or a bad server signature.
    case authenticationFailed
    case decryptionFailed
    case protocolViolation(String)
    /// The keychain couldn't be read, e.g. before the first unlock after a restart.
    case identityUnavailable
    /// `error{code}` from the Mac: busy, pairing_unavailable, not_trusted, pairing_timeout, auth_failed, bad_message, internal…
    case peerError(code: String)
    case pairingRejected(byPeer: Bool)
    /// A flow that needs trust (receive, the link) met a Mac that doesn't trust this iPhone.
    case notPaired
    /// `transfer_reject.reason` or a `text_result` other than copied: declined, busy, insufficient_storage, timeout, asleep.
    case transferRejected(reason: String)
    /// `file_result` / `transfer_result` failed: checksum_mismatch, write_failed, insufficient_storage.
    case receiverFailed(code: String)
    case cancelledByPeer
    /// Cancelled on this iPhone.
    case cancelled
    case sourceUnavailable(name: String)
    /// The paired Mac or a received file couldn't be saved on this iPhone.
    case storageFailed

    /// The Mac's session errors (thrown by the shared FrameConnection, FrameCipher and parsers)
    /// as the UI sees them; anything else is unexpected data.
    init(_ error: any Error) {
        switch error {
        case let error as ClientError:
            self = error
        case let error as SessionError:
            switch error {
            case .timeout(let stage): self = .timeout(stage: stage)
            case .connectionClosed, .transport: self = .connectionLost
            case .cancelled: self = .cancelled
            case .protocolViolation(let detail): self = .protocolViolation(detail)
            case .versionUnsupported: self = .incompatibleVersion
            case .authFailed: self = .authenticationFailed
            case .decryptFailed: self = .decryptionFailed
            case .peerError(let code, _): self = code == ErrorCode.versionUnsupported ? .incompatibleVersion : .peerError(code: code)
            case .writeFailed, .insufficientStorage, .storage: self = .storageFailed
            case .checksumMismatch: self = .receiverFailed(code: ErrorCode.checksumMismatch)
            case .transferCancelled(let byPeer): self = byPeer ? .cancelledByPeer : .cancelled
            case .pairingRejected(let byPeer): self = .pairingRejected(byPeer: byPeer)
            default: self = .protocolViolation(error.description)
            }
        default:
            self = .protocolViolation(String(describing: error))
        }
    }

    /// Runs a parser of the shared protocol code (which throws `SessionError`) where a
    /// `ClientError` is expected (Android `decoding`).
    static func decoding<T>(_ parse: () throws -> T) throws(ClientError) -> T {
        do {
            return try parse()
        } catch {
            throw ClientError(error)
        }
    }

    /// Worth retrying later without the user doing anything (Android `isTemporary`).
    var isTemporary: Bool {
        switch self {
        case .noLocalNetwork, .notFound, .refused, .unreachable, .timeout, .connectionLost: true
        case .peerError(let code): code == ErrorCode.busy
        case .transferRejected(let reason): reason == RejectReason.busy.rawValue || reason == RejectReason.asleep.rawValue
        default: false
        }
    }

    /// Code to tell the Mac before closing during the handshake (Android `wireCode`); nil when
    /// it needn't or can't be told.
    var wireCode: String? {
        switch self {
        case .protocolViolation: ErrorCode.badMessage
        case .authenticationFailed: ErrorCode.authFailed
        case .decryptionFailed: ErrorCode.decryptFailed
        case .incompatibleVersion: ErrorCode.versionUnsupported
        case .storageFailed: ErrorCode.internal
        default: nil
        }
    }

    /// One sentence for the UI, naming the Mac (Android `TransferText.error`, "phone" → "iPhone").
    func message(macName: String) -> String {
        switch self {
        case .noLocalNetwork:
            String(localized: "Connect to Wi-Fi, or turn on Personal Hotspot on this iPhone and connect the Mac to it. Dewlet sends files directly over the local network and never uses mobile data.", table: "Core")
        case .localNetworkDenied:
            String(localized: "Dewlet can’t reach \(macName): allow Local Network for Dewlet in Settings.", table: "Core")
        case .notFound:
            String(localized: "Can’t find \(macName) on this network. Make sure the Mac is awake, Dewlet is running on it, and both devices are on the same Wi-Fi.", table: "Core")
        case .refused:
            String(localized: "\(macName) refused the connection. Make sure Dewlet is running on it.", table: "Core")
        case .unreachable:
            String(localized: "Can’t reach \(macName). Make sure both devices are on the same Wi-Fi network. Some public and guest networks block connections between devices.", table: "Core")
        case .timeout:
            String(localized: "\(macName) stopped responding.", table: "Core")
        case .connectionLost:
            String(localized: "The connection to \(macName) was lost.", table: "Core")
        case .incompatibleVersion:
            String(localized: "\(macName) uses an incompatible version of Dewlet. Update the app on both devices.", table: "Core")
        case .authenticationFailed:
            String(localized: "Couldn’t verify the identity of \(macName). The connection was closed to keep your data safe.", table: "Core")
        case .decryptionFailed:
            String(localized: "Data from \(macName) failed decryption. The connection was closed to keep your data safe.", table: "Core")
        case .protocolViolation:
            String(localized: "\(macName) sent an unexpected response.", table: "Core")
        case .identityUnavailable:
            String(localized: "This iPhone’s security key is unavailable. Unlock your iPhone and try again.", table: "Core")
        case .peerError(let code):
            switch code {
            case ErrorCode.busy:
                String(localized: "\(macName) is busy with other devices. Try again in a moment.", table: "Core")
            case ErrorCode.pairingTimeout:
                String(localized: "\(macName) closed the connection because pairing wasn’t confirmed in time.", table: "Core")
            case ErrorCode.authFailed:
                String(localized: "\(macName) couldn’t verify this iPhone’s identity.", table: "Core")
            case ErrorCode.notTrusted:
                String(localized: "\(macName) no longer trusts this iPhone. Add the Mac again to pair.", table: "Core")
            case ErrorCode.pairingUnavailable:
                String(localized: "\(macName) isn’t paired with this iPhone. On the Mac, click Dewlet in the menu bar, turn on “Visible to new devices”, then try again.", table: "Core")
            default:
                String(localized: "\(macName) closed the connection (\(code)).", table: "Core")
            }
        case .pairingRejected(let byPeer):
            byPeer
                ? String(localized: "Pairing was declined on \(macName).", table: "Core")
                : String(localized: "Pairing was cancelled.", table: "Core")
        case .notPaired:
            String(localized: "\(macName) is no longer paired with this iPhone. Add it again in Dewlet.", table: "Core")
        case .transferRejected(let reason):
            switch reason {
            case RejectReason.declined.rawValue:
                String(localized: "\(macName) declined the transfer.", table: "Core")
            case RejectReason.busy.rawValue:
                String(localized: "\(macName) is receiving another transfer. Try again in a moment.", table: "Core")
            case RejectReason.asleep.rawValue:
                String(localized: "\(macName) is asleep. Wake it up and try again.", table: "Core")
            case RejectReason.insufficientStorage.rawValue:
                String(localized: "There isn’t enough free space on \(macName).", table: "Core")
            case RejectReason.timeout.rawValue:
                String(localized: "\(macName) didn’t respond to the request.", table: "Core")
            default:
                String(localized: "\(macName) rejected the transfer (\(reason)).", table: "Core")
            }
        case .receiverFailed(let code):
            switch code {
            case ErrorCode.checksumMismatch:
                String(localized: "A file was damaged in transit (checksum mismatch) and wasn’t saved. Try again.", table: "Core")
            case ErrorCode.insufficientStorage:
                String(localized: "There isn’t enough free space on \(macName).", table: "Core")
            case ErrorCode.writeFailed:
                String(localized: "\(macName) couldn’t save the file.", table: "Core")
            default:
                String(localized: "\(macName) closed the connection (\(code)).", table: "Core")
            }
        case .cancelledByPeer:
            String(localized: "\(macName) cancelled the transfer.", table: "Core")
        case .cancelled:
            String(localized: "Transfer cancelled.", table: "Core")
        case .sourceUnavailable(let name):
            String(localized: "\(name) can no longer be read. It may have been moved or deleted.", table: "Core")
        case .storageFailed:
            String(localized: "Couldn’t save on this iPhone. Free up some storage and try again.", table: "Core")
        }
    }
}
