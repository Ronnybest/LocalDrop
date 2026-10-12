import CryptoKit
import Foundation

/// The key that lets trusted devices recognize this Mac over BLE and read its sealed Endpoint
/// Info (protocol/protocol.md §2.2–2.3, security.md §6a). It grants no access by itself.
nonisolated struct PresenceKey: Sendable {
    static let size = 32
    private static let item = KeychainBlob(service: "dev.localdrop.presence", account: "presence-key-v1", label: "LocalDrop presence key")
    /// Keys before the last rotations, newest first, end to end.
    private static let history = KeychainBlob(service: "dev.localdrop.presence", account: "presence-key-history-v1", label: "LocalDrop previous presence keys")
    private static let historyLimit = 4
    private static let slotSeconds: Double = 900
    private static let tokenLabel = Data("localdrop/v1/presence".utf8)
    private static let endpointInfo = Data("localdrop/v1/endpoint".utf8)
    private static let pendingLabel = Data("localdrop/v1/pending".utf8)

    let raw: Data

    /// A short id of the key, remembered per device: which key that device was last given.
    var id: Data { Data(SHA256.hash(data: raw).prefix(8)) }

    static func loadOrCreate() throws(IdentityStoreError) -> PresenceKey {
        if let raw = try item.read(), raw.count == size { return PresenceKey(raw: raw) }
        let key = PresenceKey(raw: Self.random())
        try item.add(key.raw)
        Log.crypto.info("Generated presence key")
        return key
    }

    /// New key after a device is forgotten: it can no longer recognize this Mac. The old one is
    /// kept a while for the other phones: one that hasn't connected since only knows that one,
    /// and files waiting for it must be announced in a way it recognizes (protocol.md §2.8).
    static func rotate(from old: PresenceKey?) throws(IdentityStoreError) -> PresenceKey {
        let key = PresenceKey(raw: Self.random())
        try item.replace(with: key.raw)
        if let old {
            let kept = ([old] + previous()).prefix(historyLimit)
            do {
                try history.replace(with: Data(kept.flatMap { $0.raw }))
            } catch {
                Log.crypto.error("Could not keep the previous presence key: \(error.description, privacy: .public)")
            }
        }
        Log.crypto.info("Rotated presence key")
        return key
    }

    /// Keys before the last rotations, newest first; empty if none were kept.
    static func previous() -> [PresenceKey] {
        guard let blob = try? history.read(), blob.count % size == 0 else { return [] }
        return stride(from: 0, to: blob.count, by: size).map { PresenceKey(raw: blob.subdata(in: $0 ..< $0 + size)) }
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

    /// 8-byte tag that tells one trusted phone, and only phones that know this key, that files
    /// wait for it (protocol.md §2.8). Rotates with the slot, like the presence token.
    func pendingTag(deviceId: String, slot: UInt64) -> Data {
        var message = Self.pendingLabel
        message.append(Data(deviceId.lowercased().utf8))
        withUnsafeBytes(of: slot.bigEndian) { message.append(contentsOf: $0) }
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: raw))
        return Data(mac).prefix(8)
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
