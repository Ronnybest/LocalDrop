import CryptoKit
import Foundation
import Testing
@testable import LocalDrop

/// ClientSession end to end against `FakeMac` on loopback: the handshake, pairing, sending and
/// receiving as the unchanged Mac runs them.
@Suite(.timeLimit(.minutes(1)))
struct SessionTests {
    private let directory: URL
    private let store: MacStore
    private let phone = Phone.test()

    init() throws {
        directory = try temporaryDirectory()
        store = MacStore(fileURL: directory.appending(path: "Dewlet/paired-macs.json"))
    }

    private func open(_ mac: FakeMac, expected: (deviceId: String, fingerprint: Data)? = nil) async throws(ClientError) -> ClientSession {
        try await ClientSession.open(to: .addresses(["127.0.0.1"], port: mac.port, quick: false), phone: phone, name: "Test iPhone",
                                     expected: expected, store: store)
    }

    @Test func pairing() async throws {
        let mac = try FakeMac()
        let server = Task { () throws -> (FakeMac.Peer, [String]) in
            let peer = try await mac.handshake(try await mac.accept())
            try await peer.channel.send(SessionStatus.pairingRequired.message(presenceKey: nil))
            #expect(try PairingMessages.confirmAccepted(await peer.channel.receive(timeout: 10, stage: "confirm")))
            try await peer.channel.send(PairingMessages.result(accepted: true, presenceKey: mac.presenceKey))
            return (peer, await mac.readUntilClosed(peer.channel))
        }
        let session = try await open(mac)
        guard case .pairingRequired(let code, let keyChanged) = session.status else { Issue.record("not pairing"); return }
        await session.confirmPairing()
        await session.confirmPairing() // at most once on the wire
        let paired = try await session.pairingResult()
        await session.close()
        let (peer, rest) = try await server.value

        #expect(code == peer.pairingCode && !keyChanged)
        #expect(peer.hello.deviceId == phone.deviceId && peer.hello.platform == "ios" && peer.hello.name == "Test iPhone")
        #expect(peer.hello.capabilities.contains("receive") && peer.hello.capabilities.contains("clipboardReceive"))
        #expect(!peer.auth.trusted && !peer.auth.keyChanged)
        #expect(rest == [MessageType.close])
        #expect(paired.id == mac.deviceId && paired.presenceKey == mac.presenceKey && paired.canSend && paired.takesClipboardText)
        let stored = try #require(store.mac(mac.deviceId))
        #expect(stored.publicKey == mac.identity.publicKeyX963 && stored.lastAddresses == ["127.0.0.1"] && stored.lastPort == mac.port)
        #expect(stored.presenceKey == mac.presenceKey)
    }

    @Test func pairingDeclinedOnTheMac() async throws {
        let mac = try FakeMac()
        let server = Task {
            let peer = try await mac.handshake(try await mac.accept())
            try await peer.channel.send(SessionStatus.pairingRequired.message(presenceKey: nil))
            try await peer.channel.send(PairingMessages.result(accepted: false))
            peer.frames.cancel()
        }
        let session = try await open(mac)
        await #expect(throws: ClientError.pairingRejected(byPeer: true)) { try await session.pairingResult() }
        try await server.value
        #expect(store.mac(mac.deviceId) == nil && session.isClosed)
    }

    @Test func keyChangedPairingCancelledHereSendsClose() async throws {
        let mac = try FakeMac()
        let server = Task { () throws -> (Bool, [String]) in
            let peer = try await mac.handshake(try await mac.accept())
            try await peer.channel.send(SessionStatus.keyChanged.message(presenceKey: nil))
            return (peer.auth.keyChanged, await mac.readUntilClosed(peer.channel))
        }
        // This iPhone knew the Mac's deviceId with another key.
        var old = mac.paired()
        old.publicKey = Data(repeating: 4, count: 65)
        try store.trust(old)
        let session = try await open(mac)
        guard case .pairingRequired(_, let keyChanged) = session.status else { Issue.record("not pairing"); return }
        #expect(keyChanged)
        await session.declinePairing()
        await session.close()
        let (toldKeyChanged, rest) = try await server.value
        #expect(toldKeyChanged)
        #expect(rest == [MessageType.pairingConfirm, MessageType.close])
        #expect(store.mac(mac.deviceId)?.publicKey == old.publicKey)
    }

