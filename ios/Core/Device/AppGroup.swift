import Foundation

/// The container the app and the share extension share (`group.com.zepponapps.localdrop.ios`),
/// named by the `DewletAppGroup` Info.plist key of either bundle, like the Mac's `ShareInbox`.
nonisolated enum AppGroup {
    static var identifier: String? { Bundle.main.object(forInfoDictionaryKey: "DewletAppGroup") as? String }

    /// nil when the entitlement is missing (an unsigned build).
    static var container: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var defaults: UserDefaults {
        identifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
