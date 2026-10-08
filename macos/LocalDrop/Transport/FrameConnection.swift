import CryptoKit
import Foundation
import Network

/// Length-prefixed frames (`u32 BE length ‖ payload`, protocol/protocol.md §3.1) over one NWConnection.
///
/// All mutable state is confined to `queue`, the queue the connection delivers callbacks on.
/// Any timeout or task cancellation cancels the whole connection: in this protocol every
/// timeout is fatal to the session.
nonisolated final class FrameConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var timedOutStage: String?
    // Pipelined sends (file data): confined to `queue`.
    private var bytesInFlight = 0
    private var sendWaiters: [CheckedContinuation<Void, Error>] = []
    private var pipelineError: Error?
    private static let pipelineWindow = 4 * 1024 * 1024

    var remoteDescription: String { String(describing: connection.endpoint) }

    init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "dev.localdrop.connection")
    }

    func start(timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Callbacks below all run on `queue`, so this one-shot guard needs no lock.
                let once = ResumeOnce(continuation)
                let finish = once.resume
                let timer = Deadline(queue: queue, after: timeout) { [connection] in
                    finish(.failure(SessionError.timeout(stage: "connection setup")))
                    connection.cancel()
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        timer.cancel()
                        finish(.success(()))
                    case .failed(let error):
                        timer.cancel()
                        finish(.failure(SessionError.transport(error.localizedDescription)))
                    case .cancelled:
                        timer.cancel()
                        finish(.failure(SessionError.cancelled))
                    case .waiting(let error):
                        Log.connection.warning("Connection waiting: \(error.localizedDescription, privacy: .public)")
                    case .setup, .preparing:
                        break
                    @unknown default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    /// Returns the payload and the complete frame as received (needed for the transcript hash).
    func receiveFrameWithWire(timeout: TimeInterval, stage: String) async throws -> (payload: Data, frame: Data) {
        let (header, payload) = try await receiveHeaderAndPayload(timeout: timeout, stage: stage)
        return (payload, header + payload)
    }

    func receiveFrame(timeout: TimeInterval, stage: String) async throws -> Data {
        try await receiveHeaderAndPayload(timeout: timeout, stage: stage).payload
    }

    private func receiveHeaderAndPayload(timeout: TimeInterval, stage: String) async throws -> (header: Data, payload: Data) {
        let header = try await receiveExactly(4, timeout: timeout, stage: stage)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length <= ProtocolConstants.maxFrameSize else {
            throw SessionError.protocolViolation("frame length \(length) out of range")
        }
        return (header, try await receiveExactly(Int(length), timeout: timeout, stage: stage))
    }

    /// Sends one frame and returns it exactly as written (needed for the transcript hash).
    @discardableResult
    func sendFrame(_ payload: Data) async throws -> Data {
        guard payload.count <= ProtocolConstants.maxFrameSize else {
            throw SessionError.protocolViolation("outgoing frame too large")
        }
        var built = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { built.append(contentsOf: $0) }
        built.append(payload)
        let frame = built

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // On `queue`, like pipelined sends, so frames go out in the order they were sent.
                queue.async { [connection] in
                    connection.send(content: frame, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: SessionError.transport(error.localizedDescription))
                        } else {
                            continuation.resume()
                        }
                    })
                }
            }
        } onCancel: { [connection] in
            connection.cancel()
        }
        return frame
    }

    /// Queues a frame without waiting for the network to take it, as long as less than
    /// `pipelineWindow` bytes are still on their way. Waiting for each frame instead allows one
    /// chunk per Wi-Fi round trip: about 10 MB/s. Order is kept: NWConnection sends in call order.
    func sendFramePipelined(_ payload: Data) async throws {
        guard payload.count <= ProtocolConstants.maxFrameSize else {
            throw SessionError.protocolViolation("outgoing frame too large")
        }
        var built = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { built.append(contentsOf: $0) }
        built.append(payload)
        let frame = built
        let size = frame.count
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    if let pipelineError {
                        continuation.resume(throwing: pipelineError)
                        return
                    }
                    bytesInFlight += size
                    connection.send(content: frame, completion: .contentProcessed { [self] error in
                        bytesInFlight -= size
                        if let error, pipelineError == nil {
                            pipelineError = SessionError.transport(error.localizedDescription)
                        }
                        releaseSendWaiters()
                    })
                    if bytesInFlight <= Self.pipelineWindow {
                        continuation.resume()
                    } else {
                        sendWaiters.append(continuation)
                    }
                }
            }
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    /// On `queue`: lets queued senders continue as the window frees up, or fails them all.
    private func releaseSendWaiters() {
        if let pipelineError {
            let waiters = sendWaiters
            sendWaiters = []
            waiters.forEach { $0.resume(throwing: pipelineError) }
            return
        }
        while bytesInFlight <= Self.pipelineWindow, !sendWaiters.isEmpty {
            sendWaiters.removeFirst().resume()
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveExactly(_ count: Int, timeout: TimeInterval, stage: String) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async { [self] in
                    let timer = Deadline(queue: queue, after: timeout) { [self] in
                        timedOutStage = stage
                        connection.cancel()
                    }
                    connection.receive(minimumIncompleteLength: count, maximumLength: count) { [self] data, _, isComplete, error in
                        timer.cancel()
                        if let stage = timedOutStage {
                            continuation.resume(throwing: SessionError.timeout(stage: stage))
                        } else if let data, data.count == count {
                            continuation.resume(returning: data)
                        } else if let error {
                            if case .posix(let code) = error, code == .ECANCELED {
                                continuation.resume(throwing: SessionError.cancelled)
                            } else {
                                continuation.resume(throwing: SessionError.transport(error.localizedDescription))
                            }
                        } else if isComplete {
                            continuation.resume(throwing: SessionError.connectionClosed)
                        } else {
                            continuation.resume(throwing: SessionError.transport("short read"))
                        }
                    }
                }
            }
        } onCancel: { [connection] in
            connection.cancel()
        }
    }
}

