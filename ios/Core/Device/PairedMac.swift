import Foundation

/// A Mac this iPhone has paired with (Android `TrustedDevice`).
nonisolated struct PairedMac: Codable, Identifiable, Equatable, Sendable {
    /// The Mac's deviceId, lowercase.
    var id: String
    var name: String
    /// Identity public key, X9.63 (65 bytes).
    var publicKey: Data
    /// SHA-256 of `publicKey`.
    var fingerprint: Data
    /// The latest presence key the Mac gave (32 bytes). The Mac addresses pending deliveries with
    /// the key it last gave this iPhone, so every new one is stored.
    var presenceKey: Data?
    /// `server_hello.caps` of the last session.
    var capabilities: [String]
    /// Where the Mac answered last: the address that answered first.
    var lastAddresses: [String]
    var lastPort: UInt16?
    var firstSeen: Date
    var lastSeen: Date
    /// Files this Mac sends are saved without asking.
    var receiveAutomatically: Bool

    /// The Mac runs a Dewlet that sends to phones.
    var canSend: Bool { capabilities.contains("send") }
    /// Text goes to the Mac's clipboard as `text` rather than as a file.
    var takesClipboardText: Bool { capabilities.contains(ProtocolConstants.clipboardReceiveCapability) }
}
