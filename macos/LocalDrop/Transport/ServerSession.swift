import CryptoKit
import Foundation

/// A remote device that completed the handshake and proved possession of its identity key.
nonisolated struct PeerInfo: Equatable, Sendable {
    let deviceId: String
    let name: String
    let platform: String
    let identityKey: Data
    let protocolVersion: UInt64
    let capabilities: [String]

    var fingerprint: Data { Data(SHA256.hash(data: identityKey)) }
}

/// App-side decisions and state a session needs. Implemented by AppModel on the main actor.
@MainActor
protocol SessionCoordinator: AnyObject, Sendable {
    func trustState(deviceId: String, identityKey: Data) -> TrustState
    func sessionAuthenticated(_ entryId: UUID, peer: PeerInfo, status: SessionStatus)
    /// Shows the pairing prompt. Throws `SessionError.busy` if another pairing is in progress
    /// or too many attempts were made recently.
    func beginPairing(_ entryId: UUID, peer: PeerInfo, code: String, keyChanged: Bool) throws
    /// Suspends until this Mac's user decides. Cancelling the calling task dismisses the prompt.
    func awaitPairingDecision(_ entryId: UUID) async -> Bool
    /// Persists the peer as trusted. Called before the peer is told pairing succeeded.
    func pairingSucceeded(_ entryId: UUID, peer: PeerInfo) throws
    func sessionEnded(_ entryId: UUID, peer: PeerInfo?, error: SessionError?)

    /// Pairing is accepted only in pairing mode (protocol.md §2.2).
    func isPairingAllowed() -> Bool
    /// Given to trusted devices so they recognize this Mac over BLE (security.md §6a).
    func currentPresenceKey() -> Data?

    /// The user's choice for this trusted device (ask when unknown).
    func acceptPolicy(for peer: PeerInfo) -> AcceptPolicy
    /// Registers the incoming transfer and, unless [autoAccepted], shows the prompt. Throws
    /// `SessionError.busy` if another transfer is active.
    func beginIncomingTransfer(_ entryId: UUID, peer: PeerInfo, request: TransferRequest, autoAccepted: Bool, cancel: @escaping @Sendable () -> Void) async throws
    /// Suspends until the user accepts or declines. Cancelling the caller abandons the wait only.
    func awaitTransferDecision(_ entryId: UUID) async -> TransferDecision
    /// Files were added to the request on screen.
    func transferRequestGrew(_ entryId: UUID, request: TransferRequest)
    func transferStarted(_ entryId: UUID)
    func transferProgress(_ entryId: UUID, bytesReceived: Int64, currentFile: String)
    /// Idempotent: only the first outcome for a transfer is shown.
    func transferFinished(_ entryId: UUID, outcome: TransferOutcome)
    func transferRejectedForStorage(peer: PeerInfo, request: TransferRequest)
    /// Puts text from a trusted device on the clipboard. Returns false if its policy declines everything.
    func textReceived(_ text: String, peer: PeerInfo) -> Bool

    /// The next delivery waiting for this phone, now being offered to it; nil when none.
    func takeDelivery(for peer: PeerInfo) -> (id: UUID, files: [URL], token: TransferCancelToken)?
    func deliveryStarted(_ id: UUID)
    func deliveryProgress(_ id: UUID, bytesSent: Int64)
    func deliveryFinished(_ id: UUID, outcome: DeliveryOutcome)
}

