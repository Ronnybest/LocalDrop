import Foundation
import UserNotifications

/// Results of incoming transfers ("received" with Show in Finder, failures) and received text
/// ("copied", with Open Link for a link) as system notifications.
/// Requests are a banner panel instead: notification action buttons stay hidden until hover.
/// Without notification permission, results stay in the panel.
@Observable
final class NotificationController: NSObject {
    enum Action {
        case showInFinder([URL])
        case openLink(URL)
    }

    @ObservationIgnored var onAction: ((Action) -> Void)?
    private(set) var isAuthorized = false

    @ObservationIgnored private let center = UNUserNotificationCenter.current()

    /// Opens LocalDrop's page in System Settings › Notifications.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.localdrop.mac")!

    private nonisolated enum Identifier {
        static let receivedCategory = "TRANSFER_RECEIVED"
        static let showInFinder = "SHOW_IN_FINDER"
        static let pathsKey = "paths"
        static let linkCategory = "TEXT_LINK"
        static let openLink = "OPEN_LINK"
        static let linkKey = "link"
    }

    func setUp() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Identifier.receivedCategory,
                actions: [UNNotificationAction(identifier: Identifier.showInFinder, title: String(localized: "Show in Finder"), options: [])],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Identifier.linkCategory,
                actions: [UNNotificationAction(identifier: Identifier.openLink, title: String(localized: "Open Link"), options: [])],
                intentIdentifiers: [],
                options: []
            ),
        ])
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                Log.app.info("Notifications authorized: \(granted, privacy: .public)")
            } catch {
                Log.app.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            await refreshAuthorization()
        }
    }

    /// The user can change this in System Settings at any time, so it is re-read before each
    /// incoming request, whenever the menu opens and when the app becomes active.
    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        let authorized = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            && settings.alertSetting == .enabled
        if authorized != isAuthorized {
            Log.app.info("Notifications \(authorized ? "enabled" : "disabled", privacy: .public)")
            isAuthorized = authorized
        }
    }

    /// - Parameter copied: the files are also on the clipboard (ReceivedClipboard).
    func postReceived(urls: [URL], peerName: String, size: String, copied: Bool) {
        let content = UNMutableNotificationContent()
        content.title = urls.count == 1 ? String(localized: "\(urls[0].lastPathComponent) received") : String(localized: "\(urls.count) files received")
        content.body = copied
            ? String(localized: "From \(peerName) · \(size) · copied, paste with ⌘V")
            : String(localized: "From \(peerName) · \(size) · integrity verified")
        content.categoryIdentifier = Identifier.receivedCategory
        content.userInfo = [Identifier.pathsKey: urls.map(\.path)]
        post(id: UUID().uuidString, content: content)
    }

    /// Text put on the clipboard. A link opens only when the user clicks the notification.
    func postText(_ text: String, link: URL?, peerName: String) {
        let content = UNMutableNotificationContent()
        content.title = link == nil ? String(localized: "Text from \(peerName) copied") : String(localized: "Link from \(peerName) copied")
        content.body = TextPreview.make(text)
        if let link {
            content.categoryIdentifier = Identifier.linkCategory
            content.userInfo = [Identifier.linkKey: link.absoluteString]
        }
        post(id: UUID().uuidString, content: content)
    }

    /// A plain notification: a result, a failure, a note.
    func postMessage(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        post(id: UUID().uuidString, content: content)
    }

    private func post(id: String, content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error {
                Log.app.error("Could not post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handle(actionIdentifier: String, paths: [String]?, link: String?) {
        let isDefault = actionIdentifier == UNNotificationDefaultActionIdentifier
        if let link = link.flatMap(URL.init(string:)), isDefault || actionIdentifier == Identifier.openLink {
            onAction?(.openLink(link))
        } else if let paths, isDefault || actionIdentifier == Identifier.showInFinder {
            onAction?(.showInFinder(paths.map { URL(fileURLWithPath: $0) }))
        }
    }
}

extension NotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A menu bar app is often "active"; banners must still appear.
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let paths = userInfo[Identifier.pathsKey] as? [String]
        let link = userInfo[Identifier.linkKey] as? String
        await handle(actionIdentifier: action, paths: paths, link: link)
    }
}

/// A short single-paragraph preview of received text for notifications and panels.
enum TextPreview {
    static func make(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
