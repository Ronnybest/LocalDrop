import AppKit
import CoreBluetooth
import Foundation
import Network

/// Owns the long-lived services of the menu bar app and exposes their state to SwiftUI.
@Observable
final class AppModel {
    enum StartupState: Equatable {
        /// Reading the identity key. Can block on a system Keychain access prompt.
        case loadingIdentity
        case running
        case failed(reason: String)
    }

    private(set) var localDevice: LocalDevice
    private(set) var fingerprint: Data?
    /// This Mac's identity key, for the pair verification code shown with each device.
    private(set) var identityPublicKey: Data?
    private(set) var startupState: StartupState = .loadingIdentity
    private(set) var lanAddresses: [String] = []
    /// Shown as a hint: on 2.4 GHz, transfers crawl at a few MB/s.
    private(set) var wifiBand: WiFiBand?
    /// Devices connected over TCP, newest first. Ended sessions linger briefly so the user sees why.
    private(set) var connections: [ConnectionEntry] = []
    private(set) var trustStore: TrustedDeviceStore?
    private(set) var trustStoreError: String?

    let listener: TCPListener
    private(set) var advertiser: BLEAdvertiser?

    private var identity: Identity?
    private var presenceKey: PresenceKey?
    private let pathMonitor = NWPathMonitor()

    /// While set and in the future, new devices can find and pair with this Mac.
    private(set) var pairingWindowUntil: Date?
    static let pairingWindowDuration: TimeInterval = 10 * 60
    private var presenceTask: Task<Void, Never>?
    /// Lets the app end live sessions (trust revoked, superseded pairing).
    private var sessionHandles: [UUID: SessionHandle] = [:]
    /// Held for the app's lifetime; see `start()`.
    private var presenceActivity: NSObjectProtocol?

    // Pairing: at most one at a time (protocol/security.md §5).
    private var pairingPrompt: PairingPrompt?
    private var pairingDecision: Bool?
    private var pairingContinuation: CheckedContinuation<Bool, Never>?
    private var pairingAttempts: [ContinuousClock.Instant] = []
    private let pairingPanel = PairingPanelController()

    // Incoming transfer: at most one at a time.
    private(set) var incomingTransfer: IncomingTransfer?
    private var transferDecision: TransferDecision?
    private var transferContinuation: CheckedContinuation<TransferDecision, Never>?
    private var transferCancel: (@Sendable () -> Void)?
    private let transferPanel = TransferPanelController()
    private let textPanel = TextPanelController()

    /// Files on their way to phones (Mac → Android, protocol.md §2.8).
    private(set) var deliveries: [OutgoingDelivery] = [] {
        didSet {
            releaseSharedFiles()
            saveDeliveries()
        }
    }
    /// The queue on disk, so it survives restarts; nil until restored at launch.
    @ObservationIgnored private var deliveryStore: DeliveryStore?
    /// Restored files whose security scope stays open while a delivery holds them.
    @ObservationIgnored private var scopedFiles: Set<URL> = []
    /// Directories of copies made for sending — Share extension inbox entries, folder archives,
    /// photos dropped from Photos — removed once no delivery holds their files any more.
    @ObservationIgnored private var sharedDirectories: Set<URL> = []
    /// Directories of folders being zipped: kept until their archives are queued.
    @ObservationIgnored private var zipping: [URL: Int] = [:]
    /// Folders being packed before they are queued.
    private(set) var packings: [FolderPacking] = []
    @ObservationIgnored private var publishedPhones: [ShareInbox.Phone]?
    let notifications = NotificationController()
    /// Which Settings tab to show; the menu opens Devices directly.
    var settingsTab: SettingsTab = .general
    let saveFolder = SaveFolder()
    let shareMenu = ShareMenu()
    let loginItem = LoginItem()

    private static let maxActiveSessions = 4
    private static let maxPairingAttemptsPerMinute = 5
    private static let endedEntryLifetime: Duration = .seconds(10)

    init() {
        let device = LocalDevice.loadOrCreate()
        localDevice = device
        listener = TCPListener(bonjourName: device.deviceId)
    }

    func start() {
        Log.app.info("Starting LocalDrop, deviceId \(self.localDevice.deviceId, privacy: .public)")
        startupState = .loadingIdentity

        // A windowless agent goes into App Nap when idle, and macOS then treats its Bluetooth
        // peripheral session as inactive: advertising continues but GATT reads are refused, so
        // phones see the Mac yet can't connect. Opting out of App Nap keeps it answerable;
        // idle system sleep stays allowed.
        presenceActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Answering nearby devices over Bluetooth and the local network"
        )

