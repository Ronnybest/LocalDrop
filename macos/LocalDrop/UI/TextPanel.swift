import AppKit
import SwiftUI

/// "Text copied" as a banner panel, for when notifications are off.
final class TextPanelController {
    private let panel = FloatingPanel()
    private var autoClose: Task<Void, Never>?

    private static let lifetime: Duration = .seconds(6)

    func show(text: String, link: URL?, peerName: String) {
        autoClose?.cancel()
        let view = TextReceivedView(
            preview: TextPreview.make(text),
            link: link,
            peerName: peerName,
            dismiss: { [weak self] in self?.close() }
        )
        panel.show(title: "LocalDrop", style: .banner, content: view) { [weak self] in self?.autoClose?.cancel() }
        autoClose = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.panel.close()
        }
    }

    func close() {
        autoClose?.cancel()
        panel.close()
    }
}

private struct TextReceivedView: View {
    let preview: String
    let link: URL?
    let peerName: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: link == nil ? "doc.on.clipboard.fill" : "link.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(link == nil ? String(localized: "Text from \(peerName) copied") : String(localized: "Link from \(peerName) copied"))
                    .font(.headline)
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                HStack {
                    Spacer()
                    if let link {
                        Button("Open Link") {
                            NSWorkspace.shared.open(link)
                            dismiss()
                        }
                    }
                    Button("Done", action: dismiss)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}
