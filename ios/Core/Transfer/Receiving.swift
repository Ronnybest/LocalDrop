import Foundation
import os
import UniformTypeIdentifiers

/// Mac → iPhone (transfer.md §2; Android `runReceive`, `receiveTransfer`; the Mac's `TransferSender`).
nonisolated extension ClientSession {
    /// The Mac answers `receive_ready` at once; after a delivery it sends the next one or `nothing_pending`.
    private static let deliveryWait: TimeInterval = 30
    /// Shorter than the Mac's 180 s acceptance wait, so this iPhone's `timeout` answer arrives first.
    static let decisionTimeout: TimeInterval = 170
    private static let frameTimeout: TimeInterval = 60
    /// Kept free beyond what the Mac sends (Android `RECEIVE_SPACE_MARGIN`).
    private static let freeSpaceMargin: Int64 = 200 * 1024 * 1024

    private enum Decision: Sendable {
        case accepted, declined, timedOut
        /// The Mac sent something first (a cancel); it is still in the inbox.
        case macSpoke
    }

    /// One round: `receive_ready`, then every delivery the Mac has until `nothing_pending`.
    /// Files go into `directory` through the shared `IncomingFileWriter` (hidden temporary file,
    /// SHA-256 checked, unique name); texts are answered `copied` and returned for the pasteboard.
    /// `decide` is asked per file delivery unless `automatically`; no answer in 170 s is a
    /// `timeout` rejection. Never answers busy or asleep: the Mac would delete the delivery.
    /// Throws `.storageFailed` after a round in which files were refused for space and nothing arrived.
    /// - Parameter delivered: each delivery once the Mac has been told it arrived, and the files a
    ///   failed one saved first. The Mac deletes those deliveries: a later failure in the round
    ///   must not lose them. The round returns all of them too.
    @concurrent func receive(
        into directory: URL, automatically: Bool,
        decide: @escaping @Sendable (IncomingOffer) async -> Bool,
        progress: @escaping @Sendable (TransferProgress) -> Void,
        delivered: @escaping @Sendable ([ReceivedItem]) async -> Void = { _ in }
    ) async throws(ClientError) -> [ReceivedItem] {
        try await run { () async throws(ClientError) in
            try await write(Message(type: MessageType.receiveReady))
            var received: [ReceivedItem] = []
            var refusedForSpace = false
            while true {
                let message = try await inbox.next(timeout: Self.deliveryWait, stage: "delivery")
                switch message.type {
                case MessageType.nothingPending:
                    if refusedForSpace && received.isEmpty { throw .storageFailed }
                    return received
                case MessageType.text:
                    let text = try ClientError.decoding { try TextMessage(message) }
                    try await write(TransferMessages.textResult(text.transferId, copied: true))
                    Log.transfer.info("Text from \(self.mac.deviceId, privacy: .public): \(text.text.utf8.count) bytes")
                    received.append(.text(text.text))
                    await delivered([.text(text.text)])
                case MessageType.transferRequest:
                    let request = try ClientError.decoding { try IncomingRequest(message) }
                    Log.transfer.info("Delivery offered: \(request.files.count) file(s), \(request.totalSize) bytes")
                    let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                    if let free, free < request.totalSize + Self.freeSpaceMargin {
                        // The Mac deletes the delivery and goes on with the next one.
                        Log.transfer.warning("Refusing delivery: \(free) bytes free, \(request.totalSize) needed")
                        try await write(TransferMessages.reject(request.transferId, reason: .insufficientStorage))
                        refusedForSpace = true
                        continue
                    }
                    received += try await receiveFiles(request, into: directory, automatically: automatically, decide: decide, progress: progress,
                                                       delivered: delivered)
                case MessageType.cancel:
                    throw .cancelledByPeer
                default:
                    throw .protocolViolation("unexpected \(message.type) while waiting for a delivery")
                }
            }
        }
    }

    /// One file delivery. Returns what was saved: nothing after a decline or timeout. Files the
    /// Mac was told are saved stay saved when a later one fails (messages.md), and go to `delivered`.
    private func receiveFiles(
        _ request: IncomingRequest, into directory: URL, automatically: Bool,
        decide: @escaping @Sendable (IncomingOffer) async -> Bool,
        progress: @escaping @Sendable (TransferProgress) -> Void,
        delivered: @escaping @Sendable ([ReceivedItem]) async -> Void
    ) async throws(ClientError) -> [ReceivedItem] {
        let transferId = request.transferId
        state.withLock { $0.transferId = transferId }
        defer { state.withLock { $0.transferId = nil } }

        if !automatically {
            let offer = IncomingOffer(macName: mac.name, fileCount: request.files.count, totalSize: request.totalSize, firstName: request.files[0].name)
            switch await decision(offer, decide) {
            case .accepted:
                break
            case .declined:
                try await write(TransferMessages.reject(transferId, reason: .declined))
                Log.transfer.info("Delivery declined")
                return []
            case .timedOut:
                try await write(TransferMessages.reject(transferId, reason: .timeout))
                Log.transfer.info("Delivery not answered in time")
                return []
            case .macSpoke:
                guard let message = try inbox.poll() else { throw .cancelled }
                throw message.type == MessageType.cancel ? .cancelledByPeer : .protocolViolation("unexpected \(message.type) before the decision")
            }
        }

        try await write(TransferMessages.accept(transferId, fileCount: request.files.count))
        Log.transfer.info("Delivery accepted\(automatically ? " automatically" : "", privacy: .public)")
        var meter = ProgressMeter(totalBytes: request.totalSize, fileCount: request.files.count, firstName: request.files[0].name, report: progress)
        meter.update(phase: .transferring, force: true)
        var received: [ReceivedItem] = []

        do throws(ClientError) {
            for file in request.files {
                let beginMessage = try await nextInDelivery("file_begin")
                let begin = try ClientError.decoding { try FileBegin(beginMessage) }
                guard begin.transferId == transferId, begin.fileId == file.fileId, begin.offset == 0 else {
                    throw .protocolViolation("file_begin out of order")
                }
                // Why this file can't be saved. The rest of it is still read: the Mac reads answers only
                // after file_end, and a failure reported earlier would look like a lost connection to it,
                // which it retries forever (macimpact.md #10).
                var failure: SessionError?
                var writer: IncomingFileWriter?
                do {
                    writer = try IncomingFileWriter(directory: directory, info: file, origin: "\(mac.name) (Dewlet)")
                } catch {
                    failure = error as? SessionError ?? .writeFailed(String(describing: error))
                }
                defer { writer?.discard() }
                var written: Int64 = 0
                while written < file.size {
                    let message = try await nextInDelivery("file data")
                    let chunk = try ClientError.decoding { try FileChunk(message) }
                    guard chunk.transferId == transferId, chunk.fileId == file.fileId, chunk.offset == written,
                          written + Int64(chunk.data.count) <= file.size else {
                        throw .protocolViolation("file_chunk out of order")
                    }
                    if failure == nil, let writer {
                        do {
                            try writer.write(chunk.data)
                        } catch {
                            failure = error as? SessionError ?? .writeFailed(String(describing: error))
                            writer.discard()
                        }
                    }
                    written += Int64(chunk.data.count)
                    meter.update(adding: Int64(chunk.data.count), file: (file.fileId, file.name))
                }
                let endMessage = try await nextInDelivery("file_end")
                let end = try ClientError.decoding { try FileEnd(endMessage) }
                guard end.transferId == transferId, end.fileId == file.fileId else { throw .protocolViolation("file_end out of order") }
                meter.update(file: (file.fileId, file.name), force: true)

                // Answered at once: the Mac's 30 s stall watchdog counts this wait (macimpact.md #9).
                var saved: URL?
                if failure == nil, let writer {
                    do {
                        saved = try writer.finish(expectedSHA256: end.sha256)
                    } catch {
                        failure = error as? SessionError ?? .writeFailed(String(describing: error))
                    }
                }
                if let saved {
                    try await write(TransferMessages.fileResult(transferId, fileId: file.fileId, ok: true))
                    let mimeType = file.mimeType == "application/octet-stream"
                        ? UTType(filenameExtension: saved.pathExtension)?.preferredMIMEType ?? file.mimeType
                        : file.mimeType
                    received.append(.file(url: saved, name: saved.lastPathComponent, mimeType: mimeType, size: file.size))
                    continue
                }

                let code = switch failure {
                case .checksumMismatch: ErrorCode.checksumMismatch
                case .insufficientStorage: ErrorCode.insufficientStorage
                default: ErrorCode.writeFailed
                }
                Log.transfer.error("File \(file.fileId) not saved: \(code, privacy: .public)")
                // The Mac drops the delivery on file_result{false} and closes the connection (critic.md A3).
                await self.end(sending: [TransferMessages.fileResult(transferId, fileId: file.fileId, ok: false, code: code),
                                         TransferMessages.transferResult(transferId, completed: false, code: code)],
                               drain: Self.cancelDrain)
                throw code == ErrorCode.checksumMismatch ? .receiverFailed(code: code) : .storageFailed
            }

            let complete = try await nextInDelivery("transfer_complete")
            guard complete.type == MessageType.transferComplete,
                  try ClientError.decoding({ try complete.bytes("transferId", count: 16) }) == transferId else {
                throw .protocolViolation("expected transfer_complete, got \(complete.type)")
            }
            try await write(TransferMessages.transferResult(transferId, completed: true))
        } catch {
            if !received.isEmpty { await delivered(received) }
            throw error
        }
        Log.transfer.info("Delivery complete: \(received.count) file(s), \(request.totalSize) bytes")
        await delivered(received)
        return received
    }

    /// The next message of a delivery; the Mac may cancel between any two.
    private func nextInDelivery(_ stage: String) async throws(ClientError) -> Message {
        let message = try await inbox.next(timeout: Self.frameTimeout, stage: stage)
        if message.type == MessageType.cancel { throw .cancelledByPeer }
        return message
    }

    /// The user's answer while the Mac may cancel (its message stays in the inbox), for at most 170 s.
    private func decision(_ offer: IncomingOffer, _ decide: @escaping @Sendable (IncomingOffer) async -> Bool) async -> Decision {
        let (events, sink) = AsyncStream.makeStream(of: Decision.self)
        let local = Task { sink.yield(await decide(offer) ? .accepted : .declined) }
        let mac = Task { [inbox] in sink.yield(await inbox.wait(timeout: Self.decisionTimeout) ? .macSpoke : .timedOut) }
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next() ?? .timedOut
        // The loser's answer is dropped: a decide that ignores cancellation only finishes late.
        local.cancel()
        mac.cancel()
        sink.finish()
        return first
    }
}
