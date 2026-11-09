import CryptoKit
import Foundation
import Security
import UIKit

/// This iPhone as Macs see it.
///
/// The deviceId and the identity key both live in the keychain, this-device-only: a reinstall
/// keeps both, so a Mac recognizes the iPhone and only asks to pair again (the paired-Mac file is
/// gone, so `client_auth` says `trusted:false`); a restore to another iPhone starts as a new
/// device. Never in backed-up UserDefaults: the same id with a new key would show as a changed key.
nonisolated struct Phone: Sendable {
    /// Lowercase UUID, as `client_hello.id` and the pending-delivery tag need it.
    let deviceId: String
    let identity: Identity

    private static let deviceIdItem = KeychainBlob(service: "dev.localdrop.identity", account: "device-id-v1", label: "Dewlet device ID")
    private static let nameKey = "deviceName"

    /// Keychain access can block, and fails before the first unlock after a restart: call it off
    /// the main actor.
    static func load() throws(ClientError) -> Phone {
        do {
            let identity = try IdentityStore.loadOrCreate()
            if let deviceId = try storedDeviceId() { return Phone(deviceId: deviceId, identity: identity) }
            let created = UUID().uuidString.lowercased()
            do {
                try deviceIdItem.add(Data(created.utf8))
                Log.app.info("Created deviceId \(created, privacy: .public)")
                return Phone(deviceId: created, identity: identity)
            } catch {
                // The share extension may have created it at the same moment.
                guard let deviceId = try storedDeviceId() else { throw error }
                return Phone(deviceId: deviceId, identity: identity)
            }
        } catch {
            Log.crypto.error("Identity unavailable: \(String(describing: error), privacy: .public)")
            throw .identityUnavailable
        }
    }

    private static func storedDeviceId() throws(IdentityStoreError) -> String? {
        guard let data = try deviceIdItem.read(), let text = String(data: data, encoding: .utf8),
              UUID(uuidString: text) != nil else { return nil }
        return text.lowercased()
    }

    /// Name shown on the Mac, kept in the App Group defaults so the share extension sends the same.
    /// Defaults to `UIDevice.current.name`, which is a generic "iPhone" since iOS 16: the user can
    /// change it in Settings. Sessions trim it to what `client_hello` allows.
    @MainActor static var name: String {
        get {
            let stored = AppGroup.defaults.string(forKey: nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? UIDevice.current.name : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == UIDevice.current.name {
                AppGroup.defaults.removeObject(forKey: nameKey)
            } else {
                AppGroup.defaults.set(trimmed, forKey: nameKey)
            }
        }
    }
}
