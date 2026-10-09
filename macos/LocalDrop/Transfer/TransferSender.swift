import CryptoKit
import Foundation
import os

/// How a delivery to a phone ended.
nonisolated enum DeliveryOutcome: Sendable {
    case completed(files: Int, bytes: Int64)
    /// The phone's user (or its policy) declined, or it couldn't take the files.
    case rejected(reason: String)
    case cancelledByPeer
    case cancelled
    /// Connection or file trouble: the delivery waits for the phone again.
    case interrupted(String)
}

/// Sends one delivery to a phone that asked with `receive_ready` (protocol.md §2.8): the same
/// transfer messages as phone → Mac, with the roles swapped.
nonisolated final class TransferSender {
    static let acceptanceTimeout: TimeInterval = 180
    static let replyTimeout: TimeInterval = 60
    private static let progressInterval: Duration = .milliseconds(100)
    /// No data accepted by the network for this long: the phone is gone.
    private static let stallTimeout: Duration = .seconds(30)
    /// A cancel from this Mac waits this long for the sender to stop by itself before the
    /// connection is cut (a send blocked on a full buffer doesn't see the cancel).
    private static let cancelGrace: Duration = .seconds(2)

    private let deliveryId: UUID
    private let files: [URL]
    private let channel: SecureChannel
    private let coordinator: any SessionCoordinator
    private let token: TransferCancelToken

    /// Text goes straight to the phone's clipboard: `text`, answered by `text_result`.
    static func sendText(_ text: String, over channel: SecureChannel) async throws -> DeliveryOutcome {
        let transferId = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        try await channel.send(OutgoingMessages.text(transferId, text: text))
        let result = try await channel.receive(timeout: replyTimeout, stage: "text result")
        try result.expect(MessageType.textResult)
        let status = (try? result.text("status")) ?? "declined"
        Log.transfer.info("Text delivered: \(text.utf8.count) bytes, \(status, privacy: .public)")
        return status == "copied" ? .completed(files: 0, bytes: Int64(text.utf8.count)) : .rejected(reason: "declined")
    }

    init(deliveryId: UUID, files: [URL], channel: SecureChannel, coordinator: any SessionCoordinator, token: TransferCancelToken) {
        self.deliveryId = deliveryId
        self.files = files
        self.channel = channel
        self.coordinator = coordinator
        self.token = token
    }

    func run() async throws -> DeliveryOutcome {
        let infos: [TransferFileInfo]
        do {
            infos = try files.enumerated().map { try OutgoingFile.info($1, fileId: $0) }
        } catch {
            return .rejected(reason: String(describing: error))
        }
        let transferId = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        try await channel.send(OutgoingMessages.request(transferId, files: infos))
        Log.transfer.info("Delivery request sent: \(infos.count) file(s), \(infos.reduce(0) { $0 + $1.size }) bytes")

        let answer: Message
        do {
            answer = try await channel.receive(timeout: Self.acceptanceTimeout, stage: "acceptance")
        } catch SessionError.timeout {
            // Unanswered on the phone: not retried, or the phone would be asked again and again.
            try? await channel.send(TransferMessages.cancel(transferId, reason: "timeout"))
            return .rejected(reason: "timeout")
        }
        switch answer.type {
        case MessageType.transferAccept:
            break
        case MessageType.transferReject:
            return .rejected(reason: (try? answer.text("reason")) ?? "declined")
        case MessageType.cancel:
            return .cancelledByPeer
        default:
            throw SessionError.protocolViolation("unexpected \(answer.type) instead of transfer_accept")
        }
        let accepted = Int(clamping: (try? answer.uint("fileCount")) ?? UInt64(infos.count))
        let sending = Array(infos.prefix(max(0, min(accepted, infos.count))))
        await coordinator.deliveryStarted(deliveryId)
        Log.transfer.info("Delivery accepted: sending \(sending.count) file(s)")
        return try await stream(sending, transferId: transferId)
    }

    private func stream(_ infos: [TransferFileInfo], transferId: Data) async throws -> DeliveryOutcome {
        // The phone may cancel at any time: read its messages alongside sending. The reader stops
        // after the last reply this transfer expects, so the session's next message isn't consumed.
        let channel = channel
        let replies = Replies()
        let peerCancelled = OSAllocatedUnfairLock(initialState: false)
        let reader = Task {
            do {
                while true {
                    let message = try await channel.receive(timeout: 3600, stage: "receiver")
                    if message.type == MessageType.cancel {
                        peerCancelled.withLock { $0 = true }
                        // The phone stopped reading: a send may be stuck on a full buffer.
                        await channel.closeConnection()
                    }
                    await replies.push(.success(message))
                    if message.type == MessageType.cancel || message.type == MessageType.transferResult { break }
                }
            } catch {
                await replies.push(.failure(error))
            }
        }
        defer { reader.cancel() }
        // Unblocks a stuck send: a cancel on this Mac, or no progress at all for a while.
        let lastProgressAt = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let token = token
        let watchdog = Task {
            var cancelledAt: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let now = ContinuousClock.now
                if token.isCancelled { cancelledAt = cancelledAt ?? now }
                let stalled = now - lastProgressAt.withLock { $0 } > Self.stallTimeout
                if stalled || cancelledAt.map({ now - $0 > Self.cancelGrace }) == true {
                    if stalled {
                        Log.transfer.warning("Delivery stalled; closing the connection")
                    } else {
                        Log.transfer.warning("Cancel didn't stop the delivery; closing the connection")
                    }
                    await channel.closeConnection()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        func reply(_ expected: String) async throws -> Message {
            let message = try await replies.next()
            if message.type == MessageType.cancel { throw SessionError.transferCancelled(byPeer: true) }
            try message.expect(expected)
            return message
        }

        let started = ContinuousClock.now
        var lastProgress = started
        var sent: Int64 = 0
        // Where the time goes: reading and hashing the file, or waiting for the network to take data.
        var readTime = Duration.zero
        var sendTime = Duration.zero
        do {
            for info in infos {
                let url = files[info.fileId]
                try await channel.send(OutgoingMessages.fileBegin(transferId, fileId: info.fileId))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasher = SHA256()
                var offset: Int64 = 0
                while offset < info.size {
                    if token.isCancelled {
                        try? await channel.send(TransferMessages.cancel(transferId, reason: "user_cancelled"))
                        return .cancelled
                    }
                    if peerCancelled.withLock({ $0 }) { return .cancelledByPeer }
                    let count = Int(min(Int64(ProtocolConstants.chunkSize), info.size - offset))
                    let readStart = ContinuousClock.now
                    guard let data = try handle.read(upToCount: count), !data.isEmpty else {
                        throw SessionError.writeFailed("\(info.name) ended early")
                    }
                    hasher.update(data: data)
                    let sendStart = ContinuousClock.now
                    readTime += sendStart - readStart
                    try await channel.sendPipelined(OutgoingMessages.fileChunk(transferId, fileId: info.fileId, offset: offset, data: data))
                    sendTime += ContinuousClock.now - sendStart
                    offset += Int64(data.count)
                    sent += Int64(data.count)
                    lastProgressAt.withLock { $0 = ContinuousClock.now }
                    let now = ContinuousClock.now
                    if now - lastProgress >= Self.progressInterval {
                        lastProgress = now
                        await coordinator.deliveryProgress(deliveryId, bytesSent: sent)
                    }
                }
                try await channel.send(OutgoingMessages.fileEnd(transferId, fileId: info.fileId, sha256: Data(hasher.finalize())))
                let result = try await reply(MessageType.fileResult)
                guard (try? result.bool("ok")) == true else {
                    return .rejected(reason: (try? result.text("code")) ?? "failed")
                }
                await coordinator.deliveryProgress(deliveryId, bytesSent: sent)
            }
            try await channel.send(OutgoingMessages.transferComplete(transferId))
            let result = try await reply(MessageType.transferResult)
            guard (try? result.text("status")) == "completed" else {
                return .rejected(reason: (try? result.text("code")) ?? "failed")
            }
        } catch SessionError.transferCancelled(byPeer: true) {
            return .cancelledByPeer
        } catch {
            // A connection cut because of a cancel is that cancel, not a network failure.
            if peerCancelled.withLock({ $0 }) { return .cancelledByPeer }
            if token.isCancelled { return .cancelled }
            throw error
        }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let rate = seconds > 0 ? Double(sent) / 1_000_000 / seconds : 0
        Log.transfer.info("Delivery complete: \(sent) bytes in \(String(format: "%.2f", seconds), privacy: .public) s (\(String(format: "%.1f", rate), privacy: .public) MB/s): reading \(readTime.formatted(.units(allowed: [.milliseconds])), privacy: .public), sending \(sendTime.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        return .completed(files: infos.count, bytes: sent)
    }
}

/// Messages from the phone, read by one task and awaited by the sender.
private actor Replies {
    private var buffered: [Result<Message, any Error>] = []
    private var waiter: CheckedContinuation<Message, any Error>?

    func push(_ result: Result<Message, any Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        } else {
            buffered.append(result)
        }
    }

    func next() async throws -> Message {
        if !buffered.isEmpty { return try buffered.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}
