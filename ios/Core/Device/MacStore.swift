import Foundation
import notify
import os

/// Paired Macs, persisted as JSON in the App Group container
/// (`Library/Application Support/Dewlet/paired-macs.json`, excluded from backup, written
/// atomically). An unreadable file is moved aside and the store starts empty: the user pairs
/// again, and no Mac is ever trusted by accident.
///
/// Thread-safe, so sessions update it from any task. The app and the share extension each have
/// one: every change re-reads the file first and posts a Darwin notification the other reloads on.
nonisolated final class MacStore: Sendable {
    static let shared = MacStore(fileURL: defaultLocation())

    private struct State {
        /// Newest `lastSeen` first.
        var macs: [PairedMac]
        var observers: [UUID: AsyncStream<[PairedMac]>.Continuation] = [:]
    }

    private static let changeNotification = "com.zepponapps.localdrop.ios.paired-macs"
    private let fileURL: URL
    private let state: OSAllocatedUnfairLock<State>
    private let notifyToken = OSAllocatedUnfairLock<Int32?>(initialState: nil)

    init(fileURL: URL) {
        self.fileURL = fileURL
        state = OSAllocatedUnfairLock(initialState: State(macs: (try? Self.read(fileURL)) ?? []))
        var token: Int32 = 0
        let status = notify_register_dispatch(Self.changeNotification, &token, .global(qos: .utility)) { [weak self] _ in
            self?.reload()
        }
        let registered = token
        if status == NOTIFY_STATUS_OK { notifyToken.withLock { $0 = registered } }
    }

    deinit {
        if let token = notifyToken.withLock({ $0 }) { notify_cancel(token) }
    }

    /// The App Group container, or this app's own Application Support if the group is unavailable.
    private static func defaultLocation() -> URL {
        let support = AppGroup.container?.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            ?? URL.applicationSupportDirectory
        return support.appending(path: "Dewlet", directoryHint: .isDirectory).appending(path: "paired-macs.json")
    }

    var macs: [PairedMac] { state.withLock { $0.macs } }

    func mac(_ id: String) -> PairedMac? {
        state.withLock { $0.macs.first { $0.id == id } }
    }

    /// After `pairing_result{accepted:true}`: replaces any record with the same id. Pairing again
    /// with the same key keeps the record's history and settings (Android `TrustedDeviceStore.trust`);
    /// a new key starts over.
    func trust(_ mac: PairedMac) throws {
        try update { macs in
            var record = mac
            if let previous = macs.first(where: { $0.id == mac.id && $0.publicKey == mac.publicKey }) {
                record.firstSeen = previous.firstSeen
                record.lastAddresses = previous.lastAddresses
                record.lastPort = previous.lastPort
                record.receiveAutomatically = previous.receiveAutomatically
                record.presenceKey = mac.presenceKey ?? previous.presenceKey
            }
            macs.removeAll { $0.id == mac.id }
            macs.append(record)
            return true
        }
        Log.app.info("Trusted \(mac.id, privacy: .public), fingerprint \(mac.fingerprint.fingerprintLogPrefix, privacy: .public)…")
    }

    /// What a trusted session learned: the Mac's name and caps now, the presence key it handed out
    /// (replaced only when one came), and where it answered.
    func noteSession(id: String, name: String, capabilities: [String], presenceKey: Data?, addresses: [String], port: UInt16) throws {
        try update { macs in
            guard let index = macs.firstIndex(where: { $0.id == id }) else { return false }
            macs[index].name = name
            macs[index].capabilities = capabilities
            if let presenceKey { macs[index].presenceKey = presenceKey }
            macs[index].lastSeen = Date()
            if !addresses.isEmpty {
                macs[index].lastAddresses = addresses
                macs[index].lastPort = port
            }
            return true
        }
    }

    func setReceiveAutomatically(_ on: Bool, id: String) throws {
        try update { macs in
            guard let index = macs.firstIndex(where: { $0.id == id }), macs[index].receiveAutomatically != on else { return false }
            macs[index].receiveAutomatically = on
            return true
        }
    }

    /// Removes the record on this iPhone only; the Mac isn't told (Android does the same).
    func forget(_ id: String) throws {
        try update { macs in
            let count = macs.count
            macs.removeAll { $0.id == id }
            return macs.count != count
        }
        Log.app.info("Forgot \(id, privacy: .public)")
    }

    /// The full list now and after every change.
    func changes() -> AsyncStream<[PairedMac]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [PairedMac].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { state in
            state.observers[id] = continuation
            continuation.yield(state.macs)
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Applies `change` to the list as it is on disk now (the other process may have written it).
    /// `change` returns false when there is nothing to save.
    private func update(_ change: (inout [PairedMac]) -> Bool) throws {
        try state.withLockUnchecked { state in
            var macs: [PairedMac]
            do {
                macs = try Self.read(fileURL)
            } catch {
                Log.app.error("Paired Macs unreadable, not changing them: \(String(describing: error), privacy: .public)")
                throw ClientError.storageFailed
            }
            guard change(&macs) else { return }
            macs.sort { $0.lastSeen > $1.lastSeen }
            do {
                try write(macs)
            } catch {
                Log.app.error("Could not save paired Macs: \(String(describing: error), privacy: .public)")
                throw ClientError.storageFailed
            }
            publish(macs, in: &state)
        }
        notify_post(Self.changeNotification)
    }

    /// Read under the lock, so a reload never brings back a list older than one just written.
    private func reload() {
        state.withLockUnchecked { state in
            guard let macs = try? Self.read(fileURL), macs != state.macs else { return }
            publish(macs, in: &state)
        }
    }

    private func publish(_ macs: [PairedMac], in state: inout State) {
        state.macs = macs
        for observer in state.observers.values { observer.yield(macs) }
    }

    /// The stored list; empty when there is no file. A file that doesn't decode is moved aside;
    /// one that can't be read (data protection before the first unlock) throws.
    private static func read(_ url: URL) throws -> [PairedMac] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode([PairedMac].self, from: data).sorted { $0.lastSeen > $1.lastSeen }
        } catch {
            Log.app.fault("Paired Macs file corrupt, moving aside: \(String(describing: error), privacy: .public)")
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))"))
            return []
        }
    }

    private func write(_ macs: [PairedMac]) throws {
        var directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Trust is per device: never restored to another iPhone, where the keys are different.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
        try Self.encoder.encode(macs).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
