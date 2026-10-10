import Foundation
import ServiceManagement

/// "Open at Login": Dewlet is most useful when it is always there to receive, but it opens at login
/// only once the user has said so.
@Observable
final class LoginItem {
    private(set) var isEnabled = false
    /// macOS may require the user to allow the item in System Settings › General › Login Items.
    private(set) var requiresApproval = false

    /// Whether the user has answered the menu's "Open at login?" yet. Never turned on without
    /// asking: the App Store doesn't allow launching at login without the user's consent.
    private(set) var hasAnswered = UserDefaults.standard.bool(forKey: answeredKey)
    private static let answeredKey = "localdrop.loginItemAnswered"

    /// The menu asks once, until the user turns it on or says no; Settings has the switch.
    var shouldSuggest: Bool { !hasAnswered && !isEnabled }

    func answer(enable: Bool) {
        UserDefaults.standard.set(true, forKey: Self.answeredKey)
        hasAnswered = true
        if enable { setEnabled(true) }
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
