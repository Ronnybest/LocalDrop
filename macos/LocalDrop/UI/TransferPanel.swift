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
    private var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []

    init(entryId: UUID, peerName: String, request: TransferRequest) {
        self.entryId = entryId
        self.peerName = peerName
        files = request.files
        totalSize = request.totalSize
        currentFile = request.files.first?.name ?? ""
    }

    var fraction: Double { totalSize > 0 ? min(1, Double(bytesReceived) / Double(totalSize)) : 1 }

    var title: String {
        files.count == 1 ? files[0].name : String(localized: "\(files.count) files")
    }

    /// Records progress and updates the speed over a sliding two-second window.
    func record(bytesReceived: Int64, currentFile: String) {
        let now = ContinuousClock.now
        self.bytesReceived = bytesReceived
        self.currentFile = currentFile
        samples.append((now, bytesReceived))
        samples.removeAll { now - $0.time > .seconds(2) }
        if let first = samples.first, first.time != now {
            let elapsed = now - first.time
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            bytesPerSecond = Double(bytesReceived - first.bytes) / seconds
        }
    }
}

/// Floating panel for an incoming transfer: request → progress → result.
final class TransferPanelController {
    private let panel = FloatingPanel()
    private var autoClose: Task<Void, Never>?

    func show(_ transfer: IncomingTransfer, decide: @escaping (Bool) -> Void, cancel: @escaping () -> Void, dismiss: @escaping () -> Void) {
        autoClose?.cancel()
        let view = TransferView(transfer: transfer, decide: decide, cancel: cancel, dismiss: dismiss)
        panel.show(title: "LocalDrop", style: .banner, content: view) {
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

private struct TransferView: View {
    let transfer: IncomingTransfer
    let decide: (Bool) -> Void
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(iconColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch transfer.phase {
        case .awaitingDecision:
            Text("\(transfer.peerName) wants to send")
                .font(.headline)
            fileSummary
            HStack {
                Spacer()
                Button("Decline") { decide(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { decide(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 2)

        case .receiving:
            Text("Receiving from \(transfer.peerName)")
                .font(.headline)
            Text(transfer.files.count == 1 ? transfer.files[0].name : transfer.currentFile)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: transfer.fraction)
            HStack {
                Text(progressLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel)
                    .controlSize(.small)
            }

        case .completed(let urls):
            Text(urls.count == 1 ? String(localized: "\(urls[0].lastPathComponent) received") : String(localized: "\(urls.count) files received"))
                .font(.headline)
                .lineLimit(2)
            Text("From \(transfer.peerName) · \(bytes(transfer.totalSize)) · integrity verified")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                    dismiss()
                }
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }

        case .failed(let reason), .cancelled(let reason):
            Text(reason)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var fileSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(transfer.files.prefix(3), id: \.fileId) { file in
                Text(file.name).lineLimit(1).truncationMode(.middle)
            }
            if transfer.files.count > 3 {
                Text("and \(transfer.files.count - 3) more").foregroundStyle(.secondary)
            }
            Text(bytes(transfer.totalSize))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var icon: String {
        switch transfer.phase {
        case .awaitingDecision, .receiving: "arrow.down.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch transfer.phase {
        case .awaitingDecision, .receiving: .accentColor
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    /// "42% · 120 MB of 284 MB · 12 MB/s"
    private var progressLine: String {
        let percent = Int(transfer.fraction * 100)
        var line = String(localized: "\(percent)% · \(bytes(transfer.bytesReceived)) of \(bytes(transfer.totalSize))")
        if transfer.bytesPerSecond > 0 {
            line += " · " + String(localized: "\(bytes(Int64(transfer.bytesPerSecond)))/s")
        }
        return line
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
