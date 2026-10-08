import AppKit

/// Whether "Share › LocalDrop" is on in Finder and other apps. macOS has the user turn share
/// extensions on themselves; the app can only check and open the right place in System Settings.
@Observable
final class ShareMenu {
    private(set) var isEnabled = false

    /// System Settings › General › Login Items & Extensions › Sharing.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.share-services")!

    func refresh() {
        // Share menus list only enabled extensions, so LocalDrop is in this list exactly when it's on.
        // Deprecated, but its replacement only builds a menu: nothing else tells which services exist.
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("Share menu probe.txt")
        if !FileManager.default.fileExists(atPath: probe.path) {
            try? Data().write(to: probe)
        }
        let enabled = NSSharingService.sharingServices(forItems: [probe]).contains { $0.title == "LocalDrop" }
        if enabled != isEnabled {
            Log.app.info("Share menu extension \(enabled ? "on" : "off", privacy: .public)")
            isEnabled = enabled
        }
    }
}
