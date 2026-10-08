import Foundation
import SystemConfiguration

/// Identity of this Mac as other LocalDrop devices see it.
nonisolated struct LocalDevice: Equatable, Sendable {
    /// Random UUID generated on first launch. Kept separate from the identity key so that
    /// a key change of a known device can be detected (protocol/security.md §2).
    let deviceId: String
    let name: String

    /// First characters of the deviceId, used in the BLE advertised name.
    var shortId: String {
        String(deviceId.replacingOccurrences(of: "-", with: "").prefix(ProtocolConstants.shortIdLength))
    }

    /// BLE local name in pairing mode.
    var pairingAdvertisedName: String { ProtocolConstants.pairingNamePrefix + shortId }

    private static let deviceIdKey = "localdrop.deviceId"

    static func loadOrCreate(defaults: UserDefaults = .standard) -> LocalDevice {
        let deviceId: String
        if let stored = defaults.string(forKey: deviceIdKey), UUID(uuidString: stored) != nil {
            deviceId = stored
        } else {
            deviceId = UUID().uuidString.lowercased()
            defaults.set(deviceId, forKey: deviceIdKey)
            Log.app.info("Generated new deviceId \(deviceId, privacy: .public)")
        }
        return LocalDevice(deviceId: deviceId, name: currentComputerName())
    }

    /// The user-visible computer name from System Settings › General › Sharing.
    static func currentComputerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.hostName
    }
}
