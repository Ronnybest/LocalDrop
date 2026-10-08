import CryptoKit
import Darwin
import Foundation

/// Length-prefixed frames (`u32 BE length ‖ payload`, protocol/protocol.md §3.1) over one
/// accepted TCP socket.
///
/// Uses the kernel TCP stack through DispatchIO rather than NWConnection: on the same Wi-Fi,
/// NWConnection's stack sent to a phone at 10–19 MB/s where a plain socket reached 22–35.
///
/// All mutable state is confined to `queue`. Any timeout or task cancellation closes the whole
/// connection: in this protocol every timeout is fatal to the session.
nonisolated final class FrameConnection: @unchecked Sendable {
    private let channel: DispatchIO
    private let queue: DispatchQueue
    private var timedOutStage: String?
    // Pipelined sends (file data): confined to `queue`.
    private var bytesInFlight = 0
    private var sendWaiters: [CheckedContinuation<Void, Error>] = []
    private var pipelineError: Error?
    private static let pipelineWindow = 4 * 1024 * 1024

    let remoteDescription: String

    /// Takes ownership of the socket: it is closed when the connection is cancelled.
    init(socket: TCPSocket) {
        let queue = DispatchQueue(label: "dev.localdrop.connection")
        let fd = socket.fd
        self.queue = queue
        self.remoteDescription = socket.remoteAddress
        channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in
            Darwin.close(fd)
        }
        // Handlers run once per operation, when it is complete or has failed.
        channel.setLimit(lowWater: Int.max)
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
        let frame = try Self.frame(payload)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // On `queue`, like pipelined sends, so frames go out in the order they were sent.
                queue.async { [self] in
                    write(frame) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        } onCancel: { [self] in
            cancel()
        }
        return frame
    }

    /// Queues a frame without waiting for the network to take it, as long as less than
    /// `pipelineWindow` bytes are still on their way. Waiting for each frame instead allows one
    /// chunk per Wi-Fi round trip: about 10 MB/s. Order is kept: a stream channel writes in call order.
    func sendFramePipelined(_ payload: Data) async throws {
        let frame = try Self.frame(payload)
        let size = frame.count
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    if let pipelineError {
                        continuation.resume(throwing: pipelineError)
                        return
                    }
                    bytesInFlight += size
                    write(frame) { [self] error in
                        bytesInFlight -= size
                        if let error, pipelineError == nil {
                            pipelineError = error
                        }
                        releaseSendWaiters()
                    }
                    if bytesInFlight <= Self.pipelineWindow {
                        continuation.resume()
                    } else {
                        sendWaiters.append(continuation)
                    }
                }
            }
        } onCancel: { [self] in
            cancel()
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

    /// Closes the socket at once; pending sends and receives fail.
    func cancel() {
        channel.close(flags: .stop)
    }

    private static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= ProtocolConstants.maxFrameSize else {
            throw SessionError.protocolViolation("outgoing frame too large")
        }
        var built = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { built.append(contentsOf: $0) }
        built.append(payload)
        return built
    }

    /// On `queue`: writes the whole frame; `completion` runs on `queue` once the kernel has it.
    private func write(_ frame: Data, completion: @escaping (SessionError?) -> Void) {
        let data = frame.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: data, queue: queue) { [self] done, _, error in
            guard done else { return }
            completion(error == 0 ? nil : failure(error))
        }
    }

    private func receiveExactly(_ count: Int, timeout: TimeInterval, stage: String) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async { [self] in
                    let timer = Deadline(queue: queue, after: timeout) { [self] in
                        timedOutStage = stage
                        cancel()
                    }
                    channel.read(offset: 0, length: count, queue: queue) { [self] done, data, error in
                        guard done else { return }
                        timer.cancel()
                        if error != 0 {
                            continuation.resume(throwing: failure(error))
                        } else if let data, data.count == count {
                            var bytes = Data(count: count)
                            bytes.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
                            continuation.resume(returning: bytes)
                        } else {
                            continuation.resume(throwing: SessionError.connectionClosed)
                        }
                    }
                }
            }
        } onCancel: { [self] in
            cancel()
        }
    }

    /// On `queue`: maps an errno from the channel to the session error it stands for.
    private func failure(_ error: Int32) -> SessionError {
        if let timedOutStage { return .timeout(stage: timedOutStage) }
        if error == ECANCELED { return .cancelled }
        return .transport(String(cString: strerror(error)))
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
