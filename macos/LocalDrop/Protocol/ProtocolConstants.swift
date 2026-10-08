import CoreBluetooth
import Foundation

/// Values fixed by protocol/protocol.md. Changing any of them is a protocol change.
nonisolated enum ProtocolConstants {
    static let version: UInt64 = 1
    static let minSupportedVersion: UInt64 = 1

    @MainActor static let serviceUUID = CBUUID(string: "8D232B6B-5901-4AEA-89A2-389415C619EB")
    @MainActor static let endpointInfoCharacteristicUUID = CBUUID(string: "13391BAF-1674-4EF2-A1E1-AAD175FE6C3F")

    /// BLE local name prefixes (protocol.md §2.2): private token, or pairing mode + shortId.
    static let privateNamePrefix = "L"
    static let pairingNamePrefix = "P"
    static let shortIdLength = 6

    /// What this Mac can do (protocol.md §2.6).
    static let capabilities = ["files", "multipleFiles", "text", "clipboardReceive", "autoAccept", "presenceToken"]

    /// Longest `text` message, in UTF-8 bytes (protocol/messages.md).
    static let maxTextSize = 262_144

    static let bonjourServiceType = "_localdrop._tcp"

    static let maxFrameSize = 1_048_576 + 64
    static let maxChunkSize = 1_048_576
    /// Sender-side chunk size. Not part of the wire contract; receivers accept up to `maxChunkSize`.
    static let chunkSize = 256 * 1024

    static let platform = "macos"
}
