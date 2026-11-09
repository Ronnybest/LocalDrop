import CryptoKit
import Foundation
import os

/// iPhone → Mac (transfer.md §1; Android `runTransfer`, `runText`; the Mac's `TransferReceiver`).
nonisolated extension ClientSession {
    /// Longer than the Mac's 120 s decision, so its own `timeout` answer arrives first.
    static let approvalTimeout: TimeInterval = 135
    static let replyTimeout: TimeInterval = 60
    /// No chunk taken by the network for this long: the Mac is gone (a send blocked on a full
    /// buffer sees nothing otherwise). The reply waits count too, as on Android.
    private static let stallTimeout: Duration = .seconds(30)
    /// After a failed write, how long the Mac's own explanation may take to arrive.
    private static let explanationWait: TimeInterval = 0.5

    /// Sends files: one `transfer_request` per 1000 (the Mac's limit), each streamed after the
    /// Mac accepts. A rejection keeps the session usable.
    @concurrent func send(_ items: [OutgoingItem], progress: @escaping @Sendable (TransferProgress) -> Void) async throws(ClientError) {
        guard let first = items.first else { return }
        try await run { () async throws(ClientError) in
            var meter = ProgressMeter(totalBytes: items.reduce(0) { $0 + $1.size }, fileCount: items.count, firstName: first.name, report: progress)
            for start in stride(from: 0, to: items.count, by: TransferRequest.maxFiles) {
                try await transfer(items, range: start..<min(start + TransferRequest.maxFiles, items.count), meter: &meter)
            }
        }
    }

    /// To the Mac's clipboard as `text` when it takes clipboard text and the text is 1…262144
    /// UTF-8 bytes; otherwise as a "Text yyyy-MM-dd HH.mm.ss.txt" file (Android `TransferSource`).
    @concurrent func send(text: String) async throws(ClientError) {
        let size = text.utf8.count
        guard size > 0 else { throw .sourceUnavailable(name: "Text") }
        if mac.capabilities.contains(ProtocolConstants.clipboardReceiveCapability) && size <= ProtocolConstants.maxTextSize {
            try await run { () async throws(ClientError) in
                // Not named in a cancel: the Mac answers text at once and would take a later cancel as bad_message.
                let transferId = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
                try await write(OutgoingMessages.text(transferId, text: text))
                let answer = try await inbox.next(timeout: Self.replyTimeout, stage: "text_result")
                guard answer.type == MessageType.textResult else {
                    throw answer.type == MessageType.cancel ? .cancelledByPeer : .protocolViolation("unexpected \(answer.type) instead of text_result")
                }
                let status = (try? answer.text("status", maxBytes: 64)) ?? RejectReason.declined.rawValue
                Log.transfer.info("Text sent: \(size) bytes, \(status, privacy: .public)")
                guard status == "copied" else { throw .transferRejected(reason: status) }
            }
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = directory.appending(path: "Text \(formatter.string(from: Date())).txt")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        } catch {
            throw .storageFailed
        }
        try await send([try OutgoingItem.file(url)], progress: { _ in })
    }

    /// One `transfer_request` for `items[range]`: request, the Mac's decision, then every file with
    /// its SHA-256 and the Mac's `file_result`, then `transfer_complete` → `transfer_result`.
    private func transfer(_ items: [OutgoingItem], range: Range<Int>, meter: inout ProgressMeter) async throws(ClientError) {
        let batch = Array(items[range])
        // Checked before announcing: nothing on the wire for files that are gone.
        for item in batch where !FileManager.default.isReadableFile(atPath: item.url.path) {
            throw .sourceUnavailable(name: item.name)
        }
        let transferId = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let infos = batch.enumerated().map { index, item in
            TransferFileInfo(fileId: index, name: item.name, mimeType: item.mimeType, size: item.size,
                             lastModified: item.modified.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) })
        }
        try await write(OutgoingMessages.request(transferId, files: infos))
        // Named in a cancel only once the Mac has the request: a cancel before it would be bad_message,
        // a bare close ends the request too.
        state.withLock { $0.transferId = transferId }
        Log.transfer.info("transfer_request sent: \(batch.count) file(s), \(infos.reduce(0) { $0 + $1.size }) bytes")
        meter.update(file: (range.lowerBound, batch[0].name), phase: .waitingForAcceptance, force: true)

        let answer = try await inbox.next(timeout: Self.approvalTimeout, stage: "approval")
        switch answer.type {
        case MessageType.transferAccept:
            // Its fileCount covers more than the request only after transfer_add, which this client never sends.
            Log.transfer.info("Transfer accepted")
        case MessageType.transferReject:
            // The Mac goes on reading: the session carries on.
            state.withLock { $0.transferId = nil }
            throw .transferRejected(reason: (try? answer.text("reason", maxBytes: 64)) ?? RejectReason.declined.rawValue)
        case MessageType.cancel:
            throw .cancelledByPeer
        default:
            throw .protocolViolation("unexpected \(answer.type) instead of transfer_accept")
        }

        let lastProgress = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let stalled = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task { [channel] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard ContinuousClock.now - lastProgress.withLock({ $0 }) > Self.stallTimeout else { continue }
                Log.transfer.warning("No progress for 30 s; closing the connection")
                stalled.withLock { $0 = true }
                channel.closeConnection()
                return
            }
        }
        defer { watchdog.cancel() }

        do throws(ClientError) {
            for (index, item) in batch.enumerated() {
                try await write(OutgoingMessages.fileBegin(transferId, fileId: index))
                let handle: FileHandle
                do {
                    handle = try FileHandle(forReadingFrom: item.url)
                } catch {
                    throw await sourceFailed(item, transferId: transferId)
                }
                defer { try? handle.close() }
                var hasher = SHA256()
                var offset: Int64 = 0
                while offset < item.size {
                    // Between chunks the Mac may only have cancelled or reported a failure.
                    if let message = try inbox.poll() { throw Self.unexpected(message) }
                    if state.withLock({ $0.cancelled }) { throw .cancelled }
                    let data: Data
                    do {
                        guard let read = try handle.read(upToCount: Int(min(Int64(ProtocolConstants.chunkSize), item.size - offset))), !read.isEmpty else {
                            throw CocoaError(.fileReadUnknown)
                        }
                        data = read
                    } catch {
                        throw await sourceFailed(item, transferId: transferId)
                    }
                    hasher.update(data: data)
                    try await write(OutgoingMessages.fileChunk(transferId, fileId: index, offset: offset, data: data), pipelined: true)
                    offset += Int64(data.count)
                    lastProgress.withLock { $0 = ContinuousClock.now }
                    meter.update(adding: Int64(data.count), file: (range.lowerBound + index, item.name), phase: .transferring)
                }
                try await write(OutgoingMessages.fileEnd(transferId, fileId: index, sha256: Data(hasher.finalize())))
                let last = index == batch.count - 1
                meter.update(file: (range.lowerBound + index, item.name), phase: last && range.upperBound == items.count ? .verifying : .transferring, force: true)
                lastProgress.withLock { $0 = ContinuousClock.now }
                let result = try await reply(MessageType.fileResult)
                guard (try? result.bool("ok")) == true else {
                    throw .receiverFailed(code: (try? result.text("code", maxBytes: 64)) ?? "unknown")
                }
            }
            try await write(OutgoingMessages.transferComplete(transferId))
            lastProgress.withLock { $0 = ContinuousClock.now }
            let result = try await reply(MessageType.transferResult)
            guard (try? result.text("status", maxBytes: 64)) == "completed" else {
                throw .receiverFailed(code: (try? result.text("code", maxBytes: 64)) ?? "unknown")
            }
        } catch {
            if stalled.withLock({ $0 }) { throw .timeout(stage: "transfer progress") }
            // The Mac often explains before it closes (cancel, a failed file, trust revoked), and a
            // write can fail before the reader has that message.
            if error == .connectionLost || error == .cancelled, !state.withLock({ $0.cancelled }), let explanation = await explanation() {
                throw explanation
            }
            throw error
        }
        state.withLock { $0.transferId = nil }
        Log.transfer.info("Transfer complete: \(batch.count) file(s)")
    }

    private func reply(_ type: String) async throws(ClientError) -> Message {
        let message = try await inbox.next(timeout: Self.replyTimeout, stage: type)
        guard message.type == type else { throw Self.unexpected(message) }
        return message
    }

    private static func unexpected(_ message: Message) -> ClientError {
        switch message.type {
        case MessageType.cancel: .cancelledByPeer
        case MessageType.fileResult, MessageType.transferResult: .receiverFailed(code: (try? message.text("code", maxBytes: 64)) ?? "unknown")
        default: .protocolViolation("unexpected \(message.type) during transfer")
        }
    }

    /// The Mac's own reason for ending the transfer, if it sent one just before closing (Android `peerExplanation`).
    private func explanation() async -> ClientError? {
        guard await inbox.wait(timeout: Self.explanationWait) else { return nil }
        do {
            return try inbox.poll().map(Self.unexpected)
        } catch {
            if case .peerError = error { return error }
            return nil
        }
    }

    /// The file can't be read any more: the Mac is told with cancel{source_unavailable} and the session ends.
    private func sourceFailed(_ item: OutgoingItem, transferId: Data) async -> ClientError {
        Log.transfer.error("Cannot read \(item.name, privacy: .private) any more")
        await end(sending: [TransferMessages.cancel(transferId, reason: ErrorCode.sourceUnavailable)], drain: Self.cancelDrain)
        return .sourceUnavailable(name: item.name)
    }
}
