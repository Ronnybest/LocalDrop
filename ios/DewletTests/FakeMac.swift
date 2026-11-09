import CryptoKit
import Darwin
import Foundation
import Testing
@testable import LocalDrop

/// A stand-in for the Mac's `ServerSession` on 127.0.0.1, put together from the Mac's own
/// protocol code (ClientHello/ClientAuth parsers, ServerHello and status builders,
/// HandshakeCrypto, SecureChannel with the server's keys, the transfer parsers and builders).
/// Each test scripts what the Mac does after the handshake.
nonisolated final class FakeMac: Sendable {
    static let capabilities = ["files", "multipleFiles", "text", "clipboardReceive", "autoAccept", "presenceToken", "send"]

    let identity = Identity(privateKey: P256.Signing.PrivateKey())
    let deviceId = UUID().uuidString.lowercased()
    let presenceKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    let port: UInt16
    private let listener: Int32

    struct Peer: Sendable {
        let hello: ClientHello
        let auth: ClientAuth
        let channel: SecureChannel
        let frames: FrameConnection
        let pairingCode: String
    }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard fd >= 0, bound == 0, named == 0, listen(fd, 4) == 0 else { throw SessionError.transport("listen failed") }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { Darwin.close(listener) }

    /// The paired record this iPhone would have for this Mac.
    func paired(addresses: [String] = ["127.0.0.1"]) -> PairedMac {
        PairedMac(id: deviceId, name: "Fake Mac", publicKey: identity.publicKeyX963, fingerprint: identity.fingerprint, presenceKey: nil,
                  capabilities: Self.capabilities, lastAddresses: addresses, lastPort: port, firstSeen: Date(), lastSeen: Date(),
                  receiveAutomatically: false)
    }

    /// The next connection, as the Mac's listener hands it to a session.
    func accept() async throws -> FrameConnection {
        let listener = listener
        let fd = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global().async {
                var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                continuation.resume(returning: poll(&entry, 1, 10_000) > 0 ? Darwin.accept(listener, nil, nil) : -1)
            }
        }
        guard fd >= 0 else { throw SessionError.timeout(stage: "accept") }
        let socket = TCPSocket(fd: fd, remoteAddress: "127.0.0.1")
        socket.configure()
        return FrameConnection(socket: socket)
    }

    /// `ServerSession.handshake`, up to and including the client's verified `client_auth`.
    func handshake(_ frames: FrameConnection) async throws -> Peer {
        let (helloPayload, helloFrame) = try await frames.receiveFrameWithWire(timeout: 5, stage: "client_hello")
        let hello = try ClientHello(Message.decodeHandshake(helloPayload))
        let clientIdentity = try P256.Signing.PublicKey(x963Representation: hello.identityKey)
        let clientEphemeral = try P256.KeyAgreement.PublicKey(x963Representation: hello.ephemeralKey)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let serverHello = ServerHello(version: 1, deviceId: deviceId, name: "Fake Mac", platform: "macos", identityKey: identity.publicKeyX963,
                                      ephemeralKey: ephemeral.publicKey.x963Representation,
                                      nonce: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }), capabilities: Self.capabilities)
        let serverHelloFrame = try await frames.sendFrame(serverHello.message.encoded())
        let (noncePayload, nonceFrame) = try await frames.receiveFrameWithWire(timeout: 5, stage: "client_nonce")
        let nonce = try ClientNonce(Message.decodeHandshake(noncePayload))
        guard Data(SHA256.hash(data: nonce.nonce)) == hello.nonceCommit else { throw SessionError.authFailed("nonce commitment") }
        let transcript = HandshakeCrypto.transcriptHash([helloFrame, serverHelloFrame, nonceFrame])
        let keys = try HandshakeCrypto.deriveKeys(ephemeral: ephemeral, peerEphemeral: clientEphemeral, transcriptHash: transcript)
        let channel = SecureChannel(frames: frames, sendKey: keys.serverToClient, receiveKey: keys.clientToServer)
        let signature = try identity.privateKey.signature(for: HandshakeCrypto.authPayload(label: HandshakeCrypto.serverAuthLabel, transcriptHash: transcript))
        try await channel.send(Message(type: MessageType.serverAuth, body: ["sig": .bytes(signature.derRepresentation)]))
        let auth = try ClientAuth(await channel.receive(timeout: 5, stage: "client_auth"))
        let clientSignature = try P256.Signing.ECDSASignature(derRepresentation: auth.signature)
        guard clientIdentity.isValidSignature(clientSignature, for: HandshakeCrypto.authPayload(label: HandshakeCrypto.clientAuthLabel, transcriptHash: transcript)) else {
            throw SessionError.authFailed("client signature")
        }
        return Peer(hello: hello, auth: auth, channel: channel, frames: frames, pairingCode: HandshakeCrypto.pairingCode(sasBits: keys.sasBits))
    }

    /// Accept → handshake → `session_status{trusted, presenceKey}`.
    func trustedSession() async throws -> Peer {
        let peer = try await handshake(try await accept())
        #expect(peer.auth.trusted && !peer.auth.keyChanged)
        try await peer.channel.send(SessionStatus.trusted.message(presenceKey: presenceKey))
        return peer
    }

    /// `TransferReceiver` accepting everything: returns what arrived, by name.
    func receiveTransfer(_ channel: SecureChannel, request message: Message) async throws -> [String: Data] {
        let request = try TransferRequest(message)
        try await channel.send(TransferMessages.accept(request.transferId, fileCount: request.files.count))
        var received: [String: Data] = [:]
        for file in request.files {
            let begin = try FileBegin(await channel.receive(timeout: 5, stage: "file_begin"))
            #expect(begin.fileId == file.fileId && begin.offset == 0 && begin.transferId == request.transferId)
            var data = Data()
            while data.count < file.size {
                let chunk = try FileChunk(await channel.receive(timeout: 5, stage: "file data"))
                #expect(chunk.offset == Int64(data.count) && chunk.fileId == file.fileId)
                data.append(chunk.data)
            }
            let end = try FileEnd(await channel.receive(timeout: 5, stage: "file_end"))
            #expect(end.sha256 == Data(SHA256.hash(data: data)))
            try await channel.send(TransferMessages.fileResult(request.transferId, fileId: file.fileId, ok: true))
            received[file.name] = data
        }
        let complete = try await channel.receive(timeout: 5, stage: "transfer_complete")
        try complete.expect(MessageType.transferComplete)
        try await channel.send(TransferMessages.transferResult(request.transferId, completed: true))
        return received
    }

    /// `TransferSender` for one delivery the phone accepts.
    func sendDelivery(_ channel: SecureChannel, files: [(name: String, data: Data)]) async throws {
        let transferId = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let infos = files.enumerated().map { TransferFileInfo(fileId: $0, name: $1.name, mimeType: "application/octet-stream", size: Int64($1.data.count), lastModified: 1_700_000_000_000) }
        try await channel.send(OutgoingMessages.request(transferId, files: infos))
        let answer = try await channel.receive(timeout: 10, stage: "acceptance")
        try answer.expect(MessageType.transferAccept)
        #expect(try answer.uint("fileCount") == UInt64(files.count))
        for (index, file) in files.enumerated() {
            try await channel.send(OutgoingMessages.fileBegin(transferId, fileId: index))
            var offset = 0
            while offset < file.data.count {
                let piece = file.data[offset..<min(offset + 1000, file.data.count)]
                try await channel.sendPipelined(OutgoingMessages.fileChunk(transferId, fileId: index, offset: Int64(offset), data: Data(piece)))
                offset += piece.count
            }
            try await channel.send(OutgoingMessages.fileEnd(transferId, fileId: index, sha256: Data(SHA256.hash(data: file.data))))
            let result = try await channel.receive(timeout: 5, stage: "file_result")
            try result.expect(MessageType.fileResult)
            #expect(try result.bool("ok"))
        }
        try await channel.send(OutgoingMessages.transferComplete(transferId))
        let result = try await channel.receive(timeout: 5, stage: "transfer_result")
        try result.expect(MessageType.transferResult)
        #expect(try result.text("status") == "completed")
    }

    /// Reads until this iPhone closes, or sends `close` (then closes, as `ServerSession` does);
    /// returns the message types it read.
    func readUntilClosed(_ channel: SecureChannel) async -> [String] {
        var types: [String] = []
        while let message = try? await channel.receive(timeout: 10, stage: "rest") {
            types.append(message.type)
            if message.type == MessageType.close { break }
        }
        await channel.closeConnection()
        return types
    }
}

extension Phone {
    nonisolated static func test() -> Phone {
        Phone(deviceId: UUID().uuidString.lowercased(), identity: Identity(privateKey: P256.Signing.PrivateKey()))
    }
}

nonisolated func temporaryDirectory() throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "DewletTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
