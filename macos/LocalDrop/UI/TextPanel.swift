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
        HStack(spacing: 12) {
            Image(systemName: link == nil ? "doc.on.clipboard" : "link")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(link == nil ? String(localized: "Text from \(peerName) copied") : String(localized: "Link from \(peerName) copied"))
                    .font(.headline)
                    .lineLimit(1)
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let link {
                Button("Open") {
                    NSWorkspace.shared.open(link)
                    dismiss()
                }
                .glassButton()
            }
            CircleButton(symbol: "xmark", help: String(localized: "Close"), action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .panelCard(width: 360, cornerRadius: 22)
    }
}
