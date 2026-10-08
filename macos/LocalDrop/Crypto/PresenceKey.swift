import CryptoKit
import Foundation

/// The key that lets trusted devices recognize this Mac over BLE and read its sealed Endpoint
/// Info (protocol/protocol.md §2.2–2.3, security.md §6a). It grants no access by itself.
nonisolated struct PresenceKey: Sendable {
    static let size = 32
    private static let item = KeychainBlob(service: "dev.localdrop.presence", account: "presence-key-v1", label: "LocalDrop presence key")
    private static let slotSeconds: Double = 900
    private static let tokenLabel = Data("localdrop/v1/presence".utf8)
    private static let endpointInfo = Data("localdrop/v1/endpoint".utf8)

    let raw: Data

    static func loadOrCreate() throws(IdentityStoreError) -> PresenceKey {
        if let raw = try item.read(), raw.count == size { return PresenceKey(raw: raw) }
        let key = PresenceKey(raw: Self.random())
        try item.add(key.raw)
        Log.crypto.info("Generated presence key")
        return key
    }

    /// New key after a device is forgotten: it can no longer recognize this Mac.
    static func rotate() throws(IdentityStoreError) -> PresenceKey {
        let key = PresenceKey(raw: Self.random())
        try item.replace(with: key.raw)
        Log.crypto.info("Rotated presence key")
        return key
    }

    static func slot(at date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970) / slotSeconds)
    }

    static func nextSlotStart(after date: Date) -> Date {
        Date(timeIntervalSince1970: Double(slot(at: date) + 1) * slotSeconds)
    }

    /// 5-byte token for a 15-minute slot.
    func token(slot: UInt64) -> Data {
        var message = Self.tokenLabel
        withUnsafeBytes(of: slot.bigEndian) { message.append(contentsOf: $0) }
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: raw))
        return Data(mac).prefix(5)
    }

    /// Status letter of the private-mode name (protocol.md §2.2).
    enum Status: String {
        case available = "L"
        case noNetwork = "N"
        case busy = "B"
    }

    /// Local name in private mode: status letter + base64url (no padding) of the current token.
    func advertisedName(at date: Date, status: Status) -> String {
        status.rawValue + token(slot: Self.slot(at: date)).base64URLEncodedString()
    }

    /// `nonce ‖ ciphertext ‖ tag` of the Endpoint Info plaintext.
    func sealEndpoint(_ plaintext: Data) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: raw),
            salt: Data(),
            info: Self.endpointInfo,
            outputByteCount: 32
        )
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return combined
    }

    private static func random() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<size).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

extension Data {
    nonisolated func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
