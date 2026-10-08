import Foundation

/// Every way a session can end abnormally. Each case maps to one user-visible explanation and,
/// where the peer should be told, one wire error code.
nonisolated enum SessionError: Error, Equatable, CustomStringConvertible {
    case timeout(stage: String)
    case connectionClosed
    case transport(String)
    case protocolViolation(String)
    case versionUnsupported(peerMin: UInt64, peerMax: UInt64)
    case authFailed(String)
    case decryptFailed
    case peerError(code: String, detail: String?)
    case userDecisionTimeout
    case busy
    case cancelled
    /// Pairing was declined. `byPeer` is true when the other device's user declined.
    case pairingRejected(byPeer: Bool)
    /// The trusted-devices store could not be written.
    case storage(String)
    /// A transfer was cancelled; `byPeer` is true when the sending device cancelled it.
    case transferCancelled(byPeer: Bool)
    case checksumMismatch(fileName: String)
    case writeFailed(String)
    case insufficientStorage
    /// The user removed the peer from trusted devices while connected.
    case trustRevoked
    /// The same device connected again; this older session was replaced.
    case superseded
    /// Pairing is needed but this Mac isn't in pairing mode.
    case pairingUnavailable

    /// Code sent to the peer before closing, or nil when the peer can't or needn't be told.
    var wireCode: String? {
        switch self {
        case .protocolViolation: ErrorCode.badMessage
        case .versionUnsupported: ErrorCode.versionUnsupported
        case .authFailed: ErrorCode.authFailed
        case .decryptFailed: ErrorCode.decryptFailed
        case .userDecisionTimeout: ErrorCode.pairingTimeout
        case .busy: ErrorCode.busy
        case .storage: ErrorCode.internal
        case .trustRevoked: ErrorCode.notTrusted
        case .superseded: nil
        case .pairingUnavailable: ErrorCode.pairingUnavailable
        // pairing_result{accepted=false}, cancel and file_result already told the peer.
        case .pairingRejected, .transferCancelled, .checksumMismatch, .writeFailed, .insufficientStorage: nil
        case .timeout, .connectionClosed, .transport, .peerError, .cancelled: nil
        }
    }

    /// Shown to the user (menu, notifications). `description` stays English for logs.
    var userMessage: String {
        switch self {
        case .timeout: String(localized: "The other device stopped responding")
        case .connectionClosed: String(localized: "Connection closed by the other device")
        case .transport: String(localized: "Network error")
        case .protocolViolation: String(localized: "The other device sent unexpected data")
        case .versionUnsupported: String(localized: "Incompatible LocalDrop version — update LocalDrop on both devices")
        case .authFailed: String(localized: "Device identity check failed")
        case .decryptFailed: String(localized: "Decryption failed")
        case .peerError: String(localized: "Closed by the other device")
        case .userDecisionTimeout: String(localized: "No response in time")
        case .busy: String(localized: "Busy with another device")
        case .cancelled: String(localized: "Cancelled")
        case .pairingRejected(let byPeer): byPeer ? String(localized: "Pairing declined on the other device") : String(localized: "Pairing declined")
        case .storage: String(localized: "Could not save the trusted device")
        case .transferCancelled(let byPeer): byPeer ? String(localized: "Cancelled on the other device") : String(localized: "Cancelled")
        case .checksumMismatch(let name): String(localized: "\(name) was damaged in transit and was not saved")
        case .writeFailed: String(localized: "Could not save the file")
        case .insufficientStorage: String(localized: "Not enough disk space")
        case .trustRevoked: String(localized: "Removed from trusted devices")
        case .superseded: String(localized: "Replaced by a new connection")
        case .pairingUnavailable: String(localized: "Not paired — turn on “Visible to new devices” to pair")
        }
    }

    var description: String {
        switch self {
        case .timeout(let stage): "Timed out waiting for \(stage)"
        case .connectionClosed: "Connection closed by the other device"
        case .transport(let message): "Network error: \(message)"
        case .protocolViolation(let message): "Unexpected data: \(message)"
        case .versionUnsupported(let min, let max): "Incompatible LocalDrop version (device supports v\(min)–v\(max))"
        case .authFailed(let message): "Device identity check failed: \(message)"
        case .decryptFailed: "Decryption failed"
        case .peerError(let code, _): "Closed by the other device (\(code))"
        case .userDecisionTimeout: "No response in time"
        case .busy: "Busy with another device"
        case .cancelled: "Cancelled"
        case .pairingRejected(let byPeer): byPeer ? "Pairing declined on the other device" : "Pairing declined"
        case .storage(let message): "Could not save trusted device: \(message)"
        case .transferCancelled(let byPeer): byPeer ? "Cancelled on the other device" : "Cancelled"
        case .checksumMismatch(let name): "\(name) was damaged in transit (checksum mismatch) and was not saved"
        case .writeFailed(let message): "Could not save the file: \(message)"
        case .insufficientStorage: "Not enough disk space"
        case .trustRevoked: "Removed from trusted devices"
        case .superseded: "Replaced by a new connection"
        case .pairingUnavailable: "Not paired and not in pairing mode"
        }
    }
}
