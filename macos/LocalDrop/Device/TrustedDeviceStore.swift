import Foundation

/// A device paired by the user (protocol/security.md §6).
nonisolated struct TrustedDevice: Codable, Equatable, Identifiable, Sendable {
    let deviceId: String
    var deviceName: String
    /// `android`, `macos`, … Absent in records written before it was stored.
    var platform: String?
    /// Capabilities announced at the last session (protocol.md §2.6). Absent in older records.
    var capabilities: [String]?
    /// Identity public key, X9.63.
    let publicKey: Data
    let fingerprint: Data
    let firstSeen: Date
    var lastSeen: Date
    /// Absent until the user changes it: ask.
    var acceptPolicy: AcceptPolicy?

    var id: String { deviceId }
    var effectiveAcceptPolicy: AcceptPolicy { acceptPolicy ?? .ask }
}

nonisolated enum TrustState: Sendable {
    case unknown
    case trusted
    /// The deviceId is known with a different key. Never trusted silently.
    case keyChanged
}

/// Trusted devices persisted as JSON in Application Support (inside the sandbox container).
/// Public keys are not secret; only this Mac's private key is, and it stays in the Keychain.
@Observable
final class TrustedDeviceStore {
    private(set) var devices: [TrustedDevice] = [] {
        didSet { if devices != oldValue { onChange?() } }
    }
    /// Called after any change to `devices`.
    @ObservationIgnored var onChange: (() -> Void)?
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultLocation() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("LocalDrop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("trusted-devices.json")
    }

    /// Loads the store. An unreadable file is moved aside rather than silently overwritten:
    /// the user re-pairs, and nobody is ever trusted by accident.
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            devices = try Self.decoder.decode([TrustedDevice].self, from: data)
            Log.app.info("Loaded \(self.devices.count) trusted device(s)")
        } catch {
            Log.app.fault("Trusted devices file unreadable, moving aside: \(String(describing: error), privacy: .public)")
            let aside = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            devices = []
        }
    }

    func trustState(deviceId: String, identityKey: Data) -> TrustState {
        guard let device = devices.first(where: { $0.deviceId == deviceId }) else { return .unknown }
        return device.publicKey == identityKey ? .trusted : .keyChanged
    }

    /// Adds the peer, replacing any previous key for the same deviceId (after re-pairing).
    func trust(_ peer: PeerInfo) throws {
        let now = Date()
        var updated = devices
        // Re-pairing with the same key keeps the device's settings; a new key starts over at "ask".
        let previous = updated.first(where: { $0.deviceId == peer.deviceId && $0.publicKey == peer.identityKey })
        let firstSeen = previous?.firstSeen ?? now
        updated.removeAll { $0.deviceId == peer.deviceId }
        updated.append(TrustedDevice(
            deviceId: peer.deviceId,
            deviceName: peer.name,
            platform: peer.platform,
            capabilities: peer.capabilities,
            publicKey: peer.identityKey,
            fingerprint: peer.fingerprint,
            firstSeen: firstSeen,
            lastSeen: now,
            acceptPolicy: previous?.acceptPolicy
        ))
        try save(updated)
        devices = updated
        Log.app.info("Trusted \(peer.deviceId, privacy: .public), fingerprint \(peer.fingerprint.fingerprintLogPrefix, privacy: .public)…")
    }

    /// After a trusted session: the device's current name and what it can do now (it may have been updated).
    func markSeen(deviceId: String, name: String, capabilities: [String]) {
        guard let index = devices.firstIndex(where: { $0.deviceId == deviceId }) else { return }
        var updated = devices
        updated[index].lastSeen = Date()
        updated[index].deviceName = name
        updated[index].capabilities = capabilities
        do {
            try save(updated)
            devices = updated
        } catch {
            Log.app.error("Could not update lastSeen: \(String(describing: error), privacy: .public)")
        }
    }

    func setAcceptPolicy(_ policy: AcceptPolicy, deviceId: String) throws {
        guard let index = devices.firstIndex(where: { $0.deviceId == deviceId }) else { return }
        var updated = devices
        updated[index].acceptPolicy = policy
        try save(updated)
        devices = updated
        Log.app.info("Accept policy for \(deviceId, privacy: .public): \(policy.rawValue, privacy: .public)")
    }

    func forget(deviceId: String) throws {
        let updated = devices.filter { $0.deviceId != deviceId }
        try save(updated)
        devices = updated
        Log.app.info("Forgot trusted device \(deviceId, privacy: .public)")
    }

    private func save(_ devices: [TrustedDevice]) throws {
        try Self.encoder.encode(devices).write(to: fileURL, options: [.atomic])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
