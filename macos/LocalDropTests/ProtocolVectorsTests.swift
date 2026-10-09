import CoreBluetooth
import CryptoKit
import Foundation
import Testing
@testable import LocalDrop

/// protocol/test-vectors.properties, the vectors the phone's tests check too
/// (android/app/src/test/java/dev/localdrop/core/ProtocolVectorsTest.kt): both sides must agree
/// byte for byte. The file is a resource of this test bundle: tests run inside the sandboxed app.
struct ProtocolVectorsTests {
    private let vectors: [String: String]

    init() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "test-vectors", withExtension: "properties"))
        var vectors: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            vectors[line[..<equals].trimmingCharacters(in: .whitespaces)] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        self.vectors = vectors
    }

    @Test func hkdf() throws {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: try bytes("hkdf.ikm")), salt: try bytes("hkdf.salt"),
                                         info: try bytes("hkdf.info"), outputByteCount: 42)
        #expect(hex(key) == (try text("hkdf.okm")))
    }

    @Test func handshakeKeySchedule() throws {
        let client = try P256.KeyAgreement.PrivateKey(rawRepresentation: try bytes("handshake.clientEphemeralPrivate"))
        let server = try P256.KeyAgreement.PrivateKey(rawRepresentation: try bytes("handshake.serverEphemeralPrivate"))
        #expect(hex(client.publicKey.x963Representation) == (try text("handshake.clientEphemeralPublic")))
        #expect(hex(server.publicKey.x963Representation) == (try text("handshake.serverEphemeralPublic")))

        let transcriptHash = HandshakeCrypto.transcriptHash(try list("handshake.frames").map(unhex))
        #expect(hex(transcriptHash) == (try text("handshake.transcriptHash")))
        let shared = try server.sharedSecretFromKeyAgreement(with: client.publicKey)
        #expect(shared.withUnsafeBytes { hex(Data($0)) } == (try text("handshake.sharedSecret")))

        // The Mac is the server: the same keys from its side.
        let keys = try HandshakeCrypto.deriveKeys(ephemeral: server, peerEphemeral: client.publicKey, transcriptHash: transcriptHash)
        #expect(hex(keys.clientToServer) == (try text("handshake.clientToServerKey")))
        #expect(hex(keys.serverToClient) == (try text("handshake.serverToClientKey")))
        #expect(hex(keys.sasBits) == (try text("handshake.sasBits")))
        #expect(HandshakeCrypto.pairingCode(sasBits: keys.sasBits) == (try text("handshake.pairingCode")))
    }

    @Test func frameEncryption() throws {
        var sender = FrameCipher(key: SymmetricKey(data: try bytes("frames.key")))
        var receiver = FrameCipher(key: SymmetricKey(data: try bytes("frames.key")))
        for (plaintext, sealed) in zip(try list("frames.plaintexts"), try list("frames.sealed")) {
            #expect(hex(try sender.seal(Data(plaintext.utf8))) == sealed)
            #expect(String(decoding: try receiver.open(unhex(sealed)), as: UTF8.self) == plaintext)
        }
    }

    @Test func pairingCodes() throws {
        for (sas, code) in zip(try list("pairingCode.sasBits"), try list("pairingCode.codes")) {
            #expect(HandshakeCrypto.pairingCode(sasBits: unhex(sas)) == code)
        }
    }

    @Test func fingerprint() throws {
        let digest = Data(SHA256.hash(data: try bytes("fingerprint.publicKey")))
        #expect(hex(digest) == (try text("fingerprint.sha256")))
        #expect(digest.fingerprintDisplay == (try text("fingerprint.display")))
    }

    @Test func presenceTokenAndName() throws {
        let key = PresenceKey(raw: try bytes("presence.key"))
        let slot = try #require(UInt64(try text("presence.slot")))
        #expect(hex(key.token(slot: slot)) == (try text("presence.token")))
        let inSlot = Date(timeIntervalSince1970: Double(slot) * 900 + 1)
        #expect(key.advertisedName(at: inSlot, status: .available) == (try text("presence.name")))
    }

    @MainActor @Test func pendingDeliveryTag() throws {
        let key = PresenceKey(raw: try bytes("presence.key"))
        let tag = key.pendingTag(deviceId: try text("pending.deviceId"), slot: try #require(UInt64(try text("pending.slot"))))
        #expect(hex(tag) == (try text("pending.tag")))
        #expect(ProtocolConstants.pendingDeliveryUUID(tag: tag).uuidString == (try text("pending.uuid")))
    }

    @Test func endpointInfo() throws {
        let open = try bytes("endpoint.cbor")
        // Deterministic encoding: what is decoded encodes to the same bytes.
        #expect(CBOR.encode(try CBOR.decode(open)) == open)

        let presenceKey = try bytes("presence.key")
        let sealed = try #require(try CBOR.decode(try bytes("endpoint.sealed"))["sealed"]?.bytes)
        let info = try CBOR.decode(try openEndpoint(sealed, presenceKey: presenceKey))
        #expect(info["id"]?.text == (try text("endpoint.sealed.deviceId")))
        #expect(info["port"]?.uint == (try #require(UInt64(try text("endpoint.sealed.port")))))

        // What this Mac seals opens the same way.
        let mine = EndpointInfo(protocolVersion: 1, deviceId: "id", deviceName: "Mac", platform: "macos", port: 1,
                                addresses: [], fingerprint: Data(count: 32), busy: false, capabilities: [])
        let mineSealed = try #require(try CBOR.decode(try mine.sealed(with: PresenceKey(raw: presenceKey)))["sealed"]?.bytes)
        #expect(try openEndpoint(mineSealed, presenceKey: presenceKey) == mine.encoded())
    }

    /// `nonce ‖ ciphertext ‖ tag` with the key protocol.md §2.3 derives from the presence key.
    private func openEndpoint(_ sealed: Data, presenceKey: Data) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: presenceKey), salt: Data(),
                                         info: Data("localdrop/v1/endpoint".utf8), outputByteCount: 32)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }

    private func text(_ key: String) throws -> String { try #require(vectors[key], "missing vector \(key)") }
    private func bytes(_ key: String) throws -> Data { unhex(try text(key)) }
    private func list(_ key: String) throws -> [String] { try text(key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
}

private final class BundleToken {}

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
private func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { hex(Data($0)) } }

private func unhex(_ string: String) -> Data {
    var data = Data(capacity: string.count / 2)
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16) ?? 0)
        index = next
    }
    return data
}
