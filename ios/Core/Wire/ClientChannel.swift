import CryptoKit
import Foundation

/// The encrypted channel from the Initiator's side: the Mac's `SecureChannel` with the keys the
/// other way round (seal with client→server, open with server→client), plus the one frame the
/// client must read differently. An actor so one task waits in `receive` while others send; a
/// seal and its write happen in one step, so frames go out in counter order.
actor ClientChannel {
    private let frames: FrameConnection
    private var sendCipher: FrameCipher
    private var receiveCipher: FrameCipher

    init(frames: FrameConnection, keys: HandshakeCrypto.SessionKeys) {
        self.frames = frames
        sendCipher = FrameCipher(key: keys.clientToServer)
        receiveCipher = FrameCipher(key: keys.serverToClient)
    }

    func send(_ message: Message) async throws {
        try await frames.sendFrame(try sendCipher.seal(message.encoded()))
    }

    /// For file data: queued without waiting for the network (see `FrameConnection.sendFramePipelined`).
    func sendPipelined(_ message: Message) async throws {
        try await frames.sendFramePipelined(try sendCipher.seal(message.encoded()))
    }

    /// Closes the socket at once: pending sends and receives fail. Not isolated, so a deadline
    /// can close it while a send waits inside the actor.
    nonisolated func closeConnection() {
        frames.cancel()
    }

    /// The next message; a Mac `error` is thrown as `SessionError.peerError`.
    /// - Parameter plaintextError: the frame may also be a plaintext `error`: where `server_auth`
    ///   is expected, a Mac that failed the nonce commitment answers before it has keys.
    func receive(timeout: TimeInterval, stage: String, plaintextError: Bool = false) async throws -> Message {
        let payload = try await frames.receiveFrame(timeout: timeout, stage: stage)
        let plaintext: Data
        do {
            plaintext = try receiveCipher.open(payload)
        } catch SessionError.decryptFailed where plaintextError {
            guard let message = try? Message.decode(payload), message.type == MessageType.error,
                  let error = try? ErrorMessage(message) else { throw SessionError.decryptFailed }
            throw SessionError.peerError(code: error.code, detail: error.detail)
        }
        let message = try Message.decode(plaintext)
        if message.type == MessageType.error {
            let error = try ErrorMessage(message)
            throw SessionError.peerError(code: error.code, detail: error.detail)
        }
        return message
    }
}
