import CryptoKit
import Foundation
import Testing
@testable import LocalDrop

/// The client direction of protocol/test-vectors.properties, and every message this iPhone
/// builds or parses checked against the Mac's own parsers and builders (Messages.swift,
/// TransferMessages.swift), which the unchanged Mac runs.
struct ClientProtocolTests {
    private let vectors: [String: String]

    init() throws {
        let url = try #require(Bundle(for: VectorsToken.self).url(forResource: "test-vectors", withExtension: "properties"))
        var vectors: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            vectors[line[..<equals].trimmingCharacters(in: .whitespaces)] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        self.vectors = vectors
    }

    @Test func keyScheduleFromTheClientSide() throws {
        let client = try P256.KeyAgreement.PrivateKey(rawRepresentation: try bytes("handshake.clientEphemeralPrivate"))
        let server = try P256.KeyAgreement.PrivateKey(rawRepresentation: try bytes("handshake.serverEphemeralPrivate"))
        let transcript = HandshakeCrypto.transcriptHash(try list("handshake.frames").map(unhex))
        let keys = try HandshakeCrypto.deriveKeys(ephemeral: client, peerEphemeral: server.publicKey, transcriptHash: transcript)
        #expect(hex(keys.clientToServer) == (try text("handshake.clientToServerKey")))
        #expect(hex(keys.serverToClient) == (try text("handshake.serverToClientKey")))
        #expect(HandshakeCrypto.pairingCode(sasBits: keys.sasBits) == (try text("handshake.pairingCode")))

        // What the client seals with client→server opens on the Mac's side with the same key, and the other way round.
        let serverKeys = try HandshakeCrypto.deriveKeys(ephemeral: server, peerEphemeral: client.publicKey, transcriptHash: transcript)
        var clientSend = FrameCipher(key: keys.clientToServer)
        var macReceive = FrameCipher(key: serverKeys.clientToServer)
        var macSend = FrameCipher(key: serverKeys.serverToClient)
        var clientReceive = FrameCipher(key: keys.serverToClient)
        for word in ["client_auth", "close"] {
            #expect(String(decoding: try macReceive.open(try clientSend.seal(Data(word.utf8))), as: UTF8.self) == word)
            #expect(String(decoding: try clientReceive.open(try macSend.seal(Data(word.utf8))), as: UTF8.self) == word)
        }
        // frames.key is the vectors' client→server key: the client's first two frames.
        var sender = FrameCipher(key: SymmetricKey(data: try bytes("frames.key")))
        #expect(try list("frames.plaintexts").map { hex(try sender.seal(Data($0.utf8))) } == (try list("frames.sealed")))
    }

    @Test func clientHelloPassesTheMacParser() throws {
        let identity = P256.Signing.PrivateKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let deviceId = UUID().uuidString.lowercased()
        let hello = ClientHello(deviceId: deviceId, name: ClientHello.wireName("Zeppon’s iPhone"), identityKey: identity.publicKey.x963Representation,
                                ephemeralKey: ephemeral.publicKey.x963Representation, nonceCommit: Data(repeating: 7, count: 32))
        let parsed = try ClientHello(Message.decodeHandshake(hello.message.encoded()))
        #expect(parsed.version == 1 && parsed.minVersion == 1)
        #expect(parsed.deviceId == deviceId)
        #expect(parsed.name == "Zeppon’s iPhone")
        #expect(parsed.platform == "ios")
        #expect(parsed.capabilities == ["files", "multipleFiles", "text", "receive", "clipboardReceive"])
        #expect(parsed.identityKey.count == 65 && parsed.ephemeralKey.count == 65 && parsed.nonceCommit.count == 32)
        // Deterministic key order, as on Android: t, v, id, eph, caps, minV, name, idKey, platform, nonceCommit.
        let encoded = hello.message.encoded()
        let order = ["t", "v", "id", "eph", "caps", "minV", "name", "idKey", "platform", "nonceCommit"].compactMap { key in
            encoded.range(of: CBOR.encode(.text(key)))?.lowerBound
        }
        #expect(order == order.sorted() && order.count == 10)
    }

    @Test func wireNameFitsTheMacLimits() {
        #expect(ClientHello.wireName("  \u{7}iPhone\n ") == "iPhone")
        #expect(ClientHello.wireName("   ") == "iPhone")
        #expect(ClientHello.wireName(String(repeating: "a", count: 100)).count == 64)
        let wide = ClientHello.wireName(String(repeating: "😀", count: 100))
        #expect(wide.utf8.count <= ClientHello.maxNameBytes && wide.count == 64)
    }

    @Test func clientAuthPassesTheMacParser() throws {
        for (trusted, keyChanged) in [(true, false), (false, false), (false, true)] {
            let auth = try ClientAuth(Message.decode(ClientAuth.message(signature: Data([1, 2, 3]), trusted: trusted, keyChanged: keyChanged).encoded()))
            #expect(auth.signature == Data([1, 2, 3]) && auth.trusted == trusted && auth.keyChanged == keyChanged)
        }
        #expect(try ClientNonce(Message.decodeHandshake(ClientNonce.message(Data(repeating: 1, count: 32)).encoded())).nonce.count == 32)
        #expect(try PairingMessages.confirmAccepted(Message.decode(PairingMessages.confirm(accepted: true).encoded())))
        #expect(try !PairingMessages.confirmAccepted(Message.decode(PairingMessages.confirm(accepted: false).encoded())))
    }

