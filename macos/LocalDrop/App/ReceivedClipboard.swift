import AppKit
import UniformTypeIdentifiers

/// Received files go to the clipboard, like Copy in Finder: ⌘V pastes them into a chat, a mail
/// or a folder right away.
enum ReceivedClipboard {
    /// On unless turned off in Settings › General.
    static let enabledKey = "localdrop.copyReceived"
    /// A single image also goes as image data, for apps that take pictures but not files; up to
    /// this size, so a huge one doesn't sit in memory.
    private static let maxImageBytes = 50 * 1024 * 1024

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if urls.count == 1, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxImageBytes,
               let data = try? Data(contentsOf: url) {
                item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            }
            return item
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        Log.transfer.info("Copied \(urls.count) received file(s) to the clipboard")
    }
}
