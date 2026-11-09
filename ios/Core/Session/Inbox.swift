import Foundation
import os

/// Everything the Mac sends after the handshake, read by one task for the whole session.
/// `FrameConnection` allows one receive at a time and any of its timeouts closes the
/// connection, so operations wait here with their own deadlines, or look without waiting
/// between chunks (Android `checkInbox`). Waiting consumes nothing: a wait that loses a race
/// (to the user's decision, say) leaves the message for the next reader.
nonisolated final class Inbox: Sendable {
    /// Messages held before the reader stops reading: TCP then slows the Mac down.
    private static let capacity = 32

    private struct Waiter: Sendable {
        let continuation: CheckedContinuation<Bool, Never>
        let deadline: WaitDeadline
    }

    private struct State: Sendable {
        var messages: [Message] = []
        /// Why reading stopped; the first reason stays.
        var end: ClientError?
        /// After close or cancel: messages are dropped so the reader drains to EOF.
        var discarding = false
        var waiters: [UInt64: Waiter] = [:]
        var lastWaiterId: UInt64 = 0
        /// The reader, parked while the buffer is full.
        var reader: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isEnded: Bool { state.withLock { $0.end != nil } }

    // MARK: Reader side

    /// Adds a message; suspends while the buffer is full.
    func push(_ message: Message) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (waiters, parked) = state.withLock { state -> ([Waiter], Bool) in
                guard !state.discarding else { return ([], false) }
                state.messages.append(message)
                let waiters = Array(state.waiters.values)
                state.waiters = [:]
                let full = state.messages.count >= Self.capacity
                if full { state.reader = continuation }
                return (waiters, full)
            }
            Self.resume(waiters, ready: true)
            if !parked { continuation.resume() }
        }
    }

    /// Reading stopped (EOF, error, closed by this side).
    func finish(_ error: ClientError) {
        let waiters = state.withLock { state -> [Waiter] in
            if state.end == nil { state.end = error }
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        Self.resume(waiters, ready: true)
    }

    /// From now on messages are dropped: the reader keeps reading until the Mac closes, so
    /// nothing unread is left when this side closes (that would be a reset, which can lose the
    /// last message this side sent).
    func discard() {
        let reader = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.discarding = true
            state.messages = []
            defer { state.reader = nil }
            return state.reader
        }
        reader?.resume()
    }

    // MARK: Consumer side

    /// Suspends until a message or the end is there, at most `timeout`. False on timeout; true
    /// also when the calling task is cancelled.
    func wait(timeout: TimeInterval) async -> Bool {
        let id = state.withLock { state -> UInt64 in
            state.lastWaiterId += 1
            return state.lastWaiterId
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let ready = state.withLock { state -> Bool in
                    if !state.messages.isEmpty || state.end != nil || Task.isCancelled { return true }
                    // Armed under the lock: if it fires at once, `wake` waits for the waiter to be in place.
                    let deadline = WaitDeadline(after: timeout) { [weak self] in self?.wake(id, ready: false) }
                    state.waiters[id] = Waiter(continuation: continuation, deadline: deadline)
                    return false
                }
                if ready { continuation.resume(returning: true) }
            }
        } onCancel: {
            wake(id, ready: true)
        }
    }

    /// The next message if one is there, nil if not yet; throws once reading has stopped and
    /// every message was taken.
    func poll() throws(ClientError) -> Message? {
        let (message, end, reader) = state.withLock { state -> (Message?, ClientError?, CheckedContinuation<Void, Never>?) in
            guard !state.messages.isEmpty else { return (nil, state.end, nil) }
            let message = state.messages.removeFirst()
            defer { state.reader = nil }
            return (message, nil, state.reader)
        }
        reader?.resume()
        if let message { return message }
        if let end { throw end }
        return nil
    }

    func next(timeout: TimeInterval, stage: String) async throws(ClientError) -> Message {
        guard await wait(timeout: timeout) else { throw .timeout(stage: stage) }
        guard let message = try poll() else { throw .cancelled }
        return message
    }

    private func wake(_ id: UInt64, ready: Bool) {
        let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
        Self.resume(waiter.map { [$0] } ?? [], ready: ready)
    }

    private static func resume(_ waiters: [Waiter], ready: Bool) {
        for waiter in waiters {
            waiter.deadline.cancel()
            waiter.continuation.resume(returning: ready)
        }
    }
}

/// A cancellable one-shot timer (like FrameConnection's private `Deadline`).
nonisolated final class WaitDeadline: @unchecked Sendable {
    // DispatchWorkItem.cancel() is thread-safe; the item is never mutated after init.
    private let item: DispatchWorkItem

    init(after interval: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        item = DispatchWorkItem(block: action)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval, execute: item)
    }

    func cancel() {
        item.cancel()
    }
}
