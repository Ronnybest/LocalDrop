import Foundation
import Observation

/// The app's live connection to one paired Mac while the app is in the foreground.
///
/// One session per Mac, kept open: every 4 s a receive round (`receive_ready` → deliveries →
/// `nothing_pending`) on the same session, queued sends in between. A new connection per poll
/// would add an "ended connection" entry to the Mac's menu and a trust-file write each time.
/// When the session drops it reconnects, waiting 2 s, 5 s, 10 s, then 30 s while the Mac stays
/// unreachable. `stop()` lets a running transfer and queued sends finish, then closes politely.
@MainActor @Observable final class MacLink {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case unreachable(ClientError)
        /// The Mac doesn't trust this iPhone any more: pair again.
        case notPaired
    }

    enum Activity: Equatable {
        /// nil progress: preparing or connecting.
        case sending(TransferProgress?, summary: String)
        case receiving(TransferProgress?, summary: String)
        /// The UI asks; `answer(_:)` replies.
        case awaitingDecision(IncomingOffer)
    }

    let macId: String
    private(set) var state: State = .idle
    /// What runs right now, for the UI.
    private(set) var activity: Activity?

    private static let pollInterval: TimeInterval = 4
    private static let retryDelays: [TimeInterval] = [2, 5, 10, 30]

    private enum Work {
        case files([OutgoingItem])
        case text(String)
    }

    private struct Job {
        let work: Work
        let summary: String
        let done: CheckedContinuation<Result<Void, ClientError>, Never>
    }

    @ObservationIgnored private var mac: PairedMac
    @ObservationIgnored private let phone: Phone
    @ObservationIgnored private let store: MacStore
    @ObservationIgnored private weak var delegate: MacLinkDelegate?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var stopping = false
    /// `interrupt()` closed the session: a send it cut off failed, it wasn't cancelled.
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var session: ClientSession?
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?
    /// Progress reports hop to the main actor one by one; only the current activity's apply.
    @ObservationIgnored private var activityGeneration = 0
    @ObservationIgnored private var wake: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    @ObservationIgnored private var lastWakeId = 0
    @ObservationIgnored private var poked = false

    init(mac: PairedMac, phone: Phone, delegate: MacLinkDelegate, store: MacStore = .shared) {
        macId = mac.id
        self.mac = mac
        self.phone = phone
        self.delegate = delegate
        self.store = store
    }

    func start() {
        stopping = false
        interrupted = false
        guard loop == nil else { return poke() }
        loop = Task { await run() }
    }

    /// Ends the link: a running transfer and queued sends go first (the app keeps a background
    /// task for them); no more receive rounds. An offer is left unanswered, now or when one comes
    /// in the meantime: the connection closes without a word, and the Mac keeps the delivery and
    /// offers it again next time (an answer, even a timeout, would make it delete the delivery).
    func stop() {
        guard loop != nil, !stopping else { return }
        stopping = true
        if case .awaitingDecision = activity { session?.interrupt() }
        resume()
    }

    /// iOS ends the app's background time: queued sends fail (their card offers Try Again) and
    /// the session closes without a word, so the Mac keeps what it was delivering and offers it
    /// again; a cancel would make it delete it.
    func interrupt() {
        interrupted = true
        failJobs(.connectionLost)
        session?.interrupt()
    }

    /// Queues the files; they go as soon as the session is free, connecting first if needed.
    func send(_ items: [OutgoingItem]) async throws(ClientError) {
        guard !items.isEmpty else { return }
        try await enqueue(.files(items), summary: Self.summary(fileCount: items.count, firstName: items[0].name))
    }

    func send(text: String) async throws(ClientError) {
        try await enqueue(.text(text), summary: String(localized: "Text", table: "Core"))
    }

    /// Cancels the running transfer; an offer waiting for an answer is declined.
    func cancelActivity() {
        switch activity {
        case .awaitingDecision: answer(false)
        case .sending, .receiving: session?.cancel()
        case nil: break
        }
    }

    /// The answer to `.awaitingDecision`.
    func answer(_ accept: Bool) {
        guard let decision else { return }
        self.decision = nil
        if case .awaitingDecision(let offer) = activity {
            activity = accept ? .receiving(nil, summary: Self.summary(fileCount: offer.fileCount, firstName: offer.firstName)) : nil
        }
        decision.resume(returning: accept)
    }

    /// Wakes the loop now: pull to refresh, the app became active, a retry after an error.
    func poke() {
        if wake != nil { resume() } else { poked = true }
    }

    // MARK: - Loop

    private func run() async {
        var failures = 0
        while !stopping || !jobs.isEmpty {
            if session?.isClosed ?? true {
                session = nil
                switch state {
                case .unreachable, .notPaired: break // keeps saying why while it retries
                default: state = .connecting
                }
                // The record as it is now: the last endpoint changes with every session.
                let current = store.mac(macId) ?? mac
                mac = current
                do {
                    let opened = try await ClientSession.open(to: current, phone: phone, name: Phone.name, store: store)
                    session = opened
                    state = .connected
                    failures = 0
                } catch {
                    failJobs(error)
                    if error == .notPaired || error == .authenticationFailed {
                        // Asked again only on poke() or start(): a Mac in pairing mode shows its
                        // pairing prompt for every attempt, and another key needs pairing again,
                        // not another try (each one a failed session in the Mac's menu).
                        state = error == .notPaired ? .notPaired : .unreachable(error)
                        await pause(nil)
                    } else {
                        state = .unreachable(error)
                        await pause(Self.retryDelays[min(failures, Self.retryDelays.count - 1)])
                        failures += 1
                    }
                    continue
                }
            }
            guard let session else { continue }

            while !jobs.isEmpty, !session.isClosed {
                await perform(jobs.removeFirst(), on: session)
            }
            if !stopping, !session.isClosed, session.mac.capabilities.contains("send") {
                await receiveRound(on: session)
            }
            if !stopping, jobs.isEmpty {
                // A dropped session reconnects after a moment, not in a tight loop.
                await pause(session.isClosed ? Self.retryDelays[0] : Self.pollInterval)
            }
        }
        if let session { await session.close() }
        session = nil
        loop = nil
        state = .idle
        activity = nil
        // start() or a send while the last transfer finished: go on.
        if !stopping || !jobs.isEmpty { loop = Task { await run() } }
    }

    private func perform(_ job: Job, on session: ClientSession) async {
        activityGeneration += 1
        let generation = activityGeneration
        activity = .sending(nil, summary: job.summary)
        let report: @Sendable (TransferProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.activityGeneration == generation, self.activity != nil else { return }
                self.activity = .sending(progress, summary: job.summary)
            }
        }
        let result: Result<Void, ClientError>
        do {
            switch job.work {
            case .files(let items): try await session.send(items, progress: report)
            case .text(let text): try await session.send(text: text)
            }
            result = .success(())
            delegate?.link(self, finishedSending: job.summary, to: session.mac.name)
        } catch {
            result = .failure(interrupted && error == .cancelled ? .connectionLost : error)
        }
        activityGeneration += 1
        activity = nil
        job.done.resume(returning: result)
    }

    private func receiveRound(on session: ClientSession) async {
        guard let delegate else { return }
        let directory = delegate.receiveDirectory
        let automatically = (store.mac(macId) ?? mac).receiveAutomatically
        activityGeneration += 1
        let generation = activityGeneration
        let report: @Sendable (TransferProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.activityGeneration == generation, self.decision == nil else { return }
                self.activity = .receiving(progress, summary: Self.summary(fileCount: progress.fileCount, firstName: progress.fileName))
            }
        }
        let macName = session.mac.name
        do {
            _ = try await session.receive(into: directory, automatically: automatically, decide: { [weak self] offer in
                await self?.ask(offer) ?? false
            }, progress: report, delivered: { @MainActor [weak self] items in
                // Each delivery as it ends: a later one failing in the same round doesn't lose it.
                guard let self else { return }
                self.activity = nil
                self.delegate?.link(self, received: items, from: macName)
            })
            activityGeneration += 1
            activity = nil
        } catch {
            activityGeneration += 1
            let wasDelivering = activity != nil
            activity = nil
            // Connection trouble shows in `state` on reconnecting; a delivery that went wrong is news.
            if error != .cancelled, wasDelivering || !error.isTemporary {
                delegate.link(self, failed: error, macName: session.mac.name)
            }
        }
    }

    private func ask(_ offer: IncomingOffer) async -> Bool {
        // Not asked in the background: see stop(). The answer below never reaches the Mac.
        if stopping {
            session?.interrupt()
            return false
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                decision?.resume(returning: false)
                decision = continuation
                activity = .awaitingDecision(offer)
            }
        } onCancel: {
            // Core stopped waiting (the Mac cancelled, or 170 s passed).
            Task { @MainActor [weak self] in
                guard let self, self.decision != nil else { return }
                self.answer(false)
            }
        }
    }

    /// A link that is stopping runs the send too, then stops.
    private func enqueue(_ work: Work, summary: String) async throws(ClientError) {
        if loop == nil { loop = Task { await run() } }
        let result = await withCheckedContinuation { continuation in
            jobs.append(Job(work: work, summary: summary, done: continuation))
            poke()
        }
        try result.get()
    }

    private func failJobs(_ error: ClientError) {
        for job in jobs { job.done.resume(returning: .failure(error)) }
        jobs = []
    }

    /// Sleeps `seconds` (nil: no limit), or until `poke()` or `stop()`.
    private func pause(_ seconds: TimeInterval?) async {
        if poked || stopping {
            poked = false
            return
        }
        lastWakeId += 1
        let id = lastWakeId
        await withCheckedContinuation { continuation in
            wake = (id, continuation)
            guard let seconds else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.resume(id)
            }
        }
    }

    private func resume(_ id: Int? = nil) {
        guard let wake, id == nil || wake.id == id else { return }
        self.wake = nil
        wake.continuation.resume()
    }

    private static func summary(fileCount: Int, firstName: String) -> String {
        fileCount == 1 ? firstName : String(localized: "\(fileCount) files", table: "Core")
    }
}

@MainActor protocol MacLinkDelegate: AnyObject {
    /// Where received files go (the app's Documents).
    var receiveDirectory: URL { get }
    func link(_ link: MacLink, received items: [ReceivedItem], from macName: String)
    func link(_ link: MacLink, finishedSending summary: String, to macName: String)
    /// A delivery from the Mac that went wrong (cancelled on the Mac, no space, …). Connection
    /// trouble shows in `state` instead, and `send` throws its own errors.
    func link(_ link: MacLink, failed error: ClientError, macName: String)
}
