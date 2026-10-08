import CryptoKit
import Foundation

/// Key schedule of protocol/security.md §3.
nonisolated enum HandshakeCrypto {
    static let serverAuthLabel = Data("localdrop/v1/server-auth".utf8)
    static let clientAuthLabel = Data("localdrop/v1/client-auth".utf8)
    private static let c2sInfo = Data("localdrop/v1/c2s".utf8)
    private static let s2cInfo = Data("localdrop/v1/s2c".utf8)
    private static let sasInfo = Data("localdrop/v1/sas".utf8)

    struct SessionKeys {
        let clientToServer: SymmetricKey
        let serverToClient: SymmetricKey
        /// Input for the 6-digit pairing code. Never logged.
        let sasBits: Data
    }

    /// `th = SHA-256(frame(CH) ‖ frame(SH) ‖ frame(CN))`, frames exactly as on the wire.
    static func transcriptHash(_ frames: [Data]) -> Data {
        var hasher = SHA256()
        for frame in frames { hasher.update(data: frame) }
        return Data(hasher.finalize())
    }

    static func deriveKeys(
        ephemeral: P256.KeyAgreement.PrivateKey,
        peerEphemeral: P256.KeyAgreement.PublicKey,
        transcriptHash: Data
    ) throws -> SessionKeys {
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)
        func derive(_ info: Data, _ count: Int) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcriptHash, sharedInfo: info, outputByteCount: count)
        }
        return SessionKeys(
            clientToServer: derive(c2sInfo, 32),
            serverToClient: derive(s2cInfo, 32),
            sasBits: derive(sasInfo, 4).withUnsafeBytes { Data($0) }
        )
    }

    static func authPayload(label: Data, transcriptHash: Data) -> Data {
        label + transcriptHash
    }

    /// 6-digit verification code shown on both devices: `uint32_BE(sasBits) mod 1 000 000`,
    /// formatted "481 273". Never logged.
    static func pairingCode(sasBits: Data) -> String {
        let value = sasBits.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%03u %03u", value / 1000, value % 1000)
    }
}

/// AES-256-GCM for one direction of a session. Nonce = 4 zero bytes ‖ u64 BE counter,
/// incremented per frame and never transmitted (protocol/security.md §4).
nonisolated struct FrameCipher {
    static let tagSize = 16

    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: try nextNonce())
        return box.ciphertext + box.tag
    }

    mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= Self.tagSize else { throw SessionError.decryptFailed }
        let nonce = try nextNonce()
        do {
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: frame.prefix(frame.count - Self.tagSize),
                tag: frame.suffix(Self.tagSize)
            )
            return try AES.GCM.open(box, using: key)
        } catch {
            throw SessionError.decryptFailed
        }
    }

    private mutating func nextNonce() throws -> AES.GCM.Nonce {
        guard counter < UInt64.max else { throw SessionError.protocolViolation("frame counter exhausted") }
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        counter += 1
        return try AES.GCM.Nonce(data: bytes)
    }
}
