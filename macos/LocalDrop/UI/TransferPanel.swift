import AppKit
import SwiftUI

/// One incoming transfer, from the request prompt to the final result.
@Observable
final class IncomingTransfer {
    enum Phase: Equatable {
        case awaitingDecision
        case receiving
        case completed([URL])
        case failed(String)
        case cancelled(String)

        var isFinished: Bool {
            switch self {
            case .awaitingDecision, .receiving: false
            case .completed, .failed, .cancelled: true
            }
        }
    }

    let entryId: UUID
    let peerName: String
    /// Grow while the request is on screen (`transfer_add`).
    var files: [TransferFileInfo]
    var totalSize: Int64
    var phase: Phase = .awaitingDecision
    var bytesReceived: Int64 = 0
    var currentFile: String
    private(set) var bytesPerSecond: Double = 0
    /// Over the last 10 seconds, for the time left: steadier than [bytesPerSecond].
    private(set) var averageBytesPerSecond: Double = 0
    private var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []

    init(entryId: UUID, peerName: String, request: TransferRequest) {
        self.entryId = entryId
        self.peerName = peerName
        files = request.files
        totalSize = request.totalSize
        currentFile = request.files.first?.name ?? ""
    }

    var fraction: Double { totalSize > 0 ? min(1, Double(bytesReceived) / Double(totalSize)) : 1 }

    var timeLeft: String? { TimeLeft.text(remainingBytes: totalSize - bytesReceived, bytesPerSecond: averageBytesPerSecond) }

    var title: String {
        files.count == 1 ? files[0].name : String(localized: "\(files.count) files")
    }

    /// Bytes per second from the oldest sample since [start] to the newest.
    private static func rate(_ samples: [(time: ContinuousClock.Instant, bytes: Int64)], since start: ContinuousClock.Instant) -> Double {
        guard let first = samples.first(where: { $0.time >= start }), let last = samples.last, last.time > first.time else { return 0 }
        let elapsed = last.time - first.time
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Double(last.bytes - first.bytes) / seconds
    }

    /// Records progress: speed over the last 2 seconds, and over 10 for the time left.
    func record(bytesReceived: Int64, currentFile: String) {
        let now = ContinuousClock.now
        self.bytesReceived = bytesReceived
        self.currentFile = currentFile
        samples.append((now, bytesReceived))
        samples.removeAll { now - $0.time > .seconds(10) }
        bytesPerSecond = Self.rate(samples, since: now - .seconds(2))
        averageBytesPerSecond = Self.rate(samples, since: now - .seconds(10))
    }
}

/// Floating panel for an incoming transfer: request → progress → result.
final class TransferPanelController {
    private let panel = FloatingPanel()
    private var autoClose: Task<Void, Never>?

    func show(_ transfer: IncomingTransfer, decide: @escaping (Bool) -> Void, cancel: @escaping () -> Void, dismiss: @escaping () -> Void) {
        autoClose?.cancel()
        let view = TransferView(transfer: transfer, decide: decide, cancel: cancel, dismiss: dismiss)
        panel.show(title: "Local Drop", style: .banner, content: view) {
            switch transfer.phase {
            case .awaitingDecision: decide(false)
            case .receiving: cancel()
            case .completed, .failed, .cancelled: dismiss()
            }
        }
    }

    /// Keeps a finished transfer visible for a moment, like a notification, then closes.
    func closeAfterDelay(_ delay: Duration, then: @escaping () -> Void) {
        autoClose?.cancel()
        autoClose = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.panel.close()
            then()
        }
    }

    func close() {
        autoClose?.cancel()
        panel.close()
    }

    var isVisible: Bool { panel.isVisible }
}

/// One compact line, like a system notification: icon, what's happening, actions on the right.
/// While receiving, a thin progress bar runs along the bottom edge.
private struct TransferView: View {
    let transfer: IncomingTransfer
    let decide: (Bool) -> Void
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                actions
            }
            if transfer.phase == .receiving {
                VStack(spacing: 4) {
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    // Pinned to both edges, so changing numbers don't move the rest.
                    HStack {
                        Text(transfer.timeLeft ?? " ")
                        Spacer(minLength: 8)
                        Text("\(Int(transfer.fraction * 100))%")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .panelCard(width: 360, cornerRadius: 22)
    }

    @ViewBuilder
    private var actions: some View {
        switch transfer.phase {
        case .awaitingDecision:
            HStack(spacing: 8) {
                CircleButton(symbol: "xmark", help: String(localized: "Decline")) { decide(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { decide(true) }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
            }
        case .receiving:
            CircleButton(symbol: "xmark", help: String(localized: "Cancel"), action: cancel)
        case .completed(let urls):
            HStack(spacing: 8) {
                Button("Show") {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                    dismiss()
                }
                .glassButton()
                CircleButton(symbol: "xmark", help: String(localized: "Close"), action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        case .failed, .cancelled:
            CircleButton(symbol: "xmark", help: String(localized: "Close"), action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var title: String {
        switch transfer.phase {
        case .awaitingDecision: transfer.peerName
        case .receiving: transfer.title
        case .completed(let urls):
            urls.count == 1 ? String(localized: "\(urls[0].lastPathComponent) received") : String(localized: "\(urls.count) files received")
        case .failed(let reason), .cancelled(let reason): reason
        }
    }

    private var subtitle: String {
        switch transfer.phase {
        case .awaitingDecision:
            "\(transfer.title) · \(bytes(transfer.totalSize))"
        case .receiving:
            String(localized: "\(bytes(transfer.bytesReceived)) of \(bytes(transfer.totalSize))")
                + (transfer.bytesPerSecond > 0 ? " · " + String(localized: "\(bytes(Int64(transfer.bytesPerSecond)))/s") : "")
        case .completed:
            String(localized: "From \(transfer.peerName) · integrity verified")
        case .failed, .cancelled:
            transfer.title
        }
    }

    private var icon: String {
        switch transfer.phase {
        case .awaitingDecision, .receiving: "arrow.down.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch transfer.phase {
        case .awaitingDecision, .receiving: .accentColor
        case .completed: .green
        case .failed: .orange
        case .cancelled: .secondary
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