    @Test func macBuiltHandshakeMessagesParse() throws {
        let built = ServerHello(version: 1, deviceId: "8C67F637-C4E3-4767-975B-C844D33D6947", name: "MacBook Pro", platform: "macos",
                                identityKey: Data(repeating: 4, count: 65), ephemeralKey: Data(repeating: 5, count: 65),
                                nonce: Data(repeating: 6, count: 32), capabilities: ["files", "clipboardReceive", "send"])
        let hello = try ServerHello(Message.decodeHandshake(built.message.encoded()))
        #expect(hello.deviceId == built.deviceId && hello.name == "MacBook Pro" && hello.platform == "macos")
        #expect(hello.capabilities == ["files", "clipboardReceive", "send"] && hello.nonce.count == 32)

        let key = Data(repeating: 9, count: 32)
        let trusted = try SessionStatus.parse(Message.decode(SessionStatus.trusted.message(presenceKey: key).encoded()))
        #expect(trusted.status == .trusted && trusted.presenceKey == key)
        let pairing = try SessionStatus.parse(Message.decode(SessionStatus.pairingRequired.message(presenceKey: key).encoded()))
        #expect(pairing.status == .pairingRequired && pairing.presenceKey == nil)
        #expect(try SessionStatus.parse(Message.decode(SessionStatus.keyChanged.message(presenceKey: nil).encoded())).status == .keyChanged)
        // Only a 32-byte presence key counts.
        let short = Message(type: MessageType.sessionStatus, body: ["status": .text("trusted"), "presenceKey": .bytes(Data(count: 5))])
        #expect(try SessionStatus.parse(short).presenceKey == nil)
        #expect(throws: SessionError.self) { try SessionStatus.parse(Message(type: MessageType.sessionStatus, body: ["status": .text("maybe")])) }

        let accepted = try PairingMessages.parseResult(Message.decode(PairingMessages.result(accepted: true, presenceKey: key).encoded()))
        #expect(accepted.accepted && accepted.presenceKey == key)
        let declined = try PairingMessages.parseResult(Message.decode(PairingMessages.result(accepted: false, presenceKey: key).encoded()))
        #expect(!declined.accepted && declined.presenceKey == nil)

        // A Mac's error frame in plaintext: what decodeHandshake (server_hello) turns into a peer error.
        #expect(throws: SessionError.peerError(code: "busy", detail: nil)) {
            try Message.decodeHandshake(ErrorMessage(code: ErrorCode.busy).message.encoded())
        }
    }

    @Test func sealedEndpointInfoOpens() throws {
        let key = PresenceKey(raw: try bytes("presence.key"))
        let sealed = try EndpointInfo(decoding: try bytes("endpoint.sealed"), presenceKey: key)
        #expect(sealed.deviceId == (try text("endpoint.sealed.deviceId")))
        #expect(UInt64(sealed.port) == UInt64(try text("endpoint.sealed.port")))
        #expect(sealed.fingerprint.count == 32)
        // The open vector has no busy or caps (older Mac): both optional.
        let open = try EndpointInfo(decoding: try bytes("endpoint.cbor"), presenceKey: nil)
        #expect(open.platform == "macos" && !open.busy && open.capabilities.isEmpty)
        #expect(throws: SessionError.self) { try EndpointInfo(decoding: try bytes("endpoint.sealed"), presenceKey: nil) }
        // What the Mac seals today opens to what it encoded.
        let mine = EndpointInfo(protocolVersion: 1, deviceId: "id", deviceName: "Mac", platform: "macos", port: 51010,
                                addresses: ["192.168.1.15"], fingerprint: Data(count: 32), busy: true, capabilities: ["send"])
        #expect(try EndpointInfo(decoding: try mine.sealed(with: key), presenceKey: key) == mine)
    }

    @Test func macDeliveryRequestsOfAnySizeParse() throws {
        let files = (0..<1500).map { TransferFileInfo(fileId: $0, name: "IMG_\($0).HEIC", mimeType: "image/heic", size: 10, lastModified: -5) }
        let request = try IncomingRequest(Message.decode(OutgoingMessages.request(Data(count: 16), files: files).encoded()))
        #expect(request.files.count == 1500 && request.totalSize == 15000)
        #expect(request.files[1499].name == "IMG_1499.HEIC" && request.files[0].lastModified == -5)
        // The Mac's own receiver parser stops at 1000.
        #expect(throws: SessionError.self) { try TransferRequest(Message.decode(OutgoingMessages.request(Data(count: 16), files: files).encoded())) }

        let wrongTotal = Message(type: MessageType.transferRequest, body: [
            "transferId": .bytes(Data(count: 16)), "totalSize": .unsigned(3),
            "files": .array([.map(["fileId": .unsigned(0), "name": .text("a"), "size": .unsigned(2)])]),
        ])
        #expect(throws: SessionError.self) { try IncomingRequest(wrongTotal) }
        let noMime = try IncomingRequest(Message(type: MessageType.transferRequest, body: [
            "transferId": .bytes(Data(count: 16)), "totalSize": .unsigned(2),
            "files": .array([.map(["fileId": .unsigned(0), "name": .text("a.bin"), "size": .unsigned(2)])]),
        ]))
        #expect(noMime.files[0].mimeType == "application/octet-stream")
    }

    @Test func incomingNamesAreSanitized() {
        #expect(IncomingRequest.sanitize("../../etc/passwd") == "passwd")
        #expect(IncomingRequest.sanitize("C:\\Users\\a\\report.pdf") == "report.pdf")
        #expect(IncomingRequest.sanitize("what?:*\"<>|.txt") == "what_______.txt")
        #expect(IncomingRequest.sanitize("..hidden") == "hidden")
        #expect(IncomingRequest.sanitize(" \u{1}\u{7F} ") == "file")
        // A bidi override would show one name in the Accept prompt and save another.
        #expect(IncomingRequest.sanitize("invoice\u{202E}fdp.html") == "invoicefdp.html")
        #expect(IncomingRequest.sanitize("a\u{85}b\u{2066}.txt") == FileNames.sanitize("a\u{85}b\u{2066}.txt"))
        #expect(IncomingRequest.sanitize("dir/") == "file")
        let long = IncomingRequest.sanitize(String(repeating: "a", count: 300) + ".jpeg")
        #expect(long.count == 200 && long.hasSuffix(".jpeg"))
    }

    @Test func sessionErrorsMapForTheUI() {
        #expect(ClientError(SessionError.connectionClosed) == .connectionLost)
        #expect(ClientError(SessionError.transport("reset")) == .connectionLost)
        #expect(ClientError(SessionError.peerError(code: ErrorCode.versionUnsupported, detail: nil)) == .incompatibleVersion)
        #expect(ClientError(SessionError.peerError(code: ErrorCode.busy, detail: nil)) == .peerError(code: ErrorCode.busy))
        #expect(ClientError(SessionError.timeout(stage: "x")) == .timeout(stage: "x"))
        #expect(ClientError(SessionError.decryptFailed) == .decryptionFailed)

        #expect(ClientError.connectionLost.isTemporary)
        #expect(ClientError.peerError(code: ErrorCode.busy).isTemporary)
        #expect(!ClientError.peerError(code: ErrorCode.pairingUnavailable).isTemporary)
        #expect(ClientError.transferRejected(reason: "asleep").isTemporary)
        #expect(!ClientError.transferRejected(reason: "declined").isTemporary)
        #expect(!ClientError.cancelledByPeer.isTemporary)

        #expect(ClientError.protocolViolation("x").wireCode == ErrorCode.badMessage)
        #expect(ClientError.authenticationFailed.wireCode == ErrorCode.authFailed)
        #expect(ClientError.connectionLost.wireCode == nil)
        #expect(ClientError.refused.message(macName: "MacBook").contains("MacBook"))
        #expect(ClientError.peerError(code: "internal").message(macName: "MacBook").contains("internal"))
    }

    @Test func outgoingItemsCarryRealTypes() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "IMG_0001.HEIC")
        try Data(count: 3).write(to: url)
        let item = try OutgoingItem.file(url)
        #expect(item.name == "IMG_0001.HEIC" && item.mimeType == "image/heic" && item.size == 3 && item.modified != nil)
        #expect(try OutgoingItem.file(url, name: "clip.mov").mimeType == "video/quicktime")
        #expect(try OutgoingItem.file(url, name: "a/b:c.bin").name == "abc.bin")
        #expect(throws: ClientError.sourceUnavailable(name: "gone.txt")) { try OutgoingItem.file(directory.appending(path: "gone.txt")) }
        #expect(throws: ClientError.self) { try OutgoingItem.file(directory) }
    }

    @Test func progressReportsFractionAndSpeed() {
        let reports = Reports()
        var meter = ProgressMeter(totalBytes: 100, fileCount: 2, firstName: "a", report: { reports.append($0) })
        meter.update(phase: .transferring, force: true)
        meter.update(adding: 50, file: (0, "a"))
        meter.update(adding: 50, file: (1, "b"), phase: .verifying, force: true)
        #expect(meter.progress.fraction == 1 && meter.progress.fileIndex == 1 && meter.progress.phase == .verifying)
        #expect(reports.all.count == 2)
        #expect(TransferProgress(bytesDone: 0, totalBytes: 0, fileName: "", fileIndex: 0, fileCount: 1, bytesPerSecond: 0, phase: .verifying).fraction == 1)
    }

    private func text(_ key: String) throws -> String { try #require(vectors[key], "missing vector \(key)") }
    private func bytes(_ key: String) throws -> Data { unhex(try text(key)) }
    private func list(_ key: String) throws -> [String] { try text(key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
}

private final class VectorsToken {}

nonisolated final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TransferProgress] = []
    var all: [TransferProgress] { lock.withLock { items } }
    func append(_ progress: TransferProgress) { lock.withLock { items.append(progress) } }
}

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