/// Responder side of one TCP session (protocol/protocol.md §5, protocol/security.md §3, §5).
nonisolated final class ServerSession {
    static let handshakeTimeout: TimeInterval = 15
    static let userDecisionTimeout: TimeInterval = 120
    static let idleTimeout: TimeInterval = 120

    private let entryId: UUID
    private let frames: FrameConnection
    private let identity: Identity
    private let localDevice: LocalDevice
    private let coordinator: any SessionCoordinator
    /// Set once an error or result has been sent, so the failure path doesn't send another.
    private var peerNotified = false

    private struct Handshake {
        let peer: PeerInfo
        let channel: SecureChannel
        let clientTrustsUs: Bool
        let clientSeesKeyChange: Bool
        let pairingCode: String
    }

    private enum PairingEvent: Sendable {
        case peer(Result<Message, any Error>)
        case local(accepted: Bool)
        case timeout
    }

    let handle: SessionHandle

    init(
        entryId: UUID,
        socket: TCPSocket,
        identity: Identity,
        localDevice: LocalDevice,
        coordinator: any SessionCoordinator
    ) {
        self.entryId = entryId
        let frames = FrameConnection(socket: socket)
        self.frames = frames
        self.handle = SessionHandle(frames: frames)
        self.identity = identity
        self.localDevice = localDevice
        self.coordinator = coordinator
    }

    /// Runs the session to completion. Never throws: the outcome is reported to the coordinator.
    func run() async {
        var peer: PeerInfo?
        var channel: SecureChannel?
        do {
            let handshake = try await handshake { established in
                channel = established
                handle.attach(established)
            }
            peer = handshake.peer

            let localTrust = await coordinator.trustState(deviceId: handshake.peer.deviceId, identityKey: handshake.peer.identityKey)
            let status: SessionStatus = if localTrust == .keyChanged || handshake.clientSeesKeyChange {
                .keyChanged
            } else if localTrust == .trusted && handshake.clientTrustsUs {
                .trusted
            } else {
                .pairingRequired
            }
            Log.handshake.info("Session with \(handshake.peer.deviceId, privacy: .public): local trust \(String(describing: localTrust), privacy: .public), client trusts us \(handshake.clientTrustsUs, privacy: .public) → \(status.rawValue, privacy: .public)")
            if status != .trusted, await !coordinator.isPairingAllowed() {
                Log.handshake.info("Refusing pairing with \(handshake.peer.deviceId, privacy: .public): not in pairing mode")
                throw SessionError.pairingUnavailable
            }
            await coordinator.sessionAuthenticated(entryId, peer: handshake.peer, status: status)
            try await handshake.channel.send(status.message(presenceKey: await coordinator.currentPresenceKey()))

            var pending: Task<Message, any Error>?
            if status != .trusted {
                pending = try await pair(handshake, keyChanged: status == .keyChanged)
            }

            try await serveTrustedSession(handshake, pending: pending)
            Log.connection.info("Session with \(handshake.peer.deviceId, privacy: .public) closed by peer")
            frames.cancel()
            await coordinator.sessionEnded(entryId, peer: peer, error: nil)
        } catch {
            // A termination from the app (trust revoked, superseded) explains the I/O error it caused.
            let terminated = handle.terminationReason
            let sessionError = terminated ?? error as? SessionError ?? .transport(String(describing: error))
            if case .timeout(let stage) = sessionError, stage == "idle" {
                Log.connection.info("Closing idle session with \(peer?.deviceId ?? "?", privacy: .public)")
                frames.cancel()
                await coordinator.sessionEnded(entryId, peer: peer, error: nil)
                return
            }
            Log.connection.error("Session with \(self.frames.remoteDescription, privacy: .public) failed: \(sessionError.description, privacy: .public)")
            if !peerNotified && terminated == nil {
                await notifyPeer(of: sessionError, channel: channel)
            }
            frames.cancel()
            await coordinator.sessionEnded(entryId, peer: peer, error: sessionError)
        }
    }

    /// Serves transfers until the peer sends `close` (or stays idle past `idleTimeout`).
    /// - Parameter pending: a receive already in flight (started during pairing); its message comes first.
    private func serveTrustedSession(_ handshake: Handshake, pending initial: Task<Message, any Error>?) async throws {
        let receiver = TransferReceiver(entryId: entryId, peer: handshake.peer, channel: handshake.channel, coordinator: coordinator)
        var pending = initial
        while true {
            let next: Message
            if let inFlight = pending {
                pending = nil
                next = try await inFlight.value
            } else {
                next = try await handshake.channel.receive(timeout: Self.idleTimeout, stage: "idle")
            }
            switch next.type {
            case MessageType.close:
                return
            case MessageType.transferRequest:
                pending = try await receiver.handle(next)
            case MessageType.text:
                try await receiver.handleText(next)
            case MessageType.receiveReady:
                try await serveDeliveries(handshake)
            case MessageType.transferAdd:
                // Sent before the sender read our answer to its request; that answer stands.
                Log.transfer.info("Ignoring transfer_add after the request was answered")
            default:
                throw SessionError.protocolViolation("unexpected \(next.type)")
            }
        }
    }

    /// The phone asked for what this Mac has for it (protocol.md §2.8): every waiting delivery
    /// in turn, then `nothing_pending`.
    private func serveDeliveries(_ handshake: Handshake) async throws {
        while let delivery = await coordinator.takeDelivery(for: handshake.peer) {
            let sender = TransferSender(deliveryId: delivery.id, files: delivery.files, channel: handshake.channel,
                                        coordinator: coordinator, token: delivery.token)
            do {
                let outcome = try await sender.run()
                await coordinator.deliveryFinished(delivery.id, outcome: outcome)
            } catch {
                let reason = (error as? SessionError)?.description ?? String(describing: error)
                await coordinator.deliveryFinished(delivery.id, outcome: .interrupted(reason))
                throw error
            }
        }
        try await handshake.channel.send(OutgoingMessages.nothingPending)
    }

    // MARK: - Pairing

    /// Numeric comparison (protocol/security.md §5). Both users decide independently; the first
    /// "no" ends pairing at once, and success requires both "yes" answers. The connection is read
    /// the whole time, so the phone withdrawing (or disconnecting) ends pairing immediately.
    ///
    /// - Returns: a receive still in flight after success, whose message is the session's next one.
    private func pair(_ handshake: Handshake, keyChanged: Bool) async throws -> Task<Message, any Error>? {
        let entryId = entryId
        let coordinator = coordinator
        let channel = handshake.channel
        let peer = handshake.peer

        try await coordinator.beginPairing(entryId, peer: peer, code: handshake.pairingCode, keyChanged: keyChanged)
        Log.handshake.info("Pairing with \(peer.deviceId, privacy: .public) started (keyChanged: \(keyChanged, privacy: .public))")

        let (events, sink) = AsyncStream<PairingEvent>.makeStream()
        func readPeer() -> Task<Message, any Error> {
            Task {
                let result: Result<Message, any Error>
                do {
                    result = .success(try await channel.receive(timeout: Self.userDecisionTimeout + 10, stage: "pairing"))
                } catch {
                    result = .failure(error)
                }
                sink.yield(.peer(result))
                return try result.get()
            }
        }
        var peerRead: Task<Message, any Error>? = readPeer()
        let local = Task { sink.yield(.local(accepted: await coordinator.awaitPairingDecision(entryId))) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(Self.userDecisionTimeout))
            if !Task.isCancelled { sink.yield(.timeout) }
        }
        defer {
            timer.cancel()
            // Dismisses the prompt if this Mac's user hasn't decided.
            local.cancel()
            sink.finish()
        }

        var peerAccepted = false
        var localAccepted = false
        for await event in events {
            switch event {
            case .peer(let result):
                peerRead = nil
                let message = try result.get()
                guard message.type == MessageType.pairingConfirm else {
                    if message.type == MessageType.close {
                        Log.handshake.info("Peer closed the session during pairing")
                        throw SessionError.pairingRejected(byPeer: true)
                    }
                    throw SessionError.protocolViolation("unexpected \(message.type) during pairing")
                }
                guard try PairingMessages.confirmAccepted(message) else {
                    Log.handshake.info("Peer declined pairing")
                    try? await channel.send(PairingMessages.result(accepted: false))
                    peerNotified = true
                    throw SessionError.pairingRejected(byPeer: true)
                }
                guard !peerAccepted else { throw SessionError.protocolViolation("duplicate pairing_confirm") }
                peerAccepted = true
                Log.handshake.info("Peer confirmed pairing")
                if !localAccepted {
                    // Keep watching: the phone may still withdraw while this Mac's user decides.
                    peerRead = readPeer()
                }
            case .local(let accepted):
                guard accepted else {
                    Log.handshake.info("User declined pairing")
                    try await channel.send(PairingMessages.result(accepted: false))
                    peerNotified = true
                    throw SessionError.pairingRejected(byPeer: false)
                }
                localAccepted = true
                Log.handshake.info("User confirmed pairing")
            case .timeout:
                try? await channel.send(ErrorMessage(code: ErrorCode.pairingTimeout).message)
                peerNotified = true
                throw SessionError.userDecisionTimeout
            }
            if peerAccepted && localAccepted { break }
        }
        guard peerAccepted && localAccepted else { throw SessionError.cancelled }

        do {
            try await coordinator.pairingSucceeded(entryId, peer: peer)
        } catch {
            throw SessionError.storage(String(describing: error))
        }
        try await channel.send(PairingMessages.result(accepted: true, presenceKey: await coordinator.currentPresenceKey()))
        Log.handshake.info("Paired with \(peer.deviceId, privacy: .public)")
        return peerRead
    }

    // MARK: - Handshake

    private func handshake(channelEstablished: (SecureChannel) -> Void) async throws -> Handshake {
        let (helloPayload, helloFrame) = try await frames.receiveFrameWithWire(timeout: Self.handshakeTimeout, stage: "client_hello")
        let hello = try ClientHello(Message.decodeHandshake(helloPayload))
        Log.handshake.info("client_hello from \(hello.deviceId, privacy: .public) (\(hello.platform, privacy: .public), v\(hello.minVersion)–v\(hello.version))")

        let version = min(hello.version, ProtocolConstants.version)
        guard version >= max(hello.minVersion, ProtocolConstants.minSupportedVersion) else {
            throw SessionError.versionUnsupported(peerMin: hello.minVersion, peerMax: hello.version)
        }
        guard hello.deviceId.lowercased() != localDevice.deviceId.lowercased() else {
            throw SessionError.protocolViolation("connection from own deviceId")
        }

        let peerIdentityKey: P256.Signing.PublicKey
        let peerEphemeralKey: P256.KeyAgreement.PublicKey
        do {
            peerIdentityKey = try P256.Signing.PublicKey(x963Representation: hello.identityKey)
            peerEphemeralKey = try P256.KeyAgreement.PublicKey(x963Representation: hello.ephemeralKey)
        } catch {
            throw SessionError.protocolViolation("invalid public key")
        }

        let ephemeral = P256.KeyAgreement.PrivateKey()
        let serverNonce = Self.randomBytes(32)
        let serverHello = ServerHello(
            version: version,
            deviceId: localDevice.deviceId,
            name: localDevice.name,
            platform: ProtocolConstants.platform,
            identityKey: identity.publicKeyX963,
            ephemeralKey: ephemeral.publicKey.x963Representation,
            nonce: serverNonce,
            capabilities: ProtocolConstants.capabilities
        )
        let serverHelloFrame = try await frames.sendFrame(serverHello.message.encoded())

        let (noncePayload, nonceFrame) = try await frames.receiveFrameWithWire(timeout: Self.handshakeTimeout, stage: "client_nonce")
        let clientNonce = try ClientNonce(Message.decodeHandshake(noncePayload))
        guard Data(SHA256.hash(data: clientNonce.nonce)) == hello.nonceCommit else {
            throw SessionError.authFailed("nonce does not match commitment")
        }

        let transcript = HandshakeCrypto.transcriptHash([helloFrame, serverHelloFrame, nonceFrame])
        let keys: HandshakeCrypto.SessionKeys
        do {
            keys = try HandshakeCrypto.deriveKeys(ephemeral: ephemeral, peerEphemeral: peerEphemeralKey, transcriptHash: transcript)
        } catch {
            throw SessionError.authFailed("key agreement failed")
        }
        let channel = SecureChannel(frames: frames, sendKey: keys.serverToClient, receiveKey: keys.clientToServer)
        channelEstablished(channel)

        let serverSignature = try identity.privateKey.signature(
            for: HandshakeCrypto.authPayload(label: HandshakeCrypto.serverAuthLabel, transcriptHash: transcript)
        )
        try await channel.send(Message(type: MessageType.serverAuth, body: ["sig": .bytes(serverSignature.derRepresentation)]))

        let clientAuth = try ClientAuth(await channel.receive(timeout: Self.handshakeTimeout, stage: "client_auth"))
        let clientSignature: P256.Signing.ECDSASignature
        do {
            clientSignature = try P256.Signing.ECDSASignature(derRepresentation: clientAuth.signature)
        } catch {
            throw SessionError.authFailed("malformed client signature")
        }
        guard peerIdentityKey.isValidSignature(
            clientSignature,
            for: HandshakeCrypto.authPayload(label: HandshakeCrypto.clientAuthLabel, transcriptHash: transcript)
        ) else {
            throw SessionError.authFailed("client signature is invalid")
        }

        let peer = PeerInfo(
            deviceId: hello.deviceId.lowercased(),
            name: Self.displayName(hello.name),
            platform: hello.platform,
            identityKey: hello.identityKey,
            protocolVersion: version,
            capabilities: hello.capabilities
        )
        Log.handshake.info("Peer \(peer.deviceId, privacy: .public) verified, fingerprint \(peer.fingerprint.fingerprintLogPrefix, privacy: .public)…")
        return Handshake(
            peer: peer,
            channel: channel,
            clientTrustsUs: clientAuth.trusted,
            clientSeesKeyChange: clientAuth.keyChanged,
            pairingCode: HandshakeCrypto.pairingCode(sasBits: keys.sasBits)
        )
    }

    /// Best-effort error notification before closing; encrypted once keys exist.
    private func notifyPeer(of error: SessionError, channel: SecureChannel?) async {
        guard let code = error.wireCode else { return }
        let supported: [UInt64]? = if case .versionUnsupported = error {
            Array(ProtocolConstants.minSupportedVersion...ProtocolConstants.version)
        } else {
            nil
        }
        let message = ErrorMessage(code: code, detail: error.description, supported: supported).message
        do {
            if let channel {
                try await channel.send(message)
            } else {
                try await frames.sendFrame(message.encoded())
            }
        } catch {
            Log.connection.info("Could not deliver error \(code, privacy: .public) to peer: \(String(describing: error), privacy: .public)")
        }
    }

    /// Rejects a connection before any handshake, e.g. when too many sessions are active.
    static func reject(_ socket: TCPSocket, code: String) async {
        let frames = FrameConnection(socket: socket)
        do {
            try await frames.sendFrame(ErrorMessage(code: code).message.encoded())
        } catch {
            Log.connection.info("Could not deliver rejection: \(String(describing: error), privacy: .public)")
        }
        frames.cancel()
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Strips control characters and limits length; names come from untrusted peers.
    private static func displayName(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(64))
        return limited.isEmpty ? "Unknown device" : limited
    }
}
