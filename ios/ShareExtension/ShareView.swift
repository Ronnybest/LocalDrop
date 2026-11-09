import SwiftUI

/// The share sheet: what goes, to which Mac, and how it's going.
struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Group {
                if model.macs.isEmpty {
                    ContentUnavailableView {
                        Label("Add your Mac first", systemImage: "laptopcomputer")
                    } description: {
                        Text("Pair your Mac once in Dewlet. After that it appears right here when you share.")
                    }
                } else {
                    Form {
                        Section { summary }
                        Picker("Send to", selection: $model.selection) {
                            ForEach(model.macs) { mac in
                                Label(mac.name, systemImage: "laptopcomputer")
                                    .tag(Optional(mac.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .disabled(model.phase.isBusy)
                        if model.phase != .choosing {
                            Section { status }
                        }
                    }
                }
            }
            .navigationTitle("Dewlet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: model.cancel)
                        .disabled(model.phase == .cancelling)
                }
                if !model.macs.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send", action: model.send)
                            .disabled(model.selection == nil || model.loadFailure != nil || model.phase.isBusy)
                    }
                }
            }
        }
        .sensoryFeedback(trigger: model.phase) { _, phase in
            switch phase {
            case .sent: .success
            case .failed: .error
            default: nil
            }
        }
    }

    /// What was shared, once it is read.
    @ViewBuilder private var summary: some View {
        switch model.content {
        case .files(let items):
            LabeledContent {
                Text(items.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)))
            } label: {
                Label {
                    Text(items.count == 1 ? items[0].name : String(localized: "\(items.count) files"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: items.allSatisfy { $0.mimeType.hasPrefix("image/") || $0.mimeType.hasPrefix("video/") } ? "photo.on.rectangle" : "doc")
                }
            }
        case .text(let text, let isLink):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .lineLimit(4)
                    Group {
                        if isLink { Text("A link, to the Mac’s clipboard") } else { Text("Text, to the Mac’s clipboard") }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: isLink ? "link" : "text.quote")
            }
        case nil:
            if let failure = model.loadFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            } else {
                LabeledContent("Preparing…") { ProgressView() }
            }
        }
    }

    /// The transfer, from connecting to its result.
    @ViewBuilder private var status: some View {
        switch model.phase {
        case .choosing:
            EmptyView()
        case .preparing:
            LabeledContent("Preparing…") { ProgressView() }
        case .connecting(let macName):
            LabeledContent("Connecting to \(macName)…") { ProgressView() }
        case .sending(let progress, let macName):
            if let progress, progress.phase == .transferring {
                ProgressView(value: progress.fraction) {
                    Text(progress.fileCount > 1 ? String(localized: "\(progress.fileName) (\(progress.fileIndex + 1) of \(progress.fileCount))") : progress.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } currentValueLabel: {
                    let done = String(localized: "\(progress.bytesDone.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
                    let speed = progress.bytesPerSecond > 0 ? String(localized: "\(Int64(progress.bytesPerSecond).formatted(.byteCount(style: .file)))/s") : nil
                    let left = TimeLeft.text(remainingBytes: progress.totalBytes - progress.bytesDone, bytesPerSecond: progress.bytesPerSecond)
                    Text([done, speed, left].compactMap { $0 }.joined(separator: " · "))
                        .monospacedDigit()
                }
            } else if progress?.phase == .verifying {
                LabeledContent("Verifying…") { ProgressView() }
            } else if progress?.phase == .waitingForAcceptance {
                LabeledContent {
                    ProgressView()
                } label: {
                    Text("Waiting for \(macName)…")
                    Text("Accept the transfer on \(macName).")
                }
            } else {
                LabeledContent("Sending to \(macName)…") { ProgressView() }
            }
        case .cancelling:
            LabeledContent("Cancelling…") { ProgressView() }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        case .sent(let macName, let copied):
            Label {
                if copied {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copied to \(macName)")
                        Text("Paste it on the Mac with ⌘V.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Sent to \(macName)")
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.symbolEffect(.automatic))
            }
        }
    }
}
