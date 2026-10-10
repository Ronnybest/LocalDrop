import Foundation
import os

/// What the user (or the system) decided about a transfer request.
nonisolated enum TransferDecision: Sendable {
    case accept
    case decline
    /// The Mac went to sleep with the request on screen: nobody can answer it.
    case unattended
}

nonisolated enum TransferOutcome: Sendable {
    case completed([URL])
    case declined
    /// Answered `asleep`: the sender keeps the transfer and retries when the Mac is awake.
    case unattended
    case timedOut
    case rejectedNoSpace
    case cancelledByPeer
    case cancelled
    case failed(String)
}

/// Whether the system is between will-sleep and wake. Read without hopping to the main actor:
/// in a dark wake the main thread may not run before the system sleeps again, and a request
/// waiting for it would hang until the Mac wakes for real.
nonisolated enum SystemSleep {
    private static let state = OSAllocatedUnfairLock(initialState: false)

    static var isAsleep: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Lets the UI cancel a running transfer; checked by the receiver between frames.
nonisolated final class TransferCancelToken: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func cancel() { state.withLock { $0 = true } }
    var isCancelled: Bool { state.withLock { $0 } }
}

/// Where received files go: the folder the user picked (see `SaveFolder`), or Downloads —
/// resolved through the sandbox container's symlink so "Show in Finder" opens the real folder.
nonisolated enum ReceiveLocation {
    private static let chosen = OSAllocatedUnfairLock<URL?>(initialState: nil)

    static var downloads: URL { URL.downloadsDirectory.resolvingSymlinksInPath() }

    /// Set by `SaveFolder` while it holds security-scoped access to the folder.
    static func setChosenDirectory(_ url: URL?) {
        chosen.withLock { $0 = url }
    }

    /// The chosen folder while it is reachable; Downloads otherwise (an external drive that was
    /// unplugged, a folder deleted since), so a transfer never fails for want of a folder.
    static func directory() -> URL {
        guard let url = chosen.withLock({ $0 }) else { return downloads }
        guard isReachable(url) else {
            Log.transfer.warning("Chosen folder unavailable; saving to Downloads")
            return downloads
        }
        return url
    }

    static func isReachable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func availableCapacity(_ directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Receiving side of one `transfer_request` (protocol/messages.md, «Передача»).
nonisolated final class TransferReceiver {
    static let decisionTimeout: TimeInterval = 120
    static let idleTransferTimeout: TimeInterval = 30
    /// Disk space kept free beyond the announced size.
    static let freeSpaceMargin: Int64 = 100 * 1024 * 1024
    private static let progressInterval: Duration = .milliseconds(100)
    private static let cancelDrainTimeout: Duration = .seconds(2)

    private enum DecisionEvent: Sendable {
        /// `transfer_add`: more files for the request on screen.
        case added(Message)
        case peer(Result<Message, any Error>)
        case local(TransferDecision)
        case timeout
    }

    private let entryId: UUID
    private let peer: PeerInfo
    private let channel: SecureChannel
    private let coordinator: any SessionCoordinator

    init(entryId: UUID, peer: PeerInfo, channel: SecureChannel, coordinator: any SessionCoordinator) {
        self.entryId = entryId
        self.peer = peer
        self.channel = channel
        self.coordinator = coordinator
    }

    /// Handles one transfer. Returns a receive already in flight whose result is the session's
    /// next message (after a decline or timeout, the sender's next step is read there).
    func handle(_ message: Message) async throws -> Task<Message, any Error>? {
        let request = try TransferRequest(message)
        Log.transfer.info("transfer_request from \(self.peer.deviceId, privacy: .public): \(request.files.count) file(s), \(request.totalSize) bytes")

        // Asleep (lid closed, dark wake): macOS still answers the network now and then, but no
        // one can see a prompt and a transfer would be cut off by the next sleep. The sender
        // waits and retries when this Mac advertises again after waking. Checked first and
        // without suspending, so the answer goes out within this dark wake.
        if SystemSleep.isAsleep {
            Log.transfer.info("Answering asleep: this Mac is sleeping")
            try await channel.send(TransferMessages.reject(request.transferId, reason: .asleep))
            return nil
        }

        let policy = await coordinator.acceptPolicy(for: peer)
        let decision = policy.decision(for: request.files, totalSize: request.totalSize)
        if decision == .decline {
            Log.transfer.info("Declining transfer: policy \(policy.rawValue, privacy: .public)")
            try await channel.send(TransferMessages.reject(request.transferId, reason: .declined))
            return nil
        }

        let directory = ReceiveLocation.directory()
        if let available = ReceiveLocation.availableCapacity(directory), available < request.totalSize + Self.freeSpaceMargin {
            Log.transfer.warning("Rejecting transfer: \(available) bytes free, \(request.totalSize) needed")
            try await channel.send(TransferMessages.reject(request.transferId, reason: .insufficientStorage))
            await coordinator.transferRejectedForStorage(peer: peer, request: request)
            return nil
        }

        let token = TransferCancelToken()
        do {
            let autoAccepted = decision == .accept
            if autoAccepted { Log.transfer.info("Accepting without asking: policy \(policy.rawValue, privacy: .public)") }
            try await coordinator.beginIncomingTransfer(entryId, peer: peer, request: request, autoAccepted: autoAccepted) { token.cancel() }
        } catch SessionError.busy {
            Log.transfer.warning("Rejecting transfer: another transfer is in progress")
            try await channel.send(TransferMessages.reject(request.transferId, reason: .busy))
            return nil
        }

        do {
            return try await decideAndReceive(request, directory: directory, token: token)
        } catch {
            let outcome: TransferOutcome = switch error as? SessionError {
            case .transferCancelled(let byPeer): byPeer ? .cancelledByPeer : .cancelled
            case let sessionError?: .failed(sessionError.userMessage)
            case nil: .failed(String(describing: error))
            }
            await coordinator.transferFinished(entryId, outcome: outcome)
            throw error
        }
    }

    /// `text` → clipboard, answered at once with `text_result`.
    func handleText(_ message: Message) async throws {
        let text = try TextMessage(message)
        let copied = await coordinator.textReceived(text.text, peer: peer)
        Log.transfer.info("text from \(self.peer.deviceId, privacy: .public): \(text.text.utf8.count) bytes, \(copied ? "copied" : "declined", privacy: .public)")
        try await channel.send(TransferMessages.textResult(text.transferId, copied: copied))
    }

    private func decideAndReceive(_ initial: TransferRequest, directory: URL, token: TransferCancelToken) async throws -> Task<Message, any Error>? {
        // Keep reading while the user decides: a sender-side cancel dismisses the prompt, and
        // files shared meanwhile are added to it.
        let channel = channel
        let coordinator = coordinator
        let entryId = entryId
        let (events, sink) = AsyncStream<DecisionEvent>.makeStream()
        // Returns the first message that isn't `transfer_add`; adds read after the decision
        // (sent before the sender saw it) are left out, which `fileCount` tells the sender.
        let pending = Task {
            while true {
                let result: Result<Message, any Error>
                do {
                    result = .success(try await channel.receive(timeout: Self.decisionTimeout + Self.idleTransferTimeout, stage: "transfer start"))
                } catch {
                    result = .failure(error)
                }
                if case .success(let message) = result, message.type == MessageType.transferAdd {
                    sink.yield(.added(message))
                    continue
                }
                sink.yield(.peer(result))
                return try result.get()
            }
        }
        let decision = Task { sink.yield(.local(await coordinator.awaitTransferDecision(entryId))) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(Self.decisionTimeout))
            if !Task.isCancelled { sink.yield(.timeout) }
        }
        var request = initial
        /// Files the decision covers: all announced ones, unless an add didn't fit on disk.
        var included = request.files.count
        var full = false
        var iterator = events.makeAsyncIterator()
        var first: DecisionEvent?
        while let event = await iterator.next() {
            guard case .added(let message) = event else {
                first = event
                break
            }
            do {
                try request.append(message)
            } catch {
                sink.finish()
                timer.cancel()
                decision.cancel()
                throw error
            }
            if !full, let available = ReceiveLocation.availableCapacity(directory), available < request.totalSize + Self.freeSpaceMargin {
                // Later adds can't be included either: the decision covers a prefix.
                Log.transfer.warning("Not adding files: \(available) bytes free, \(request.totalSize) needed")
                full = true
            }
            guard !full else { continue }
            included = request.files.count
            Log.transfer.info("transfer_add: now \(included) file(s), \(request.totalSize) bytes")
            await coordinator.transferRequestGrew(entryId, request: request)
        }
        sink.finish()
        timer.cancel()
        let decided = request.prefix(included)

        switch first {
        case .added:
            preconditionFailure("adds are consumed above")
        case .peer(let result):
            decision.cancel()
            let message = try result.get()
            Log.transfer.info("Sender ended the request before a decision (\(message.type, privacy: .public))")
            await coordinator.transferFinished(entryId, outcome: .cancelledByPeer)
            if message.type == MessageType.cancel { return nil }
            return Task { message }
        case .local(.decline):
            Log.transfer.info("User declined the transfer")
            try await channel.send(TransferMessages.reject(decided.transferId, reason: .declined, fileCount: included))
            await coordinator.transferFinished(entryId, outcome: .declined)
            return pending
        case .local(.unattended):
            Log.transfer.info("Going to sleep with the request unanswered: answering asleep")
            try await channel.send(TransferMessages.reject(decided.transferId, reason: .asleep, fileCount: included))
            await coordinator.transferFinished(entryId, outcome: .unattended)
            return pending
        case .timeout, nil:
            decision.cancel()
            Log.transfer.info("Transfer request timed out")
            try await channel.send(TransferMessages.reject(decided.transferId, reason: .timeout, fileCount: included))
            await coordinator.transferFinished(entryId, outcome: .timedOut)
            return pending
        case .local(.accept):
            try await channel.send(TransferMessages.accept(decided.transferId, fileCount: included))
            await coordinator.transferStarted(entryId)
            let urls = try await receiveFiles(decided, directory: directory, token: token, firstMessage: pending)
            await coordinator.transferFinished(entryId, outcome: .completed(urls))
            return nil
        }
    }

    private func receiveFiles(
        _ request: TransferRequest,
        directory: URL,
        token: TransferCancelToken,
        firstMessage: Task<Message, any Error>
    ) async throws -> [URL] {
        let transferId = request.transferId
        let started = ContinuousClock.now
        // Idle sleep would cut the transfer off; the display may still sleep.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Receiving files from \(peer.name)"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var lastProgress = started
        var received: Int64 = 0
        var bufferedFirst: Task<Message, any Error>? = firstMessage
        var savedURLs: [URL] = []

        func next(_ stage: String) async throws -> Message {
            if token.isCancelled {
                Log.transfer.info("Transfer cancelled on this Mac")
                try? await channel.send(TransferMessages.cancel(transferId, reason: "user_cancelled"))
                await drainUntilPeerCloses()
                throw SessionError.transferCancelled(byPeer: false)
            }
            let message: Message
            if let first = bufferedFirst {
                bufferedFirst = nil
                message = try await first.value
            } else {
                message = try await channel.receive(timeout: Self.idleTransferTimeout, stage: stage)
            }
            if message.type == MessageType.cancel {
                Log.transfer.info("Transfer cancelled by sender")
                throw SessionError.transferCancelled(byPeer: true)
            }
            return message
        }

        func requireTransfer(_ id: Data) throws {
            guard id == transferId else { throw SessionError.protocolViolation("unknown transferId") }
        }

        for file in request.files {
            let begin = try FileBegin(await next("file_begin"))
            try requireTransfer(begin.transferId)
            guard begin.fileId == file.fileId else { throw SessionError.protocolViolation("file_begin out of order") }
            // Resume is reserved by the protocol but not implemented in v1.
            guard begin.offset == 0 else { throw SessionError.protocolViolation("file_begin offset must be 0") }

            let fileStarted = ContinuousClock.now
            let writer: IncomingFileWriter
            do {
                writer = try IncomingFileWriter(directory: directory, info: file, origin: "\(peer.name) (Local Drop)")
            } catch {
                try await reportFailure(error, transferId: transferId, fileId: file.fileId)
                throw error
            }
            do {
                while writer.bytesWritten < file.size {
                    let chunk = try FileChunk(await next("file data"))
                    try requireTransfer(chunk.transferId)
                    guard chunk.fileId == file.fileId, chunk.offset == writer.bytesWritten else {
                        throw SessionError.protocolViolation("file_chunk out of order")
                    }
                    guard writer.bytesWritten + Int64(chunk.data.count) <= file.size else {
                        throw SessionError.protocolViolation("file_chunk exceeds announced size")
                    }
                    try writer.write(chunk.data)
                    received += Int64(chunk.data.count)

                    let now = ContinuousClock.now
                    if now - lastProgress >= Self.progressInterval {
                        lastProgress = now
                        await coordinator.transferProgress(entryId, bytesReceived: received, currentFile: file.name)
                    }
                }
                let end = try FileEnd(await next("file_end"))
                try requireTransfer(end.transferId)
                guard end.fileId == file.fileId else { throw SessionError.protocolViolation("file_end out of order") }
                await coordinator.transferProgress(entryId, bytesReceived: received, currentFile: file.name)
                let url = try writer.finish(expectedSHA256: end.sha256)
                savedURLs.append(url)
                try await channel.send(TransferMessages.fileResult(transferId, fileId: file.fileId, ok: true))
                Log.transfer.info("Saved file \(file.fileId) (\(file.size) bytes, SHA-256 verified) at \(Self.rate(file.size, since: fileStarted), privacy: .public)")
            } catch {
                writer.discard()
                try await reportFailure(error, transferId: transferId, fileId: file.fileId)
                throw error
            }
        }

        let complete = try await next("transfer_complete")
        try complete.expect(MessageType.transferComplete)
        try requireTransfer(try complete.bytes("transferId", count: 16))
        try await channel.send(TransferMessages.transferResult(transferId, completed: true))
        Log.transfer.info("Transfer complete: \(request.totalSize) bytes at \(Self.rate(request.totalSize, since: started), privacy: .public)")
        return savedURLs
    }

    /// After `cancel`, chunks the sender wrote before seeing it are still arriving. Closing now
    /// would reset the connection (unread data), and a reset makes the sender's TCP stack drop
    /// the `cancel` itself — the sender would see a lost connection and retry. So read until the
    /// sender closes, briefly.
    private func drainUntilPeerCloses() async {
        let deadline = ContinuousClock.now + Self.cancelDrainTimeout
        while ContinuousClock.now < deadline {
            let remaining = deadline - ContinuousClock.now
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            do {
                _ = try await channel.receive(timeout: max(seconds, 0.05), stage: "cancel")
            } catch {
                return
            }
        }
    }

    /// Tells the sender which file failed and why, for failures the receiver itself detected.
    private func reportFailure(_ error: Error, transferId: Data, fileId: Int) async throws {
        let code: String? = switch error as? SessionError {
        case .checksumMismatch: ErrorCode.checksumMismatch
        case .writeFailed: ErrorCode.writeFailed
        case .insufficientStorage: ErrorCode.insufficientStorage
        default: nil
        }
        guard let code else { return }
        Log.transfer.error("File \(fileId) failed: \(code, privacy: .public)")
        try await channel.send(TransferMessages.fileResult(transferId, fileId: fileId, ok: false, code: code))
        try await channel.send(TransferMessages.transferResult(transferId, completed: false, code: code))
    }

    private static func rate(_ bytes: Int64, since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else { return "-" }
        return String(format: "%.1f MB/s in %.2f s", Double(bytes) / 1_000_000 / seconds, seconds)
    }
}
