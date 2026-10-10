import AppKit

/// Whether "Share › Local Drop" is on in Finder and other apps. macOS has the user turn share
/// extensions on themselves; the app can only check and open the right place in System Settings.
@Observable
final class ShareMenu {
    private(set) var isEnabled = false

    /// System Settings › General › Login Items & Extensions › Sharing.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.share-services")!

    func refresh() {
        // Share menus list only enabled extensions, so LocalDrop is in this list exactly when it's on.
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("Share menu probe.txt")
        if !FileManager.default.fileExists(atPath: probe.path) {
            try? Data().write(to: probe)
        }
        let lookup: any SharingServiceLookup = SystemSharingServices()
        let enabled = lookup.services(for: [probe]).contains { $0.title == "Local Drop" }
        if enabled != isEnabled {
            Log.app.info("Share menu extension \(enabled ? "on" : "off", privacy: .public)")
            isEnabled = enabled
        }
    }
}

/// `NSSharingService.sharingServices(forItems:)` is deprecated, but its replacement only builds a
/// menu: nothing else tells which share services are on. Called through a protocol, so using it
/// on purpose doesn't warn on every build.
private protocol SharingServiceLookup {
    func services(for items: [Any]) -> [NSSharingService]
}

private struct SystemSharingServices: SharingServiceLookup {
    @available(macOS, deprecated: 13.0)
    func services(for items: [Any]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: items)
    }
}