/// A cancellable one-shot timer on a dispatch queue.
private nonisolated final class Deadline: @unchecked Sendable {
    // DispatchWorkItem.cancel() is thread-safe; the item is never mutated after init.
    private let item: DispatchWorkItem

    init(queue: DispatchQueue, after interval: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        item = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    func cancel() {
        item.cancel()
    }
}

/// Resumes a continuation at most once. Used only from the connection's serial queue.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Encrypted message channel established by the handshake.
/// An actor so one task can wait in `receive` while another sends (e.g. a pairing decision
/// made on this Mac while the peer's decision is still pending). Each direction has its own
/// cipher; concurrent `receive` calls are not supported.
actor SecureChannel {
    private let frames: FrameConnection
    private var sendCipher: FrameCipher
    private var receiveCipher: FrameCipher

    init(frames: FrameConnection, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.frames = frames
        self.sendCipher = FrameCipher(key: sendKey)
        self.receiveCipher = FrameCipher(key: receiveKey)
    }

    func send(_ message: Message) async throws {
        try await frames.sendFrame(try sendCipher.seal(message.encoded()))
    }

    /// For file data: queued without waiting for the network (see `FrameConnection.sendFramePipelined`).
    func sendPipelined(_ message: Message) async throws {
        try await frames.sendFramePipelined(try sendCipher.seal(message.encoded()))
    }

    /// Ends the connection at once: pending sends and receives fail. For a peer that cancelled
    /// while this side is blocked sending into a full buffer.
    func closeConnection() {
        frames.cancel()
    }

    /// Receives the next message. A peer `error` message is surfaced as `SessionError.peerError`.
    func receive(timeout: TimeInterval, stage: String) async throws -> Message {
        let payload = try await frames.receiveFrame(timeout: timeout, stage: stage)
        let message = try Message.decode(try receiveCipher.open(payload))
        if message.type == MessageType.error {
            let error = try ErrorMessage(message)
            throw SessionError.peerError(code: error.code, detail: error.detail)
        }
        return message
    }
}
