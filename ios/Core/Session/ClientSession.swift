import CryptoKit
import Foundation
import os

/// What the Mac said about itself in `server_hello`.
nonisolated struct MacHello: Sendable {
    /// Lowercase.
    let deviceId: String
    /// Cleaned up for display: it comes from the network.
    let name: String
    let platform: String
    let identityKey: Data
    let fingerprint: Data
    let capabilities: [String]
}

/// One authenticated TCP session to a Mac, this iPhone being the Initiator (Android
/// `HandshakeClient` + `TransferManager`; the Mac's `ServerSession` is the other end).
///
/// One operation at a time; operations may follow each other on the same session (send, then
/// receive, …): the Mac serves them in a loop until `close` or 120 s without a message. After the
/// handshake one task reads everything the Mac sends into an `Inbox`: the Mac may speak at any
/// time (a declined pairing, a cancel, a failed file), and every FrameConnection timeout is fatal.
/// Entry points are `@concurrent`: sockets, files and SHA-256 never run on the main actor.
nonisolated final class ClientSession: Sendable {
    enum Status: Sendable, Equatable {
        case trusted
        /// Both screens show `code` ("123 456"). `keyChanged`: one side knew the other with a different key.
        case pairingRequired(code: String, keyChanged: Bool)
    }

    enum Target: Sendable {
        case addresses([String], port: UInt16, quick: Bool)
        case bonjour(instance: String)
    }

    /// Each handshake step; the Mac allows 15 s too.
    static let handshakeTimeout: TimeInterval = 15
    /// Longer than the Mac's 120 s, so its own `pairing_timeout` arrives first.
    static let pairingTimeout: TimeInterval = 135
    /// After cancel{…}: how long the Mac gets to close first (critic.md "Cancel and RST").
    static let cancelDrain: TimeInterval = 2
    private static let closeDrain: TimeInterval = 1
    /// "No timeout" for the reader: FrameConnection fires a 0 s timeout at once.
    private static let readerTimeout: TimeInterval = 3600

    let mac: MacHello
    /// What the handshake said. After a successful `pairingResult()` the session is trusted too.
    let status: Status
    /// The address that answered.
    let address: String
    let port: UInt16

    /// Remembered as the Mac's endpoint once trust is settled: `address` first, then the others.
    let addresses: [String]
    let channel: ClientChannel
    let inbox = Inbox()
    let store: MacStore
    let state: OSAllocatedUnfairLock<SessionState>

    struct SessionState: Sendable {
        var trusted: Bool
        var pairingConfirmed = false
        var pairingDeclined = false
        /// An operation (send, receive) is running.
        var busy = false
        /// The transfer announced on the wire, which `cancel()` names.
        var transferId: Data?
        var cancelled = false
        var closing = false
    }

    private init(mac: MacHello, status: Status, address: String, port: UInt16, addresses: [String], channel: ClientChannel, store: MacStore) {
        self.mac = mac
        self.status = status
        self.address = address
        self.port = port
        self.addresses = addresses
        self.channel = channel
        self.store = store
        state = OSAllocatedUnfairLock(initialState: SessionState(trusted: status == .trusted))
    }

    /// A session dropped without `close()` would hold a Mac session slot until its 120 s idle timeout.
    deinit {
        guard !state.withLock({ $0.closing }) else { return }
        Task.detached { [channel] in
            try? await channel.send(Message(type: MessageType.close))
            channel.closeConnection()
        }
    }

    /// True once the socket closed: EOF, an error, `close()` or `cancel()`.
    var isClosed: Bool { state.withLock { $0.closing } || inbox.isEnded }

    // MARK: - Opening

    /// Connects (to the addresses in order, or to what Bonjour resolves) and runs the handshake.
    /// A trusted session's facts go into the store at once: name, caps, the presence key, the endpoint.
    /// - Parameter expected: the deviceId and fingerprint the Mac must have (a paired Mac); nil for pairing.
    @concurrent static func open(
        to target: Target, phone: Phone, name: String, expected: (deviceId: String, fingerprint: Data)?, store: MacStore = .shared
    ) async throws(ClientError) -> ClientSession {
        var expectedId = expected?.deviceId
        let addresses: [String]
        let port: UInt16
        let quick: Bool
        switch target {
        case .addresses(let list, let listPort, let isQuick):
            (addresses, port, quick) = (list, listPort, isQuick)
        case .bonjour(let instance):
            (addresses, port) = try await Connector.resolve(instance: instance)
            quick = false
            // The instance name is the Mac's deviceId, unless Bonjour renamed it after a conflict.
            if expectedId == nil, UUID(uuidString: instance) != nil { expectedId = instance }
        }
        let (socket, address) = try await Connector.connect(addresses: addresses, port: port, quick: quick)
        return try await handshake(socket, address: address, addresses: [address] + addresses.filter { $0 != address }, port: port,
                                   phone: phone, name: name, expectedId: expectedId, expectedFingerprint: expected?.fingerprint, store: store)
    }

    /// A paired Mac: its last endpoint first (2 s per address), then Bonjour by its deviceId when
    /// that fails in a way another address could fix (Android `TransferManager.establish`).
    /// Requires trust both ways: otherwise sends `close` — the Mac may already show a pairing
    /// prompt — and throws `.notPaired`.
    @concurrent static func open(to mac: PairedMac, phone: Phone, name: String, store: MacStore = .shared) async throws(ClientError) -> ClientSession {
        let expected = (deviceId: mac.id, fingerprint: mac.fingerprint)
        let session: ClientSession
        do throws(ClientError) {
            var remembered: ClientSession?
            if let port = mac.lastPort, !mac.lastAddresses.isEmpty {
                do {
                    remembered = try await open(to: .addresses(mac.lastAddresses, port: port, quick: true), phone: phone, name: name, expected: expected, store: store)
                } catch {
                    switch error {
                    case .refused, .unreachable, .timeout, .connectionLost, .authenticationFailed:
                        Log.connection.info("Remembered endpoint of \(mac.id, privacy: .public) failed (\(String(describing: error), privacy: .public)); trying Bonjour")
                    default:
                        throw error
                    }
                }
            }
            if let remembered {
                session = remembered
            } else {
                session = try await open(to: .bonjour(instance: mac.id), phone: phone, name: name, expected: expected, store: store)
            }
        } catch .peerError(code: ErrorCode.pairingUnavailable) {
            // Sent in place of session_status: the Mac doesn't trust this iPhone (or this store lost the Mac).
            throw .notPaired
        }
        guard session.status == .trusted else {
            Log.handshake.info("\(mac.id, privacy: .public) asks to pair again; closing")
            await session.close()
            throw .notPaired
        }
        return session
    }

    /// The Initiator side of the handshake (protocol.md §5, security.md §3; handshake.md §9).
    static func handshake(
        _ socket: TCPSocket, address: String, addresses: [String], port: UInt16, phone: Phone, name: String,
        expectedId: String?, expectedFingerprint: Data?, store: MacStore
    ) async throws(ClientError) -> ClientSession {
        let frames = FrameConnection(socket: socket)
        var channel: ClientChannel?
        do {
            // Everything for client_hello is ready before it goes: the Mac allows 15 s per step.
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let clientNonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            let hello = ClientHello(deviceId: phone.deviceId, name: ClientHello.wireName(name), identityKey: phone.identity.publicKeyX963,
                                    ephemeralKey: ephemeral.publicKey.x963Representation, nonceCommit: Data(SHA256.hash(data: clientNonce)))
            // The transcript hashes the frames exactly as written and read, length prefix included.
            let helloFrame = try await frames.sendFrame(hello.message.encoded())

            // A plaintext error{busy} (4 sessions) or {version_unsupported} may come instead; EOF
            // here is temporary too (the Mac still loading, or its busy error lost to a reset).
            let (serverHelloPayload, serverHelloFrame) = try await frames.receiveFrameWithWire(timeout: handshakeTimeout, stage: "server_hello")
            let serverHello = try ServerHello(Message.decodeHandshake(serverHelloPayload))
            guard (ProtocolConstants.minSupportedVersion...ProtocolConstants.version).contains(serverHello.version) else {
                throw ClientError.incompatibleVersion
            }
            let macId = serverHello.deviceId.lowercased()
            if let expectedId, macId != expectedId.lowercased() {
                Log.handshake.warning("A different device answered: \(macId, privacy: .public)")
                throw ClientError.authenticationFailed
            }
            let fingerprint = Data(SHA256.hash(data: serverHello.identityKey))
            // A hint only: a match proves nothing until the signature verifies.
            if let expectedFingerprint, fingerprint != expectedFingerprint {
                Log.handshake.warning("\(macId, privacy: .public) presented an unexpected identity key \(fingerprint.fingerprintLogPrefix, privacy: .public)…")
                throw ClientError.authenticationFailed
            }
            let macIdentityKey: P256.Signing.PublicKey
            let macEphemeral: P256.KeyAgreement.PublicKey
            do {
                macIdentityKey = try P256.Signing.PublicKey(x963Representation: serverHello.identityKey)
                macEphemeral = try P256.KeyAgreement.PublicKey(x963Representation: serverHello.ephemeralKey)
            } catch {
                throw ClientError.protocolViolation("invalid public key")
            }
            Log.handshake.info("server_hello from \(macId, privacy: .public) (\(serverHello.platform, privacy: .public), v\(serverHello.version))")

            let nonceFrame = try await frames.sendFrame(ClientNonce.message(clientNonce).encoded())
            let transcript = HandshakeCrypto.transcriptHash([helloFrame, serverHelloFrame, nonceFrame])
            let keys: HandshakeCrypto.SessionKeys
            do {
                keys = try HandshakeCrypto.deriveKeys(ephemeral: ephemeral, peerEphemeral: macEphemeral, transcriptHash: transcript)
            } catch {
                throw ClientError.authenticationFailed
            }
            let secure = ClientChannel(frames: frames, keys: keys)
            channel = secure

            // Verified before client_auth goes out.
            let serverAuth = try await secure.receive(timeout: handshakeTimeout, stage: "server_auth", plaintextError: true)
            try serverAuth.expect(MessageType.serverAuth)
            let signatureBytes = try serverAuth.bytes("sig")
            guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureBytes),
                  macIdentityKey.isValidSignature(signature, for: HandshakeCrypto.authPayload(label: HandshakeCrypto.serverAuthLabel, transcriptHash: transcript)) else {
                throw ClientError.authenticationFailed
            }

            // Trust is mutual: what this iPhone knows about the Mac goes into client_auth.
            let known = store.mac(macId)
            let trusted = known?.publicKey == serverHello.identityKey
            let keyChanged = known != nil && !trusted
            if keyChanged { Log.handshake.warning("Known Mac \(macId, privacy: .public) presented a different identity key") }
            let clientSignature: Data
            do {
                clientSignature = try phone.identity.privateKey.signature(
                    for: HandshakeCrypto.authPayload(label: HandshakeCrypto.clientAuthLabel, transcriptHash: transcript)
                ).derRepresentation
            } catch {
                throw ClientError.identityUnavailable
            }
            try await secure.send(ClientAuth.message(signature: clientSignature, trusted: trusted, keyChanged: keyChanged))

            // error{pairing_unavailable} may come in its place.
            let (status, presenceKey) = try SessionStatus.parse(await secure.receive(timeout: handshakeTimeout, stage: "session_status"))
            // Trust needs both sides (security.md §6): a Mac never says trusted to a client that doesn't know its key.
            guard status != .trusted || trusted else { throw ClientError.protocolViolation("session_status trusted for an untrusted key") }
            if keyChanged && status != .keyChanged { Log.handshake.warning("\(macId, privacy: .public) didn't report the key change itself") }
            let session = ClientSession(
                mac: MacHello(deviceId: macId, name: displayName(serverHello.name), platform: serverHello.platform,
                              identityKey: serverHello.identityKey, fingerprint: fingerprint, capabilities: serverHello.capabilities),
                // A key change either side saw is shown: a device with a paired Mac's id and its own key may not say so.
                status: status == .trusted ? .trusted : .pairingRequired(code: HandshakeCrypto.pairingCode(sasBits: keys.sasBits),
                                                                         keyChanged: keyChanged || status == .keyChanged),
                address: address, port: port, addresses: addresses, channel: secure, store: store
            )
            Log.handshake.info("Session with \(macId, privacy: .public) established, fingerprint \(fingerprint.fingerprintLogPrefix, privacy: .public)…, status \(status.rawValue, privacy: .public)")
            session.startReading()
            if status == .trusted { session.remember(presenceKey: presenceKey) }
            return session
        } catch {
            let failure = ClientError(error)
            Log.handshake.error("Handshake with \(socket.remoteAddress, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
            // Told before closing, like Android's HandshakeClient; never in answer to the Mac's own error.
            let fromMac = if case SessionError.peerError = error { true } else { false }
            if !fromMac, let code = failure.wireCode {
                let message = ErrorMessage(code: code, detail: String(describing: failure)).message
                if let channel {
                    try? await channel.send(message)
                } else {
                    _ = try? await frames.sendFrame(message.encoded())
                }
            }
            frames.cancel()
            throw failure
        }
    }

    /// Names come from the network: no control characters, at most 64 characters (as the Mac does).
    private static func displayName(_ raw: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Mac" : String(cleaned.prefix(64))
    }

    /// The one reader: until the connection ends, everything goes into the inbox.
    private func startReading() {
        Task.detached { [channel, inbox, mac] in
            while true {
                let message: Message
                do {
                    message = try await channel.receive(timeout: Self.readerTimeout, stage: "next message")
                } catch {
                    let reason = ClientError(error)
                    Log.connection.info("Session with \(mac.deviceId, privacy: .public) ended: \(String(describing: reason), privacy: .public)")
                    inbox.finish(reason)
                    return
                }
                await inbox.push(message)
            }
        }
    }

    /// The trusted session's facts. The Mac addresses pending deliveries with the presence key it
    /// last gave this iPhone: losing one would mean missing them, so every one is stored.
    private func remember(presenceKey: Data?) {
        do {
            try store.noteSession(id: mac.deviceId, name: mac.name, capabilities: mac.capabilities, presenceKey: presenceKey,
                                  addresses: addresses, port: port)
        } catch {
            Log.app.error("Could not remember the session with \(self.mac.deviceId, privacy: .public)")
        }
    }

    // MARK: - Pairing

    /// This iPhone's user confirmed that both screens show the same code. Sent at most once:
    /// the Mac answers a second `pairing_confirm{true}` with `bad_message`.
    @concurrent func confirmPairing() async {
        let send = state.withLock { state -> Bool in
            guard !state.trusted, !state.pairingConfirmed, !state.pairingDeclined, !state.closing else { return false }
            state.pairingConfirmed = true
            return true
        }
        guard send else { return }
        do {
            try await write(PairingMessages.confirm(accepted: true))
            Log.handshake.info("Sent pairing_confirm(accepted: true)")
        } catch {
            // `pairingResult()` sees the same failure on the inbox.
            Log.handshake.warning("Could not send pairing_confirm: \(String(describing: error), privacy: .public)")
        }
    }

    /// Declines, or withdraws an earlier confirm. The Mac answers `pairing_result{false}` and closes.
    @concurrent func declinePairing() async {
        let send = state.withLock { state -> Bool in
            guard !state.trusted, !state.pairingDeclined, !state.closing else { return false }
            state.pairingDeclined = true
            return true
        }
        guard send else { return }
        try? await write(PairingMessages.confirm(accepted: false))
        Log.handshake.info("Sent pairing_confirm(accepted: false)")
    }

    /// Waits for `pairing_result`: the Mac's user may answer before this iPhone's does. On success
    /// after a local confirm, the Mac is stored (Android `awaitPairingResult`) and the session is
    /// trusted and stays open. Any failure closes the session.
    @concurrent func pairingResult() async throws(ClientError) -> PairedMac {
        if state.withLock({ $0.trusted }), let paired = store.mac(mac.deviceId) { return paired }
        do {
            let message = try await inbox.next(timeout: Self.pairingTimeout, stage: "pairing confirmation")
            let (accepted, presenceKey) = try ClientError.decoding { try PairingMessages.parseResult(message) }
            let (confirmed, declined) = state.withLock { ($0.pairingConfirmed, $0.pairingDeclined) }
            guard accepted else { throw ClientError.pairingRejected(byPeer: !declined) }
            guard confirmed && !declined else { throw ClientError.protocolViolation("pairing_result(true) before local confirmation") }
            let now = Date()
            let paired = PairedMac(id: mac.deviceId, name: mac.name, publicKey: mac.identityKey, fingerprint: mac.fingerprint,
                                   presenceKey: presenceKey, capabilities: mac.capabilities, lastAddresses: addresses, lastPort: port,
                                   firstSeen: now, lastSeen: now, receiveAutomatically: false)
            try store.trust(paired)
            state.withLock { $0.trusted = true }
            remember(presenceKey: presenceKey)
            Log.handshake.info("Paired with \(self.mac.deviceId, privacy: .public)")
            return store.mac(mac.deviceId) ?? paired
        } catch {
            // Closed on this iPhone (Cancel on the pairing screen): not the Mac's doing.
            let failure = state.withLock({ $0.closing }) ? .cancelled : ClientError(error)
            Log.handshake.info("Pairing with \(self.mac.deviceId, privacy: .public) ended: \(String(describing: failure), privacy: .public)")
            await close()
            throw failure
        }
    }

    // MARK: - Ending

    /// Cancels what runs: `cancel{user_cancelled}` if a transfer was announced, `close`, then
    /// reads until the Mac closes, at most 2 s, before closing the socket.
    func cancel() {
        let transferId = state.withLock { state -> Data? in
            state.cancelled = true
            return state.transferId
        }
        Log.connection.info("Cancelling the session with \(self.mac.deviceId, privacy: .public)")
        Task.detached { [self] in
            await end(sending: (transferId.map { [TransferMessages.cancel($0, reason: "user_cancelled")] } ?? []) + [Message(type: MessageType.close)],
                      drain: Self.cancelDrain)
        }
    }

    /// Sends `close` and closes the socket; the Mac counts a session without `close` as failed.
    /// In the middle of an operation it cancels that. Idempotent.
    @concurrent func close() async {
        let (busy, transferId) = state.withLock { state -> (Bool, Data?) in
            if state.busy { state.cancelled = true }
            return (state.busy, state.transferId)
        }
        if busy, let transferId {
            await end(sending: [TransferMessages.cancel(transferId, reason: "user_cancelled"), Message(type: MessageType.close)], drain: Self.cancelDrain)
        } else {
            await end(sending: [Message(type: MessageType.close)], drain: Self.closeDrain)
        }
    }

    /// Closes the socket at once, without a word. The Mac sees the connection drop and keeps what
    /// it was delivering, or offering, as interrupted, to offer it again; after a cancel it would
    /// delete it. For when iOS takes the app's run time away, not for the user's Cancel. What
    /// runs ends with `.cancelled`.
    func interrupt() {
        state.withLock { state in
            state.cancelled = true
            state.closing = true
        }
        inbox.discard()
        channel.closeConnection()
    }

    /// Ends the session once. Sends `messages` (unless the Mac already closed), then reads and
    /// drops what still arrives until the Mac closes: closing with unread data is a reset, which
    /// can make the Mac lose what was just sent. Then the socket closes, `drain` after the start
    /// at the latest.
    func end(sending messages: [Message], drain: TimeInterval) async {
        guard state.withLock({ state in defer { state.closing = true }; return !state.closing }) else { return }
        inbox.discard()
        // In a task of its own: in a cancelled one, FrameConnection would close the socket before the frames go.
        await Task.detached { [channel, inbox] in
            if !inbox.isEnded && !messages.isEmpty {
                // The frames queue behind file data already handed to the socket, which a Mac that's gone never takes.
                let deadline = WaitDeadline(after: drain) { channel.closeConnection() }
                for message in messages { try? await channel.send(message) }
                _ = await inbox.wait(timeout: drain)
                deadline.cancel()
            }
            channel.closeConnection()
        }.value
    }

    // MARK: - For the operations

    /// Runs one operation: one at a time, on a trusted, open session. Errors the Mac carries on
    /// after (a rejected transfer, files refused for space, a file gone before the request) keep
    /// the session; any other ends it, telling the Mac when it can still be told. After `cancel()`
    /// or `interrupt()` every error is `.cancelled`.
    func run<T>(_ operation: () async throws(ClientError) -> T) async throws(ClientError) -> T {
        let refusal = state.withLock { state -> ClientError? in
            if state.closing { return .connectionLost }
            if !state.trusted { return .notPaired }
            if state.busy { return .protocolViolation("another operation is running") }
            state.busy = true
            return nil
        }
        if let refusal { throw refusal }
        if inbox.isEnded {
            state.withLock { $0.busy = false }
            throw .connectionLost
        }
        defer { state.withLock { $0.busy = false; $0.transferId = nil } }
        do {
            return try await operation()
        } catch {
            if state.withLock({ $0.cancelled }) { throw .cancelled }
            switch error {
            case .transferRejected, .storageFailed:
                break
            case .sourceUnavailable where state.withLock({ $0.transferId }) == nil:
                // Checked before the request: nothing went on the wire.
                break
            case .connectionLost, .decryptionFailed, .peerError:
                // Nothing more gets through, or the Mac ended it with its own error.
                await end(sending: [], drain: 0)
            case .protocolViolation(let detail):
                // "After error the sender closes the connection" (messages.md).
                await end(sending: [ErrorMessage(code: ErrorCode.badMessage, detail: detail).message], drain: Self.closeDrain)
            default:
                // The Mac counts a session that ends without `close` as failed.
                await end(sending: [Message(type: MessageType.close)], drain: Self.closeDrain)
            }
            throw error
        }
    }

    /// Sends one message; transport failures as `ClientError`.
    func write(_ message: Message, pipelined: Bool = false) async throws(ClientError) {
        do {
            if pipelined {
                try await channel.sendPipelined(message)
            } else {
                try await channel.send(message)
            }
        } catch {
            throw ClientError(error)
        }
    }
}