    @Test func trustedSessionSendsReceivesAndRemembers() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let photo = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0) })
        let incoming = Data("from the Mac".utf8)
        let server = Task { () throws -> ([String: Data], String, [String]) in
            let peer = try await mac.trustedSession()
            let files = try await mac.receiveTransfer(peer.channel, request: try await peer.channel.receive(timeout: 10, stage: "request"))
            let text = try TextMessage(await peer.channel.receive(timeout: 10, stage: "text"))
            try await peer.channel.send(TransferMessages.textResult(text.transferId, copied: true))

            try await peer.channel.receive(timeout: 10, stage: "receive_ready").expect(MessageType.receiveReady)
            try await peer.channel.send(OutgoingMessages.text(Data(count: 16), text: "clipboard from the Mac"))
            try await peer.channel.receive(timeout: 5, stage: "text_result").expect(MessageType.textResult)
            try await mac.sendDelivery(peer.channel, files: [("../evil:name.txt", incoming), ("empty", Data())])
            try await peer.channel.send(OutgoingMessages.nothingPending)
            return (files, text.text, await mac.readUntilClosed(peer.channel))
        }

        let source = directory.appending(path: "IMG_0001.HEIC")
        try photo.write(to: source)
        let empty = directory.appending(path: "empty.txt")
        try Data().write(to: empty)
        let session = try await ClientSession.open(to: mac.paired(), phone: phone, name: "Test iPhone", store: store)
        #expect(session.status == .trusted)
        let reports = Reports()
        try await session.send([try OutgoingItem.file(source), try OutgoingItem.file(empty)], progress: { reports.append($0) })
        try await session.send(text: "hello")
        let inbox = directory.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let offers = OfferLog()
        let items = try await session.receive(into: inbox, automatically: false, decide: { offers.append($0); return true }, progress: { _ in })
        await session.close()
        let (files, text, rest) = try await server.value

        #expect(files["IMG_0001.HEIC"] == photo && files["empty.txt"] == Data())
        #expect(text == "hello")
        #expect(rest == [MessageType.close])
        #expect(reports.all.first?.phase == .waitingForAcceptance && reports.all.last?.phase == .verifying && reports.all.last?.fraction == 1)
        #expect(offers.all == [IncomingOffer(macName: "Fake Mac", fileCount: 2, totalSize: Int64(incoming.count), firstName: "evil_name.txt")])
        guard items.count == 3, case .text(let clipboard) = items[0], case .file(let url, let name, _, let size) = items[1] else {
            Issue.record("unexpected items \(items)")
            return
        }
        #expect(clipboard == "clipboard from the Mac")
        #expect(name == "evil_name.txt" && size == Int64(incoming.count) && url.deletingLastPathComponent().standardizedFileURL == inbox.standardizedFileURL)
        #expect(try Data(contentsOf: url) == incoming)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).sorted() == ["empty", "evil_name.txt"])
        #expect(store.mac(mac.deviceId)?.presenceKey == mac.presenceKey)
    }

    @Test func aDeclinedTransferKeepsTheSession() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task { () throws -> [String] in
            let peer = try await mac.trustedSession()
            let request = try TransferRequest(await peer.channel.receive(timeout: 10, stage: "request"))
            try await peer.channel.send(TransferMessages.reject(request.transferId, reason: .declined, fileCount: 1))
            let text = try TextMessage(await peer.channel.receive(timeout: 10, stage: "text"))
            try await peer.channel.send(TransferMessages.textResult(text.transferId, copied: false))
            return await mac.readUntilClosed(peer.channel)
        }
        let file = directory.appending(path: "a.pdf")
        try Data(count: 10).write(to: file)
        let session = try await ClientSession.open(to: mac.paired(), phone: phone, name: "Test iPhone", store: store)
        await #expect(throws: ClientError.transferRejected(reason: "declined")) { try await session.send([try OutgoingItem.file(file)], progress: { _ in }) }
        await #expect(throws: ClientError.transferRejected(reason: "declined")) { try await session.send(text: "hi") }
        #expect(!session.isClosed)
        await session.close()
        #expect(try await server.value == [MessageType.close])
    }

    @Test func aFileFailingOnTheMacIsReported() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task {
            let peer = try await mac.trustedSession()
            let request = try TransferRequest(await peer.channel.receive(timeout: 10, stage: "request"))
            try await peer.channel.send(TransferMessages.accept(request.transferId, fileCount: 1))
            _ = try FileBegin(await peer.channel.receive(timeout: 5, stage: "file_begin"))
            _ = try FileChunk(await peer.channel.receive(timeout: 5, stage: "chunk"))
            // TransferReceiver.reportFailure, then the session ends. (The Mac closes at once; read on
            // here so the test doesn't depend on which side's reset comes first.)
            try await peer.channel.send(TransferMessages.fileResult(request.transferId, fileId: 0, ok: false, code: ErrorCode.writeFailed))
            try await peer.channel.send(TransferMessages.transferResult(request.transferId, completed: false, code: ErrorCode.writeFailed))
            _ = await mac.readUntilClosed(peer.channel)
        }
        let file = directory.appending(path: "big.bin")
        try Data(count: 3_000_000).write(to: file)
        let session = try await ClientSession.open(to: mac.paired(), phone: phone, name: "Test iPhone", store: store)
        await #expect(throws: ClientError.receiverFailed(code: ErrorCode.writeFailed)) { try await session.send([try OutgoingItem.file(file)], progress: { _ in }) }
        try await server.value
        #expect(session.isClosed)
    }

    @Test func cancellingADeliveryHereTellsTheMac() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task { () throws -> [String] in
            let peer = try await mac.trustedSession()
            try await peer.channel.receive(timeout: 10, stage: "receive_ready").expect(MessageType.receiveReady)
            try await peer.channel.send(OutgoingMessages.request(Data(repeating: 3, count: 16), files: [
                TransferFileInfo(fileId: 0, name: "movie.mov", mimeType: "video/quicktime", size: 5, lastModified: nil),
            ]))
            // TransferSender closes as soon as it reads the cancel.
            let cancel = try await peer.channel.receive(timeout: 10, stage: "acceptance")
            peer.frames.cancel()
            return [cancel.type, try cancel.text("reason")]
        }
        let session = try await ClientSession.open(to: mac.paired(), phone: phone, name: "Test iPhone", store: store)
        let asked = OfferLog()
        await #expect(throws: ClientError.cancelled) {
            try await session.receive(into: directory, automatically: false, decide: { offer in
                asked.append(offer)
                session.cancel()
                try? await Task.sleep(for: .seconds(30))
                return true
            }, progress: { _ in })
        }
        #expect(try await server.value == [MessageType.cancel, "user_cancelled"])
        #expect(asked.all.count == 1 && session.isClosed)
    }

    @Test func theMacCancellingWhileThisIPhoneDecides() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task {
            let peer = try await mac.trustedSession()
            try await peer.channel.receive(timeout: 10, stage: "receive_ready").expect(MessageType.receiveReady)
            let transferId = Data(repeating: 3, count: 16)
            try await peer.channel.send(OutgoingMessages.request(transferId, files: [
                TransferFileInfo(fileId: 0, name: "a.zip", mimeType: "application/zip", size: 5, lastModified: nil),
            ]))
            try await Task.sleep(for: .milliseconds(200))
            try await peer.channel.send(TransferMessages.cancel(transferId, reason: "user_cancelled"))
            peer.frames.cancel()
        }
        let session = try await ClientSession.open(to: mac.paired(), phone: phone, name: "Test iPhone", store: store)
        await #expect(throws: ClientError.cancelledByPeer) {
            try await session.receive(into: directory, automatically: false, decide: { _ in
                try? await Task.sleep(for: .seconds(30))
                return true
            }, progress: { _ in })
        }
        try await server.value
    }

    @Test func deliveriesBeforeAFailureAreHandedOut() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task {
            let peer = try await mac.trustedSession()
            try await peer.channel.receive(timeout: 10, stage: "receive_ready").expect(MessageType.receiveReady)
            try await peer.channel.send(OutgoingMessages.text(Data(count: 16), text: "copied first"))
            try await peer.channel.receive(timeout: 5, stage: "text_result").expect(MessageType.textResult)
            try await mac.sendDelivery(peer.channel, files: [("notes.txt", Data("notes".utf8))])
            // The next delivery is cancelled on the Mac while this iPhone decides.
            let transferId = Data(repeating: 5, count: 16)
            try await peer.channel.send(OutgoingMessages.request(transferId, files: [
                TransferFileInfo(fileId: 0, name: "b.zip", mimeType: "application/zip", size: 5, lastModified: nil),
            ]))
            try await Task.sleep(for: .milliseconds(200))
            try await peer.channel.send(TransferMessages.cancel(transferId, reason: "user_cancelled"))
            peer.frames.cancel()
        }
        let session = try await ClientSession.open(to: mac.paired(), phone: phone, name: "Test iPhone", store: store)
        let delivered = DeliveryLog()
        await #expect(throws: ClientError.cancelledByPeer) {
            try await session.receive(into: directory, automatically: false, decide: { offer in
                if offer.firstName == "b.zip" { try? await Task.sleep(for: .seconds(30)) }
                return true
            }, progress: { _ in }, delivered: { delivered.append($0) })
        }
        try await server.value
        let batches = delivered.all
        guard batches.count == 2, case .text(let text)? = batches[0].first, case .file(_, let name, _, _)? = batches[1].first else {
            Issue.record("unexpected deliveries \(batches)")
            return
        }
        #expect(text == "copied first" && name == "notes.txt")
    }

    @Test func aFileGoneBeforeTheRequestKeepsTheSession() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task { () throws -> [String] in
            await mac.readUntilClosed(try await mac.trustedSession().channel)
        }
        let file = directory.appending(path: "gone.pdf")
        try Data(count: 10).write(to: file)
        let item = try OutgoingItem.file(file)
        try FileManager.default.removeItem(at: file)
        let session = try await ClientSession.open(to: mac.paired(), phone: phone, name: "Test iPhone", store: store)
        await #expect(throws: ClientError.sourceUnavailable(name: "gone.pdf")) { try await session.send([item], progress: { _ in }) }
        #expect(!session.isClosed)
        await session.close()
        #expect(try await server.value == [MessageType.close])
    }

    @Test func trustIsMutual() async throws {
        // A Mac saying trusted to a client that doesn't know its key is lying.
        let liar = try FakeMac()
        let liarServer = Task { () throws -> String? in
            let peer = try await liar.handshake(try await liar.accept())
            #expect(!peer.auth.trusted)
            try await peer.channel.send(SessionStatus.trusted.message(presenceKey: liar.presenceKey))
            do {
                _ = try await peer.channel.receive(timeout: 5, stage: "error")
                return nil
            } catch SessionError.peerError(let code, _) {
                return code
            }
        }
        await #expect(throws: ClientError.protocolViolation("session_status trusted for an untrusted key")) { try await open(liar) }
        #expect(try await liarServer.value == ErrorCode.badMessage)
        #expect(store.mac(liar.deviceId) == nil)

        // A key change only this iPhone sees is shown all the same.
        let other = try FakeMac()
        var old = other.paired()
        old.publicKey = Data(repeating: 4, count: 65)
        try store.trust(old)
        let otherServer = Task { () throws -> [String] in
            let peer = try await other.handshake(try await other.accept())
            try await peer.channel.send(SessionStatus.pairingRequired.message(presenceKey: nil))
            return await other.readUntilClosed(peer.channel)
        }
        let session = try await open(other)
        guard case .pairingRequired(_, let keyChanged) = session.status else { Issue.record("not pairing"); return }
        #expect(keyChanged)
        await session.close()
        #expect(try await otherServer.value == [MessageType.close])
    }

    @Test func notTrustedByTheMac() async throws {
        let mac = try FakeMac()
        try store.trust(mac.paired())
        let server = Task {
            let peer = try await mac.handshake(try await mac.accept())
            // ServerSession: not trusted and not in pairing mode.
            try await peer.channel.send(ErrorMessage(code: ErrorCode.pairingUnavailable).message)
            peer.frames.cancel()
            let second = try await mac.handshake(try await mac.accept())
            try await second.channel.send(SessionStatus.pairingRequired.message(presenceKey: nil))
            return await mac.readUntilClosed(second.channel)
        }
        await #expect(throws: ClientError.notPaired) { try await ClientSession.open(to: mac.paired(), phone: phone, name: "Test iPhone", store: store) }
        // In pairing mode the Mac already shows its prompt: it is told to drop it.
        await #expect(throws: ClientError.notPaired) { try await ClientSession.open(to: mac.paired(), phone: phone, name: "Test iPhone", store: store) }
        #expect(try await server.value == [MessageType.close])
    }

    @Test func handshakeRefusals() async throws {
        // A plaintext error{busy} instead of server_hello (4 sessions on the Mac).
        let busy = try FakeMac()
        let busyServer = Task {
            let frames = try await busy.accept()
            _ = try await frames.receiveFrame(timeout: 5, stage: "client_hello")
            try await frames.sendFrame(ErrorMessage(code: ErrorCode.busy).message.encoded())
            frames.cancel()
        }
        await #expect(throws: ClientError.peerError(code: ErrorCode.busy)) { try await open(busy) }
        try await busyServer.value
        #expect(ClientError.peerError(code: ErrorCode.busy).isTemporary)

        // EOF before server_hello (identity not loaded yet): temporary.
        let silent = try FakeMac()
        let silentServer = Task { (try await silent.accept()).cancel() }
        await #expect(throws: ClientError.connectionLost) { try await open(silent) }
        try await silentServer.value

        // A plaintext error where server_auth belongs (the Mac failed the nonce commitment).
        let plain = try FakeMac()
        let plainServer = Task {
            let frames = try await plain.accept()
            _ = try await frames.receiveFrame(timeout: 5, stage: "client_hello")
            let hello = ServerHello(version: 1, deviceId: plain.deviceId, name: "Mac", platform: "macos", identityKey: plain.identity.publicKeyX963,
                                    ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, nonce: Data(count: 32), capabilities: [])
            try await frames.sendFrame(hello.message.encoded())
            _ = try await frames.receiveFrame(timeout: 5, stage: "client_nonce")
            try await frames.sendFrame(ErrorMessage(code: ErrorCode.authFailed).message.encoded())
            frames.cancel()
        }
        await #expect(throws: ClientError.peerError(code: ErrorCode.authFailed)) { try await open(plain) }
        try await plainServer.value

        // A different key than the paired one: the client says why in plaintext and closes.
        let other = try FakeMac()
        let otherServer = Task { () throws -> String in
            let frames = try await other.accept()
            _ = try await frames.receiveFrame(timeout: 5, stage: "client_hello")
            let hello = ServerHello(version: 1, deviceId: other.deviceId, name: "Mac", platform: "macos", identityKey: other.identity.publicKeyX963,
                                    ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, nonce: Data(count: 32), capabilities: [])
            try await frames.sendFrame(hello.message.encoded())
            return try ErrorMessage(Message.decode(try await frames.receiveFrame(timeout: 5, stage: "error"))).code
        }
        await #expect(throws: ClientError.authenticationFailed) { try await open(other, expected: (other.deviceId, Data(count: 32))) }
        #expect(try await otherServer.value == ErrorCode.authFailed)

        // Version 2 only.
        let future = try FakeMac()
        let futureServer = Task {
            let frames = try await future.accept()
            _ = try await frames.receiveFrame(timeout: 5, stage: "client_hello")
            let hello = ServerHello(version: 2, deviceId: future.deviceId, name: "Mac", platform: "macos", identityKey: future.identity.publicKeyX963,
                                    ephemeralKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, nonce: Data(count: 32), capabilities: [])
            try await frames.sendFrame(hello.message.encoded())
        }
        await #expect(throws: ClientError.incompatibleVersion) { try await open(future) }
        try await futureServer.value
    }

    @Test func connectorOrderAndFailures() async throws {
        // A closed port on loopback refuses at once.
        let closed = try FakeMac()
        let port = closed.port
        _ = consume closed
        await #expect(throws: ClientError.refused) { try await Connector.connect(addresses: ["127.0.0.1"], port: port, quick: true) }
        await #expect(throws: ClientError.self) { try await Connector.connect(addresses: ["not an address"], port: port, quick: true) }

        // Malformed addresses are skipped, loopback is tried unbound.
        let mac = try FakeMac()
        let server = Task { (try await mac.accept()).cancel() }
        let (socket, address) = try await Connector.connect(addresses: ["bogus", "::1", "127.0.0.1"], port: mac.port, quick: true)
        #expect(address == "127.0.0.1") // IPv4 first; the fake listens on IPv4 only
        socket.close()
        try await server.value
    }
}

nonisolated final class DeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[ReceivedItem]] = []
    var all: [[ReceivedItem]] { lock.withLock { batches } }
    func append(_ items: [ReceivedItem]) { lock.withLock { batches.append(items) } }
}

nonisolated final class OfferLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [IncomingOffer] = []
    var all: [IncomingOffer] { lock.withLock { items } }
    func append(_ offer: IncomingOffer) { lock.withLock { items.append(offer) } }
}
