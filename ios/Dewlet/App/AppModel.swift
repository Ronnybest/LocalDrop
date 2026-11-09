import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The app's state: this iPhone, the paired Macs with one live link each while the app is in the
/// foreground, and what was sent and received.
@MainActor @Observable final class AppModel: MacLinkDelegate {
    /// What a Mac's card shows after a transfer: for a few seconds when it went well, until
    /// dismissed when it didn't.
    struct Outcome: Equatable {
        enum Kind: Equatable {
            case done
            case link(URL)
            /// `retry`: the files are still here to send again.
            case failed(retry: Bool)
        }

        let id = UUID()
        let kind: Kind
        let title: String
        var detail: String?
    }

    /// A send before the link runs it: photos copied out of the library, files out of iCloud.
    struct Preparation: Equatable {
        /// Ready and waiting for the link (connecting, or a receive round running): no longer cancellable here.
        var queued = false
    }

    private enum Payload {
        case files([OutgoingItem])
        case text(String)
    }

    static let savesToPhotosKey = "savesToPhotos"

    private(set) var phone: Phone?
    private(set) var phoneError: ClientError?
    private(set) var macs: [PairedMac] = []
    /// One per paired Mac once the phone's identity is loaded.
    private(set) var links: [String: MacLink] = [:]
    private(set) var history: [HistoryEntry]
    private(set) var preparing: [String: Preparation] = [:]
    private(set) var outcomes: [String: Outcome] = [:]
    let browser = BonjourBrowser()

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var preparations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedSends: [String: Payload] = [:]
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        history = History.load()
        IncomingFileWriter.removeLeftovers(in: URL.documentsDirectory)
        try? FileManager.default.removeItem(at: PickedItem.directory)
        Task { [weak self] in
            for await macs in MacStore.shared.changes() {
                guard let self else { return }
                sync(macs)
            }
        }
        Task { await loadPhone() }
    }

    /// The identity lives in the keychain, which fails before the first unlock after a restart.
    func loadPhone() async {
        phoneError = nil
        let result = await Task.detached { Result { () throws(ClientError) in try Phone.load() } }.value
        switch result {
        case .success(let phone):
            self.phone = phone
            sync(macs)
        case .failure(let error):
            withAnimation { phoneError = error }
        }
    }

    /// Links run while the app is in the foreground. Leaving it, they close politely; a transfer
    /// under way, a queued send and one still being prepared finish first, in a background task.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            for link in links.values { link.start() }
        case .background:
            isActive = false
            for link in links.values { link.stop() }
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish transfers") { [weak self] in
                guard let self else { return }
                // Out of time. Closed without a cancel, the Mac keeps what it was delivering (or
                // offering) and offers it again; queued sends fail with Try Again.
                for link in links.values { link.interrupt() }
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            Task {
                // A preparation that ends now still hands its send to the link, which runs it.
                while !isActive, !preparing.isEmpty || links.values.contains(where: { $0.state != .idle }) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard backgroundTask != .invalid else { return }
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        default:
            break
        }
    }

    private func sync(_ macs: [PairedMac]) {
        withAnimation { self.macs = macs }
        guard let phone else { return }
        for mac in macs where links[mac.id] == nil {
            let link = MacLink(mac: mac, phone: phone, delegate: self)
            links[mac.id] = link
            if isActive { link.start() }
        }
        for id in links.keys where !macs.contains(where: { $0.id == id }) {
            links.removeValue(forKey: id)?.stop()
            failedSends[id] = nil
            outcomes[id] = nil
        }
    }

    /// The link whose Mac waits for Accept or Decline: one offer at a time, in the order of the Macs.
    var offering: MacLink? {
        macs.lazy.compactMap { self.links[$0.id] }.first { link in
            if case .awaitingDecision = link.activity { true } else { false }
        }
    }

    /// The line under a Mac's name.
    func statusText(of mac: PairedMac) -> String {
        switch links[mac.id]?.state ?? .idle {
        case .idle, .connecting: String(localized: "Looking for \(mac.name)…")
        case .connected: String(localized: "Connected")
        case .unreachable(let error): error.message(macName: mac.name)
        case .notPaired: String(localized: "Not paired — add it again")
        }
    }

    // MARK: - Sending

    func send(_ picks: [PhotosPickerItem], to macId: String) {
        send(to: macId) { () async throws(ClientError) -> Payload in
            var items: [OutgoingItem] = []
            do throws(ClientError) {
                for pick in picks {
                    let isVideo = pick.supportedContentTypes.contains { $0.conforms(to: .movie) }
                    let loaded = try? await pick.loadTransferable(type: PickedItem.self)
                    if Task.isCancelled { throw .cancelled }
                    guard case .file(let url)? = loaded else {
                        throw .sourceUnavailable(name: isVideo ? String(localized: "A video") : String(localized: "A photo"))
                    }
                    items.append(try OutgoingItem.file(url))
                }
            } catch {
                Self.discard(.files(items))
                throw error
            }
            return .files(items)
        }
    }

    func send(files urls: [URL], to macId: String) {
        send(to: macId) { () async throws(ClientError) -> Payload in .files(try await Self.copy(urls)) }
    }

    /// From the Paste button: pictures as files, otherwise the text (a link is text too).
    func send(pasted items: [PickedItem], to macId: String) {
        var files: [OutgoingItem] = []
        var texts: [String] = []
        for item in items {
            switch item {
            case .file(let url): if let file = try? OutgoingItem.file(url) { files.append(file) }
            case .text(let text): texts.append(text)
            }
        }
        let text = texts.joined(separator: "\n")
        guard !files.isEmpty || !text.isEmpty else { return }
        send(to: macId) { () throws(ClientError) -> Payload in files.isEmpty ? .text(text) : .files(files) }
    }

    func retry(_ macId: String) {
        guard let payload = failedSends.removeValue(forKey: macId) else { return }
        send(to: macId) { () throws(ClientError) -> Payload in payload }
    }

    /// Stops a send that is still being prepared; once the link runs it, `MacLink.cancelActivity()` does.
    func cancelPreparation(for macId: String) {
        preparations[macId]?.cancel()
    }

    func dismissOutcome(_ macId: String) {
        if let payload = failedSends.removeValue(forKey: macId) { Self.discard(payload) }
        withAnimation { outcomes[macId] = nil }
    }

    /// Prepares the payload, hands it to the link and waits for the result: history and the card's
    /// outcome on success; on failure the outcome with the reason, and the files kept for a retry.
    private func send(to macId: String, prepare: @escaping () async throws(ClientError) -> Payload) {
        guard let link = links[macId], let mac = macs.first(where: { $0.id == macId }), preparing[macId] == nil else { return }
        dismissOutcome(macId)
        withAnimation { preparing[macId] = Preparation() }
        preparations[macId] = Task {
            var prepared: Payload?
            do throws(ClientError) {
                let payload = try await prepare()
                prepared = payload
                if Task.isCancelled { throw .cancelled }
                preparing[macId]?.queued = true
                let entry: HistoryEntry
                let outcome: Outcome
                switch payload {
                case .files(let items):
                    try await link.send(items)
                    let summary = items.count == 1 ? items[0].name : String(localized: "\(items.count) files")
                    entry = HistoryEntry(incoming: false, macName: mac.name, kind: .files, title: summary, count: items.count,
                                         bytes: items.reduce(0) { $0 + $1.size })
                    outcome = Outcome(kind: .done, title: String(localized: "Sent to \(mac.name)"), detail: summary)
                case .text(let text):
                    try await link.send(text: text)
                    entry = HistoryEntry(incoming: false, macName: mac.name, kind: Self.webLink(text) == nil ? .text : .link,
                                         title: text, bytes: Int64(text.utf8.count))
                    // Short text lands on the Mac's clipboard; a Mac without that, or a long text, gets a file.
                    outcome = (MacStore.shared.mac(macId) ?? mac).takesClipboardText && text.utf8.count <= ProtocolConstants.maxTextSize
                        ? Outcome(kind: .done, title: String(localized: "Copied to \(mac.name)"), detail: String(localized: "Paste it on the Mac with ⌘V."))
                        : Outcome(kind: .done, title: String(localized: "Sent to \(mac.name)"), detail: String(localized: "Text"))
                }
                Self.discard(payload)
                record(entry)
                show(outcome, for: macId)
            } catch {
                if error == .cancelled {
                    if let prepared { Self.discard(prepared) }
                } else {
                    failedSends[macId] = prepared
                    show(Outcome(kind: .failed(retry: prepared != nil), title: String(localized: "Couldn’t send to \(mac.name)"),
                                 detail: error.message(macName: mac.name)), for: macId)
                }
            }
            withAnimation { preparing[macId] = nil }
            preparations[macId] = nil
        }
    }

    /// Files from the file picker, copied out under their security scope (and downloaded first
    /// when they live in iCloud): the Mac must get every byte within seconds once it accepts.
    @concurrent private nonisolated static func copy(_ urls: [URL]) async throws(ClientError) -> [OutgoingItem] {
        var items: [OutgoingItem] = []
        do throws(ClientError) {
            for url in urls {
                if Task.isCancelled { throw .cancelled }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                var copied: URL?
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
                    copied = try? PickedItem.copy(readable, name: url.lastPathComponent)
                }
                guard let copied else {
                    Log.transfer.error("Could not copy a picked file: \(String(describing: coordinationError), privacy: .public)")
                    throw .sourceUnavailable(name: url.lastPathComponent)
                }
                items.append(try OutgoingItem.file(copied))
            }
        } catch {
            discard(.files(items))
            throw error
        }
        return items
    }

    private nonisolated static func discard(_ payload: Payload) {
        guard case .files(let items) = payload else { return }
        for item in items { try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent()) }
    }

    // MARK: - Receiving

    var receiveDirectory: URL { URL.documentsDirectory }

    /// Text goes to the clipboard at once. Photos and videos go to the photo library (unless
    /// turned off in Settings), everything else stays in Files › Dewlet.
    func link(_ link: MacLink, received items: [ReceivedItem], from macName: String) {
        var files: [(url: URL, name: String, mimeType: String, size: Int64)] = []
        for item in items {
            switch item {
            case .file(let url, let name, let mimeType, let size):
                files.append((url, name, mimeType, size))
            case .text(let text):
                UIPasteboard.general.string = text
                let url = Self.webLink(text)
                record(HistoryEntry(incoming: true, macName: macName, kind: url == nil ? .text : .link, title: text, bytes: Int64(text.utf8.count)))
                show(url.map { Outcome(kind: .link($0), title: String(localized: "Link from \(macName) copied"), detail: $0.host()) }
                     ?? Outcome(kind: .done, title: String(localized: "Text from \(macName) copied"), detail: text), for: link.macId)
            }
        }
        guard !files.isEmpty else { return }
        let macId = link.macId
        let savesToPhotos = UserDefaults.standard.object(forKey: Self.savesToPhotosKey) as? Bool ?? true
        let media = savesToPhotos ? files.compactMap { file -> (url: URL, name: String, type: PHAssetResourceType)? in
            guard let type = UTType(filenameExtension: file.url.pathExtension) ?? UTType(mimeType: file.mimeType) else { return nil }
            if type.conforms(to: .movie) { return (file.url, file.name, .video) }
            if type.conforms(to: .image) { return (file.url, file.name, .photo) }
            return nil
        } : []
        Task {
            let added = media.isEmpty ? [] : await Self.saveToPhotos(media)
            let saved = added ?? []
            let kept = files.filter { !saved.contains($0.url) }
            let title = files.count == 1 ? files[0].name : String(localized: "\(files.count) files")
            record(HistoryEntry(incoming: true, macName: macName, kind: .files, title: title, count: files.count,
                                bytes: files.reduce(0) { $0 + $1.size }, files: kept.map(\.url.lastPathComponent), savedToPhotos: saved.count))
            let detail = kept.isEmpty ? String(localized: "Saved to Photos")
                // Otherwise the setting looks broken.
                : added == nil ? String(localized: "Kept in Files: Dewlet isn’t allowed to add to Photos. Allow it in Settings.")
                : saved.isEmpty ? String(localized: "In the Files app › Dewlet")
                : String(localized: "Photos and videos in Photos, the rest in Files")
            show(Outcome(kind: .done, title: files.count == 1 ? String(localized: "\(files[0].name) received") : String(localized: "\(files.count) files received"),
                         detail: detail), for: macId)
        }
    }

    /// The card says it when the send that queued it returns: only that knows what went.
    func link(_ link: MacLink, finishedSending summary: String, to macName: String) {}

    func link(_ link: MacLink, failed error: ClientError, macName: String) {
        show(Outcome(kind: .failed(retry: false), title: String(localized: "Couldn’t receive from \(macName)"),
                     detail: error.message(macName: macName)), for: link.macId)
    }

    /// Moves each file into the library (after the transfer finished, so the Mac never waits on
    /// it); returns the ones that went, nil when Dewlet may not add to Photos. A file Photos can't
    /// take stays in Files.
    @concurrent private nonisolated static func saveToPhotos(_ media: [(url: URL, name: String, type: PHAssetResourceType)]) async -> Set<URL>? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Log.app.info("No access to add to Photos; keeping \(media.count) file(s) in Files")
            return nil
        }
        var saved = Set<URL>()
        for file in media {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = file.name
                    options.shouldMoveFile = true
                    PHAssetCreationRequest.forAsset().addResource(with: file.type, fileURL: file.url, options: options)
                }
                try? FileManager.default.removeItem(at: file.url)
                saved.insert(file.url)
            } catch {
                Log.app.error("Photos didn't take a received file: \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.app.info("Saved \(saved.count) of \(media.count) received file(s) to Photos")
        return saved
    }

    // MARK: - History and outcomes

    private func record(_ entry: HistoryEntry) {
        withAnimation {
            history.insert(entry, at: 0)
            if history.count > History.limit { history.removeLast(history.count - History.limit) }
        }
        History.save(history)
    }

    private func show(_ outcome: Outcome, for macId: String) {
        withAnimation { outcomes[macId] = outcome }
        if case .failed = outcome.kind { return }
        Task {
            // A link stays a little longer: it has an Open button.
            try? await Task.sleep(for: .seconds(outcome.kind == .done ? 5 : 10))
            guard outcomes[macId]?.id == outcome.id else { return }
            withAnimation { outcomes[macId] = nil }
        }
    }

    /// The text when it is nothing but one web link.
    nonisolated static func webLink(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }
}

/// A photo, video, pasted picture or text, as a send needs it: a local file of known size (once
/// the Mac accepts, it waits at most 150 s for the first file and 30 s between chunks) or text.
nonisolated enum PickedItem: Transferable, Sendable {
    case file(URL)
    case text(String)

    /// Emptied at launch: what a send leaves behind is never needed again.
    static let directory = URL.temporaryDirectory.appending(path: "Outgoing", directoryHint: .isDirectory)

    static var transferRepresentation: some TransferRepresentation {
        // Videos first: a picked video also offers a still image.
        FileRepresentation(importedContentType: .movie) { .file(try copy($0.file, name: $0.file.lastPathComponent)) }
        FileRepresentation(importedContentType: .image) { .file(try copy($0.file, name: $0.file.lastPathComponent)) }
        ProxyRepresentation(importing: { (url: URL) in .text(url.absoluteString) })
        ProxyRepresentation(importing: { (text: String) in .text(text) })
    }

    /// Into a directory of its own, so every file keeps its name next to others with the same one.
    static func copy(_ url: URL, name: String) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: FileNames.sanitize(name))
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