        // A sleeping Mac can keep advertising for a while; phones must not see it as nearby.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.discovery.info("System going to sleep: stopping BLE advertising")
                // Dark wakes in between run this process without a did-wake.
                SystemSleep.isAsleep = true
                self.advertiser?.stop()
                // A request on screen can't be answered any more; the sender retries after wake.
                if let transfer = self.incomingTransfer, transfer.phase == .awaitingDecision {
                    self.resolveTransfer(transfer.entryId, decision: .unattended)
                }
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                SystemSleep.isAsleep = false
                self.refreshAddresses()
                guard self.listener.port != nil else { return }
                Log.discovery.info("System woke: resuming BLE advertising")
                self.advertiser?.start()
            }
        }
        // Only did-wake ends sleep. The displays alone also light up for a notification in the
        // middle of the night, and no will-sleep follows that: taken as a wake, it left the app
        // reading the network in every dark wake until morning.

        notifications.onAction = { [weak self] action in self?.handle(action) }
        notifications.setUp()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.notifications.refreshAuthorization() }
            }
        }
        loginItem.configureOnFirstLaunch()

        do {
            let store = TrustedDeviceStore(fileURL: try TrustedDeviceStore.defaultLocation())
            store.load()
            trustStore = store
            store.onChange = { [weak self] in self?.publishSharePhones() }
            publishSharePhones()
            restoreDeliveries(directory: try TrustedDeviceStore.defaultLocation().deletingLastPathComponent())
            listenForShares()
            // The first check is the slow one (~90 ms); not when the menu opens.
            shareMenu.refresh()
        } catch {
            // Without a store nothing can be trusted or paired; sessions still authenticate.
            Log.app.fault("Trusted devices store unavailable: \(String(describing: error), privacy: .public)")
            trustStoreError = error.localizedDescription
        }

        // No transfer can be running yet, so any partial files are leftovers from a crash.
        Task.detached { IncomingFileWriter.removeLeftovers(in: ReceiveLocation.downloads) }
        saveFolder.load()

        // Keychain reads may wait for the user to answer a system prompt; keep the UI responsive.
        Task.detached {
            let result = Result { () throws(IdentityStoreError) -> (Identity, PresenceKey) in
                (try IdentityStore.loadOrCreate(), try PresenceKey.loadOrCreate())
            }
            await MainActor.run { self.finishStart(with: result) }
        }
    }

    /// Removes the device from trusted devices and immediately ends any session with it:
    /// revoking trust must also revoke access that is already in progress. The presence key is
    /// rotated so the forgotten device can no longer recognize this Mac over Bluetooth.
    func forgetTrustedDevice(_ deviceId: String) {
        do {
            try trustStore?.forget(deviceId: deviceId)
        } catch {
            Log.app.error("Could not forget \(deviceId, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        for entry in connections where !entry.state.isEnded && entry.state.peer?.deviceId == deviceId {
            sessionHandles[entry.id]?.terminate(.trustRevoked)
        }
        do {
            presenceKey = try PresenceKey.rotate()
        } catch {
            Log.crypto.error("Could not rotate presence key: \(error.description, privacy: .public)")
        }
        advertiser?.refresh()
    }

    // MARK: - Sending to phones

    /// One pending-delivery UUID per phone with files waiting, addressed to it (protocol.md §2.8).
    private func pendingDeliveryUUIDs() -> [CBUUID] {
        guard let presenceKey else { return [] }
        let slot = PresenceKey.slot(at: Date())
        var phones: [String] = []
        for delivery in deliveries where delivery.phase == .waiting && !phones.contains(delivery.deviceId) {
            phones.append(delivery.deviceId)
        }
        return phones.map { ProtocolConstants.pendingDeliveryUUID(tag: presenceKey.pendingTag(deviceId: $0, slot: slot)) }
    }

    func delivery(for deviceId: String) -> OutgoingDelivery? {
        deliveries.first { $0.deviceId == deviceId }
    }

    /// Queues files for a paired phone. They go when the phone connects, which it does on its
    /// own when it sees the pending delivery advertised; files added meanwhile join the same request.
    func send(_ urls: [URL], to deviceId: String) {
        let folders = urls.filter(Self.isFolder)
        if !folders.isEmpty { sendFolders(folders, to: deviceId) }
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        guard !files.isEmpty, let record = trustStore?.devices.first(where: { $0.deviceId == deviceId }) else { return }
        if let waiting = deliveries.first(where: { $0.deviceId == deviceId && $0.phase == .waiting && $0.text == nil }) {
            waiting.add(files)
            saveDeliveries()
        } else {
            deliveries.append(OutgoingDelivery(deviceId: deviceId, deviceName: record.deviceName, files: files))
        }
        Log.transfer.info("Queued \(files.count) file(s) for \(deviceId, privacy: .public)")
        advertiser?.refresh()
    }

    /// A folder, or a package such as an .app: both go zipped.
    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Folders go as zip archives (see `FolderArchive`), kept in a staging folder removed once
    /// they are sent. Packing shows in the menu and can be cancelled there.
    private func sendFolders(_ folders: [URL], to deviceId: String) {
        Log.transfer.info("Packing \(folders.count) folder(s) to send")
        let packing = FolderPacking(deviceId: deviceId, folders: folders)
        packings.append(packing)
        let parents = folders.map { $0.deletingLastPathComponent().standardizedFileURL }
        parents.forEach { zipping[$0, default: 0] += 1 }
        let cancel = packing.cancelToken
        Task.detached {
            let started = Date()
            var archives: [URL] = []
            var skipped: [String] = []
            var directory: URL?
            for (index, folder) in folders.enumerated() where !cancel.isCancelled {
                do {
                    let staging = try directory ?? Self.makeStagingDirectory()
                    directory = staging
                    let packed = try FolderArchive.pack(folder, into: staging, cancel: cancel) { fraction in
                        let overall = (Double(index) + fraction) / Double(folders.count)
                        Task { @MainActor in packing.fraction = overall }
                    }
                    archives.append(packed.archive)
                    skipped += packed.skipped
                } catch FolderArchive.PackError.cancelled {
                    break
                } catch {
                    Log.transfer.error("Could not pack \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            Log.transfer.info("Packed \(archives.count) archive(s) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
            if !skipped.isEmpty {
                Log.transfer.warning("Left \(skipped.count) unreadable file(s) out of the archive")
            }
            await MainActor.run {
                self.packings.removeAll { $0 === packing }
                for parent in parents {
                    self.zipping[parent, default: 1] -= 1
                    if self.zipping[parent] == 0 { self.zipping[parent] = nil }
                }
                guard let directory else { return }
                if cancel.isCancelled {
                    Log.transfer.info("Cancelled packing")
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                if !skipped.isEmpty {
                    let names = skipped.prefix(3).joined(separator: ", ") + (skipped.count > 3 ? "…" : "")
                    self.notifications.postMessage(
                        title: String(localized: "\(skipped.count) files left out of the archive"),
                        body: String(localized: "macOS doesn't let Local Drop read them: \(names)")
                    )
                }
                if archives.isEmpty {
                    try? FileManager.default.removeItem(at: directory)
                    self.notifications.postMessage(
                        title: String(localized: "Couldn't send \(packing.title)"),
                        body: String(localized: "Local Drop couldn't pack the folder.")
                    )
                } else {
                    self.sendStaged(archives, in: directory, to: deviceId)
                }
            }
        }
    }

    /// Sends files made for sending (folder archives, photos dropped from Photos); their
    /// directory is removed once no delivery holds them.
    func sendStaged(_ files: [URL], in directory: URL, to deviceId: String) {
        sharedDirectories.insert(directory)
        send(files, to: deviceId)
        releaseSharedFiles()
    }

    /// A new folder in Application Support for files made for sending.
    nonisolated static func makeStagingDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("LocalDrop/Outgoing/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Text or a link for the phone's clipboard. A phone without `clipboardReceive` gets it as a
    /// .txt file, as does text too long for one message (messages.md `text`).
    func sendText(_ text: String, to deviceId: String) {
        guard !text.isEmpty, let record = trustStore?.devices.first(where: { $0.deviceId == deviceId }) else { return }
        let toClipboard = record.capabilities?.contains(ProtocolConstants.clipboardReceiveCapability) == true
        guard toClipboard, text.utf8.count <= ProtocolConstants.maxTextSize else {
            sendTextAsFile(text, to: deviceId)
            return
        }
        deliveries.append(OutgoingDelivery(deviceId: deviceId, deviceName: record.deviceName, text: text))
        Log.transfer.info("Queued text for \(deviceId, privacy: .public)")
        advertiser?.refresh()
    }

    private func sendTextAsFile(_ text: String, to deviceId: String) {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("LocalDrop/Text", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let file = directory.appendingPathComponent("Text \(stamp).txt")
            try Data(text.utf8).write(to: file)
            send([file], to: deviceId)
        } catch {
            Log.transfer.error("Could not save text to send: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends what is on the clipboard: text or a link, or copied files.
    func sendClipboard(to deviceId: String) {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types?.map(\.rawValue) ?? []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            send(urls, to: deviceId)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            sendText(text, to: deviceId)
        } else {
            Log.transfer.warning("Nothing to send on the clipboard; types \(types.description, privacy: .public)")
            notifications.postMessage(
                title: String(localized: "Nothing to send"),
                body: String(localized: "Copy text, a link or files first.")
            )
        }
    }

    /// Lets the user pick files for a phone. The menu bar app has no window, so the panel comes forward itself.
    func chooseFiles(for deviceId: String) {
        // After the menu (and a context menu in it) has closed: opened from inside, the panel
        // ended up behind other apps' windows, since activation is only a request since macOS 14.
        DispatchQueue.main.async { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = String(localized: "Send")
            panel.level = .floating
            NSApp.activate()
            panel.begin { response in
                guard response == .OK else { return }
                let urls = panel.urls
                MainActor.assumeIsolated { self?.send(urls, to: deviceId) }
            }
            panel.orderFrontRegardless()
        }
    }

    func cancelDelivery(_ id: UUID) {
        if let packing = packings.first(where: { $0.id == id }) {
            packing.cancelToken.cancel()
            return
        }
        guard let delivery = deliveries.first(where: { $0.id == id }) else { return }
        if delivery.phase == .waiting {
            deliveries.removeAll { $0.id == id }
            Log.transfer.info("Cancelled a waiting delivery")
            advertiser?.refresh()
        } else {
            // The sender stops at its next chunk and reports `.cancelled`.
            delivery.cancelToken.cancel()
        }
    }

    // MARK: - Delivery queue on disk

    private func restoreDeliveries(directory: URL) {
        var store = DeliveryStore(directory: directory)
        let restored = store.load().filter { delivery in trustStore?.devices.contains { $0.deviceId == delivery.deviceId } == true }
        deliveryStore = store
        guard !restored.isEmpty else { return }
        let staging = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?
            .appendingPathComponent("LocalDrop/Outgoing").standardizedFileURL.path
        let inbox = ShareInbox.inbox?.standardizedFileURL.path
        for delivery in restored {
            for file in delivery.files {
                scopedFiles.insert(file)
                // Files from the Share extension: their inbox directory is already taken.
                let directory = file.deletingLastPathComponent().standardizedFileURL
                if let inbox, directory.path.hasPrefix(inbox) { sharedDirectories.insert(directory) }
                if let staging, directory.path.hasPrefix(staging) { sharedDirectories.insert(directory) }
            }
        }
        deliveries = restored
        Log.transfer.info("Restored \(restored.count) waiting deliver(ies)")
        advertiser?.refresh()
    }

    private func saveDeliveries() {
        guard deliveryStore != nil else { return }
        deliveryStore?.save(deliveries)
        // A restored file's security scope closes once no delivery holds it.
        let inUse = Set(deliveries.flatMap(\.files))
        for file in scopedFiles where !inUse.contains(file) {
            file.stopAccessingSecurityScopedResource()
            scopedFiles.remove(file)
        }
    }

    // MARK: - Share extension

    /// Tells the Share extension which phones it can offer: paired phones that receive files.
    private func publishSharePhones() {
        let phones = (trustStore?.devices ?? [])
            .filter { $0.capabilities?.contains(ProtocolConstants.receiveCapability) == true }
            .map { ShareInbox.Phone(deviceId: $0.deviceId, name: $0.deviceName) }
        guard phones != publishedPhones else { return }
        publishedPhones = phones
        ShareInbox.publish(phones)
    }

    /// Shares arrive as a Darwin notification; ones made while LocalDrop wasn't running are
    /// waiting in the inbox and are picked up now.
    private func listenForShares() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                // AppModel lives as long as the app, so the unretained pointer stays valid.
                let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { model.takeShares() } }
            },
            ShareInbox.requestNotification as CFString,
            nil,
            .deliverImmediately
        )
        takeShares()
    }

    private func takeShares() {
        for (request, directory) in ShareInbox.pendingRequests() where !sharedDirectories.contains(directory) {
            if let text = request.text {
                Log.transfer.info("Share extension: text for \(request.deviceId, privacy: .public)")
                sendText(text, to: request.deviceId)
                try? FileManager.default.removeItem(at: directory)
                continue
            }
            let files = request.files.map { directory.appendingPathComponent($0) }
            guard trustStore?.devices.contains(where: { $0.deviceId == request.deviceId }) == true else {
                Log.transfer.warning("Dropping a share for a device that is no longer paired")
                try? FileManager.default.removeItem(at: directory)
                continue
            }
            Log.transfer.info("Share extension: \(files.count) file(s) for \(request.deviceId, privacy: .public)")
            sharedDirectories.insert(directory)
            send(files, to: request.deviceId)
            releaseSharedFiles()
        }
    }

    /// Deletes the copies made for shares once they are sent, declined or cancelled.
    private func releaseSharedFiles() {
        guard !sharedDirectories.isEmpty else { return }
        let inUse = Set(deliveries.flatMap(\.files).map { $0.deletingLastPathComponent().standardizedFileURL })
            .union(zipping.keys)
        for directory in sharedDirectories where !inUse.contains(directory.standardizedFileURL) {
            try? FileManager.default.removeItem(at: directory)
            sharedDirectories.remove(directory)
        }
    }

    // MARK: - Presence and pairing mode

    /// Pairing mode: opened for a while from the menu, and always on while nothing is paired.
    var isPairingModeActive: Bool {
        if trustStore?.devices.isEmpty ?? true { return true }
        guard let until = pairingWindowUntil else { return false }
        return until > Date()
    }

    func openPairingWindow() {
        pairingWindowUntil = Date().addingTimeInterval(Self.pairingWindowDuration)
        Log.app.info("Pairing mode opened for \(Int(Self.pairingWindowDuration / 60)) minutes")
        advertiser?.refresh()
        schedulePresenceRefresh()
    }

    func closePairingWindow() {
        guard pairingWindowUntil != nil else { return }
        pairingWindowUntil = nil
        Log.app.info("Pairing mode closed")
        advertiser?.refresh()
        schedulePresenceRefresh()
    }

    private func currentAdvertisedName() -> String {
        guard !isPairingModeActive, let presenceKey else { return localDevice.pairingAdvertisedName }
        let status: PresenceKey.Status = if isBusy {
            .busy
        } else if lanAddresses.isEmpty {
            .noNetwork
        } else {
            .available
        }
        return presenceKey.advertisedName(at: Date(), status: status)
    }

    private var isBusy: Bool {
        pairingPrompt != nil || (incomingTransfer.map { !$0.phase.isFinished } ?? false)
    }

    /// Network or busy state changed: phones read it from the advertisement within seconds.
    private func presenceChanged() {
        advertiser?.refresh()
    }

    /// Endpoint Info for the GATT read: open in pairing mode, sealed with the presence key otherwise.
    private func currentEndpointValue() -> Data? {
        guard let info = currentEndpointInfo() else { return nil }
        guard !isPairingModeActive, let presenceKey else { return info.encoded() }
        do {
            return try info.sealed(with: presenceKey)
        } catch {
            Log.crypto.error("Could not seal endpoint info: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Re-advertises at each token slot boundary and when the pairing window ends.
    private func schedulePresenceRefresh() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                var next = PresenceKey.nextSlotStart(after: now)
                if let until = self?.pairingWindowUntil, until > now { next = min(next, until) }
                try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 0.5))
                guard !Task.isCancelled, let self else { return }
                if let until = self.pairingWindowUntil, until <= Date() {
                    self.pairingWindowUntil = nil
                    Log.app.info("Pairing mode expired")
                }
                self.advertiser?.refresh()
            }
        }
    }

    /// Re-shows a pending pairing or transfer prompt, e.g. if its window was closed or hidden.
    func showPrompt(for entryId: UUID) {
        if let prompt = pairingPrompt, prompt.entryId == entryId {
            showPairingPanel(prompt)
        } else if let transfer = incomingTransfer, transfer.entryId == entryId, !transfer.phase.isFinished {
            showTransferPanel(transfer)
        }
    }

    /// A pairing or transfer window that can be brought back: the request, or the progress of a
    /// transfer (auto-accepted ones start without a window).
    func hasPendingPrompt(for entryId: UUID) -> Bool {
        pairingPrompt?.entryId == entryId
            || (incomingTransfer?.entryId == entryId && incomingTransfer?.phase.isFinished == false)
    }

    private func showPairingPanel(_ prompt: PairingPrompt) {
        let entryId = prompt.entryId
        pairingPanel.show(prompt) { [weak self] accepted in
            self?.resolvePairing(entryId, accepted: accepted)
        }
    }

    private func handle(_ action: NotificationController.Action) {
        switch action {
        case .showInFinder(let urls): NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .openLink(let url): NSWorkspace.shared.open(url)
        }
    }

    private func showTransferPanel(_ transfer: IncomingTransfer) {
        let entryId = transfer.entryId
        transferPanel.show(
            transfer,
            decide: { [weak self] accepted in self?.resolveTransfer(entryId, decision: accepted ? .accept : .decline) },
            cancel: { [weak self] in self?.cancelIncomingTransfer(entryId) },
            dismiss: { [weak self] in self?.dismissTransfer(entryId) }
        )
    }

    private func finishStart(with result: Result<(Identity, PresenceKey), IdentityStoreError>) {
        switch result {
        case .success(let (identity, presenceKey)):
            self.identity = identity
            self.presenceKey = presenceKey
            fingerprint = identity.fingerprint
            identityPublicKey = identity.publicKeyX963
            startupState = .running
            Log.crypto.info("Identity fingerprint \(identity.fingerprint.fingerprintLogPrefix, privacy: .public)…")
        case .failure(let error):
            Log.crypto.fault("Cannot load identity: \(error.description, privacy: .public)")
            startupState = .failed(reason: error.description)
            return
        }

        refreshAddresses()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAddresses() }
        }
        pathMonitor.start(queue: .main)

        let advertiser = BLEAdvertiser(
            nameProvider: { [weak self] in self?.currentAdvertisedName() ?? "" },
            endpointValueProvider: { [weak self] in self?.currentEndpointValue() },
            pendingProvider: { [weak self] in self?.pendingDeliveryUUIDs() ?? [] }
        )
        self.advertiser = advertiser
        schedulePresenceRefresh()

        listener.onConnection = { [weak self] connection in
            self?.accept(connection)
        }
        listener.onStateChange = { [weak advertiser] state in
            // Advertise only while the endpoint we publish over BLE is actually reachable.
            switch state {
            case .ready:
                advertiser?.start()
            case .failed, .stopped:
                advertiser?.stop()
            case .starting, .waiting:
                break
            }
        }
        listener.start()

        #if DEBUG
        // For development: `-LocalDropTestDeliveryFile <path in Downloads> -LocalDropTestDeliveryDevice <deviceId>`
        // queues a delivery at launch, so Mac → phone can be exercised without clicking. Several
        // files as a property list array: `-LocalDropTestDeliveryFile '("a.bin", "b.jpg")'`.
        let defaults = UserDefaults.standard
        if let paths = defaults.stringArray(forKey: "LocalDropTestDeliveryFile") ?? defaults.string(forKey: "LocalDropTestDeliveryFile").map({ [$0] }),
           let device = defaults.string(forKey: "LocalDropTestDeliveryDevice") {
            Log.transfer.info("Debug: queueing a test delivery")
            send(paths.map { URL(fileURLWithPath: $0) }, to: device)
        }
        // `-LocalDropTestDeliveryText <text> -LocalDropTestDeliveryDevice <deviceId>`: text for the phone's clipboard.
        if let text = UserDefaults.standard.string(forKey: "LocalDropTestDeliveryText"),
           let device = UserDefaults.standard.string(forKey: "LocalDropTestDeliveryDevice") {
            Log.transfer.info("Debug: queueing test text")
            sendText(text, to: device)
        }
        #endif
    }

    private func accept(_ socket: TCPSocket) {
        guard let identity else {
            socket.close()
            return
        }
        let active = connections.filter { !$0.state.isEnded }.count
        guard active < Self.maxActiveSessions else {
            Log.connection.warning("Rejecting \(socket.remoteAddress, privacy: .public): \(active) sessions active")
            Task.detached { await ServerSession.reject(socket, code: ErrorCode.busy) }
            return
        }

        refreshComputerName()
        let entry = ConnectionEntry(remote: socket.remoteHost)
        connections.insert(entry, at: 0)
        let session = ServerSession(
            entryId: entry.id,
            socket: socket,
            identity: identity,
            localDevice: localDevice,
            coordinator: self
        )
        sessionHandles[entry.id] = session.handle
        // Session I/O and crypto run off the main actor; only state updates hop back.
        Task.detached { await session.run() }
    }

    private func updateEntry(_ entryId: UUID, _ state: ConnectionEntry.State) {
        guard let index = connections.firstIndex(where: { $0.id == entryId }) else { return }
        connections[index].state = state
    }

    private func refreshAddresses() {
        // Dark wakes bring Wi-Fi up for a moment all night; nothing is served then (sessions
        // get `asleep`), so the next real wake reads the network instead.
        guard !SystemSleep.isAsleep else { return }
        let band = NetworkInterfaces.wifiBand()
        if band != wifiBand {
            Log.connection.info("Wi-Fi band: \(band.map { String(describing: $0) } ?? "none", privacy: .public)")
            wifiBand = band
        }
        let addresses = NetworkInterfaces.lanAddresses()
        if addresses != lanAddresses {
            Log.connection.info("LAN addresses: \(addresses.joined(separator: ", "), privacy: .public)")
            lanAddresses = addresses
            presenceChanged()
        }
        refreshComputerName()
    }

    /// The computer name can be changed in System Settings at any time; peers learn it on their
    /// next connection and update their share targets.
    private func refreshComputerName() {
        let currentName = LocalDevice.currentComputerName()
        if currentName != localDevice.name {
            Log.app.info("Computer name changed to \(currentName, privacy: .public)")
            localDevice = LocalDevice(deviceId: localDevice.deviceId, name: currentName)
        }
    }

    private func currentEndpointInfo() -> EndpointInfo? {
        guard let port = listener.port, let fingerprint else { return nil }
        refreshComputerName()
        return EndpointInfo(
            protocolVersion: ProtocolConstants.version,
            deviceId: localDevice.deviceId,
            deviceName: localDevice.name,
            platform: ProtocolConstants.platform,
            port: port,
            addresses: NetworkInterfaces.lanAddresses(),
            fingerprint: fingerprint,
            busy: isBusy,
            capabilities: ProtocolConstants.capabilities
        )
    }

    // MARK: - Pairing prompt

    private func resolvePairing(_ entryId: UUID, accepted: Bool) {
        guard pairingPrompt?.entryId == entryId else { return }
        if let continuation = pairingContinuation {
            pairingContinuation = nil
            continuation.resume(returning: accepted)
        } else {
            pairingDecision = accepted
        }
    }

    // MARK: - Incoming transfer

    private func resolveTransfer(_ entryId: UUID, decision: TransferDecision) {
        guard let transfer = incomingTransfer, transfer.entryId == entryId, transfer.phase == .awaitingDecision else { return }
        if decision == .accept { transfer.phase = .receiving }
        if let continuation = transferContinuation {
            transferContinuation = nil
            continuation.resume(returning: decision)
        } else {
            transferDecision = decision
        }
    }

    private func abandonTransferDecision(_ entryId: UUID) {
        guard incomingTransfer?.entryId == entryId else { return }
        transferContinuation?.resume(returning: .decline)
        transferContinuation = nil
    }

    private func cancelIncomingTransfer(_ entryId: UUID) {
        guard let transfer = incomingTransfer, transfer.entryId == entryId, !transfer.phase.isFinished else { return }
        Log.transfer.info("User cancelled the incoming transfer")
        transferCancel?()
        // The receiver confirms with transferFinished(.cancelled) at its next frame.
        transferPanel.close()
    }

    private func dismissTransfer(_ entryId: UUID) {
        guard let transfer = incomingTransfer, transfer.entryId == entryId else { return }
        transferPanel.close()
        if transfer.phase.isFinished { incomingTransfer = nil }
    }

    private func endPairing(_ entryId: UUID) {
        guard pairingPrompt?.entryId == entryId else { return }
        pairingContinuation?.resume(returning: false)
        pairingContinuation = nil
        pairingDecision = nil
        pairingPrompt = nil
        pairingPanel.close()
        presenceChanged()
    }
}

