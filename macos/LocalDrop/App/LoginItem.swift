import Foundation
import ServiceManagement

/// "Open at Login": LocalDrop is infrastructure and should be present without being launched.
@Observable
final class LoginItem {
    private(set) var isEnabled = false
    /// macOS may require the user to allow the item in System Settings › General › Login Items.
    private(set) var requiresApproval = false

    private static let configuredKey = "localdrop.loginItemConfigured"

    /// Enables launch at login on first run; afterwards the user's choice is kept.
    func configureOnFirstLaunch() {
        if !UserDefaults.standard.bool(forKey: Self.configuredKey) {
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
            setEnabled(true)
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("Open at login \(enabled ? "enabled" : "disabled", privacy: .public)")
        } catch {
            Log.app.error("Could not change login item: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }
}
