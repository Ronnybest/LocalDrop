import Foundation
import os

/// Lets the app end a running session from outside, e.g. when the user removes the device from
/// trusted devices. The session reports `terminationReason` as its outcome.
nonisolated final class SessionHandle: Sendable {
    private struct State {
        var channel: SecureChannel?
        var terminationReason: SessionError?
    }

    private let frames: FrameConnection
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(frames: FrameConnection) {
        self.frames = frames
    }

    var terminationReason: SessionError? { state.withLock { $0.terminationReason } }

    func attach(_ channel: SecureChannel) {
        state.withLock { $0.channel = channel }
    }

    /// Tells the peer why (when the reason has a wire code and keys exist), then closes.
    func terminate(_ reason: SessionError) {
        let channel: SecureChannel? = state.withLock { state in
            guard state.terminationReason == nil else { return nil }
            state.terminationReason = reason
            return state.channel
        }
        guard terminationReason == reason else { return }
        Log.connection.info("Terminating session with \(self.frames.remoteDescription, privacy: .public): \(reason.description, privacy: .public)")
        Task { [frames] in
            if let channel, let code = reason.wireCode {
                try? await channel.send(ErrorMessage(code: code, detail: reason.description).message)
            }
            frames.cancel()
        }
    }
}