extension AppModel: SessionCoordinator {
    func trustState(deviceId: String, identityKey: Data) -> TrustState {
        trustStore?.trustState(deviceId: deviceId, identityKey: identityKey) ?? .unknown
    }

    func sessionAuthenticated(_ entryId: UUID, peer: PeerInfo, status: SessionStatus) {
        updateEntry(entryId, .connected(peer, status))
        if status == .trusted {
            trustStore?.markSeen(deviceId: peer.deviceId, name: peer.name, capabilities: peer.capabilities)
        }
    }

    func beginPairing(_ entryId: UUID, peer: PeerInfo, code: String, keyChanged: Bool) throws {
        guard trustStore != nil else { throw SessionError.storage(trustStoreError ?? "store unavailable") }
        if let current = pairingPrompt {
            guard current.peerDeviceId == peer.deviceId else {
                Log.handshake.warning("Pairing with \(peer.deviceId, privacy: .public) refused: another pairing in progress")
                throw SessionError.busy
            }
            // The same device is retrying; its previous attempt is stale.
            Log.handshake.info("Pairing with \(peer.deviceId, privacy: .public) supersedes its previous attempt")
            sessionHandles[current.entryId]?.terminate(.superseded)
            endPairing(current.entryId)
        }
        let now = ContinuousClock.now
        pairingAttempts.removeAll { now - $0 > .seconds(60) }
        guard pairingAttempts.count < Self.maxPairingAttemptsPerMinute else {
            Log.handshake.warning("Pairing with \(peer.deviceId, privacy: .public) refused: rate limit")
            throw SessionError.busy
        }
        pairingAttempts.append(now)

        let prompt = PairingPrompt(entryId: entryId, peerDeviceId: peer.deviceId, peerName: peer.name, code: code, keyChanged: keyChanged)
        pairingPrompt = prompt
        pairingDecision = nil
        updateEntry(entryId, .pairing(peer))
        showPairingPanel(prompt)
        presenceChanged()
    }

    func awaitPairingDecision(_ entryId: UUID) async -> Bool {
        guard pairingPrompt?.entryId == entryId else { return false }
        if let decision = pairingDecision { return decision }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pairingContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in self.endPairing(entryId) }
        }
    }

    func pairingSucceeded(_ entryId: UUID, peer: PeerInfo) throws {
        guard let trustStore else { throw SessionError.storage(trustStoreError ?? "store unavailable") }
        try trustStore.trust(peer)
        endPairing(entryId)
        // Paired: stop being discoverable to strangers.
        pairingWindowUntil = nil
        advertiser?.refresh()
        schedulePresenceRefresh()
        updateEntry(entryId, .connected(peer, .trusted))
    }

    func acceptPolicy(for peer: PeerInfo) -> AcceptPolicy {
        guard let record = trustStore?.devices.first(where: { $0.deviceId == peer.deviceId }),
              record.publicKey == peer.identityKey else { return .ask }
        return record.effectiveAcceptPolicy
    }

    func setAcceptPolicy(_ policy: AcceptPolicy, deviceId: String) {
        do {
            try trustStore?.setAcceptPolicy(policy, deviceId: deviceId)
        } catch {
            Log.app.error("Could not save accept policy: \(String(describing: error), privacy: .public)")
        }
    }

    func beginIncomingTransfer(_ entryId: UUID, peer: PeerInfo, request: TransferRequest, autoAccepted: Bool, cancel: @escaping @Sendable () -> Void) async throws {
        if let current = incomingTransfer, !current.phase.isFinished { throw SessionError.busy }
        transferPanel.close()
        let transfer = IncomingTransfer(entryId: entryId, peerName: peer.name, request: request)
        incomingTransfer = transfer
        transferCancel = cancel
        presenceChanged()
        Task { await notifications.refreshAuthorization() }
        if autoAccepted {
            // Nothing to decide: progress shows in the menu, the result as a notification.
            transfer.phase = .receiving
            transferDecision = .accept
            return
        }
        transferDecision = nil
        // The request is a banner with visible buttons (notification actions stay hidden until
        // hover); the result is a notification when allowed.
        showTransferPanel(transfer)
    }

    func textReceived(_ text: String, peer: PeerInfo) -> Bool {
        guard acceptPolicy(for: peer) != .never else { return false }
        let link = Self.link(in: text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let link { pasteboard.setString(link.absoluteString, forType: .URL) }
        if notifications.isAuthorized {
            notifications.postText(text, link: link, peerName: peer.name)
        } else {
            textPanel.show(text: text, link: link, peerName: peer.name)
        }
        return true
    }

    /// The text when it is exactly one web link. Links are opened only when the user clicks.
    private static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    func awaitTransferDecision(_ entryId: UUID) async -> TransferDecision {
        guard incomingTransfer?.entryId == entryId else { return .decline }
        if let decision = transferDecision { return decision }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                transferContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in self.abandonTransferDecision(entryId) }
        }
    }

    func transferRequestGrew(_ entryId: UUID, request: TransferRequest) {
        guard let transfer = incomingTransfer, transfer.entryId == entryId, transfer.phase == .awaitingDecision else { return }
        transfer.files = request.files
        transfer.totalSize = request.totalSize
    }

    func transferStarted(_ entryId: UUID) {
        guard let transfer = incomingTransfer, transfer.entryId == entryId else { return }
        transfer.phase = .receiving
    }

    func transferProgress(_ entryId: UUID, bytesReceived: Int64, currentFile: String) {
        guard let transfer = incomingTransfer, transfer.entryId == entryId else { return }
        transfer.record(bytesReceived: bytesReceived, currentFile: currentFile)
    }

    func transferFinished(_ entryId: UUID, outcome: TransferOutcome) {
        guard let transfer = incomingTransfer, transfer.entryId == entryId, !transfer.phase.isFinished else { return }
        transferContinuation?.resume(returning: .decline)
        transferContinuation = nil
        transferCancel = nil
        let wasReceiving = transfer.phase == .receiving
        // Phase changes below make the Mac available again.
        defer { presenceChanged() }
        if case .completed(let urls) = outcome, ReceivedClipboard.isEnabled {
            ReceivedClipboard.copy(urls)
        }

        if notifications.isAuthorized {
            transferPanel.close()
            reportByNotification(transfer, outcome: outcome, wasReceiving: wasReceiving)
            return
        }
        // An auto-accepted transfer had no panel; without notifications its result needs one.
        if !transferPanel.isVisible { showTransferPanel(transfer) }
        switch outcome {
        case .completed(let urls):
            transfer.phase = .completed(urls)
            transferPanel.closeAfterDelay(.seconds(8)) { [weak self] in self?.dismissTransfer(entryId) }
        case .declined, .cancelled, .unattended:
            transfer.phase = .cancelled(String(localized: "Cancelled"))
            dismissTransfer(entryId)
        case .timedOut:
            transfer.phase = .cancelled(String(localized: "The request from \(transfer.peerName) expired"))
            dismissTransfer(entryId)
        case .cancelledByPeer:
            transfer.phase = .cancelled(String(localized: "\(transfer.peerName) cancelled the transfer"))
            if !wasReceiving { dismissTransfer(entryId) }
        case .rejectedNoSpace:
            transfer.phase = .failed(String(localized: "Not enough disk space"))
        case .failed(let reason):
            transfer.phase = .failed(reason)
        }
    }

    /// Notification counterpart of the panel's final states; the transfer record is cleared at once.
    private func reportByNotification(_ transfer: IncomingTransfer, outcome: TransferOutcome, wasReceiving: Bool) {
        let size = ByteCountFormatter.string(fromByteCount: transfer.totalSize, countStyle: .file)
        switch outcome {
        case .completed(let urls):
            transfer.phase = .completed(urls)
            notifications.postReceived(urls: urls, peerName: transfer.peerName, size: size, copied: ReceivedClipboard.isEnabled)
        case .declined, .cancelled, .timedOut, .unattended:
            transfer.phase = .cancelled(String(localized: "Cancelled"))
        case .cancelledByPeer:
            transfer.phase = .cancelled(String(localized: "Cancelled"))
            if wasReceiving {
                notifications.postMessage(title: String(localized: "\(transfer.peerName) cancelled the transfer"), body: transfer.title)
            }
        case .rejectedNoSpace:
            transfer.phase = .failed(String(localized: "Not enough disk space"))
            notifications.postMessage(title: String(localized: "Couldn't receive from \(transfer.peerName)"), body: String(localized: "Not enough disk space"))
        case .failed(let reason):
            transfer.phase = .failed(reason)
            notifications.postMessage(title: String(localized: "Couldn't receive from \(transfer.peerName)"), body: reason)
        }
        dismissTransfer(transfer.entryId)
    }

    func transferRejectedForStorage(peer: PeerInfo, request: TransferRequest) {
        guard incomingTransfer == nil || incomingTransfer?.phase.isFinished == true else { return }
        let size = ByteCountFormatter.string(fromByteCount: request.totalSize, countStyle: .file)
        if notifications.isAuthorized {
            notifications.postMessage(
                title: String(localized: "Couldn't receive from \(peer.name)"),
                body: String(localized: "\(peer.name) tried to send \(size), but there isn't enough disk space")
            )
            return
        }
        let transfer = IncomingTransfer(entryId: UUID(), peerName: peer.name, request: request)
        transfer.phase = .failed(String(localized: "\(peer.name) tried to send \(size), but there isn't enough disk space"))
        incomingTransfer = transfer
        transferPanel.show(transfer, decide: { _ in }, cancel: {}, dismiss: { [weak self] in self?.dismissTransfer(transfer.entryId) })
    }

    func isPairingAllowed() -> Bool { isPairingModeActive }

    func takeDelivery(for peer: PeerInfo) -> PendingDelivery? {
        guard trustState(deviceId: peer.deviceId, identityKey: peer.identityKey) == .trusted,
              let delivery = deliveries.first(where: { $0.deviceId == peer.deviceId && $0.phase == .waiting }) else { return nil }
        delivery.phase = .awaitingAcceptance
        delivery.record(bytesSent: 0)
        advertiser?.refresh()
        return PendingDelivery(id: delivery.id, files: delivery.files, text: delivery.text, token: delivery.cancelToken)
    }

    func deliveryStarted(_ id: UUID) {
        deliveries.first { $0.id == id }?.phase = .sending
    }

    func deliveryProgress(_ id: UUID, bytesSent: Int64) {
        deliveries.first { $0.id == id }?.record(bytesSent: bytesSent)
    }

    func deliveryFinished(_ id: UUID, outcome: DeliveryOutcome) {
        guard let delivery = deliveries.first(where: { $0.id == id }) else { return }
        defer { advertiser?.refresh() }
        switch outcome {
        case .interrupted(let reason):
            // Kept: the Mac advertises it again and the phone retries when it can.
            Log.transfer.warning("Delivery interrupted (\(reason, privacy: .public)); waiting for the phone again")
            delivery.phase = .waiting
            delivery.record(bytesSent: 0)
            return
        case .completed where delivery.text != nil:
            notifications.postMessage(title: String(localized: "Copied to \(delivery.deviceName)'s clipboard"), body: delivery.title)
        case .completed(let files, let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            notifications.postMessage(
                title: String(localized: "Sent to \(delivery.deviceName)"),
                body: files == 1 ? "\(delivery.title) · \(size)" : String(localized: "\(files) files · \(size)")
            )
        case .rejected(let reason):
            let body = switch reason {
            case "declined": String(localized: "Declined on the phone")
            case "timeout": String(localized: "No answer on the phone")
            case "insufficient_storage": String(localized: "Not enough space on the phone")
            default: reason
            }
            notifications.postMessage(title: String(localized: "\(delivery.deviceName) didn't take the files"), body: body)
        case .cancelledByPeer:
            notifications.postMessage(title: String(localized: "\(delivery.deviceName) cancelled the transfer"), body: delivery.title)
        case .cancelled:
            break
        }
        deliveries.removeAll { $0.id == id }
    }

    func currentPresenceKey() -> Data? { presenceKey?.raw }

    func sessionEnded(_ entryId: UUID, peer: PeerInfo?, error: SessionError?) {
        sessionHandles[entryId] = nil
        transferFinished(entryId, outcome: .failed(error?.userMessage ?? String(localized: "Connection closed")))
        endPairing(entryId)
        updateEntry(entryId, .ended(peer, error))
        Task { [weak self] in
            try? await Task.sleep(for: Self.endedEntryLifetime)
            self?.connections.removeAll { $0.id == entryId }
        }
    }
}

/// One TCP connection as shown in the menu.
struct ConnectionEntry: Identifiable {
    enum State {
        case handshaking
        case connected(PeerInfo, SessionStatus)
        case pairing(PeerInfo)
        case ended(PeerInfo?, SessionError?)

        var isEnded: Bool {
            if case .ended = self { return true }
            return false
        }

        var peer: PeerInfo? {
            switch self {
            case .handshaking: nil
            case .connected(let peer, _), .pairing(let peer): peer
            case .ended(let peer, _): peer
            }
        }
    }

    let id = UUID()
    let remote: String
    var state: State = .handshaking
}
