import SwiftUI
import UIKit

/// Share › Dewlet: sends what was shared straight to a paired Mac. The extension runs the whole
/// transfer itself while the sheet is open, so Dewlet needn't be running.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(items: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        model.finish = { [weak self] sent in
            if sent {
                self?.extensionContext?.completeRequest(returningItems: nil)
            } else {
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }
        let hosting = UIHostingController(rootView: ShareView(model: model))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        // Swiping the sheet away would cut a transfer off; Cancel ends it politely.
        isModalInPresentation = true
    }
}

/// One share: what was shared (loaded at once, while the user picks a Mac), then the transfer.
@Observable final class ShareModel {
    enum Phase: Equatable {
        case choosing
        /// Send was tapped before the shared files were copied out.
        case preparing
        case connecting(macName: String)
        /// nil progress: text, which has none, or files before the request went out.
        case sending(TransferProgress?, macName: String)
        case cancelling
        case failed(String)
        /// `copied`: text that went to the Mac's clipboard.
        case sent(macName: String, copied: Bool)

        /// Picking another Mac or sending again waits until this ends.
        var isBusy: Bool {
            switch self {
            case .choosing, .failed: false
            case .preparing, .connecting, .sending, .cancelling, .sent: true
            }
        }
    }

    /// Newest `lastSeen` first.
    let macs = MacStore.shared.macs
    var selection: String?
    private(set) var content: SharedContent?
    /// Why the shared items couldn't be read: nothing can be sent then.
    private(set) var loadFailure: String?
    private(set) var phase: Phase = .choosing
    var finish: (Bool) -> Void = { _ in }

    /// A finished share stays on screen this long, like the system's own confirmations.
    private static let sentDelay: Duration = .seconds(1.2)
    /// Copies a killed extension left behind are removed after this long.
    private static let leftoverAge: TimeInterval = 3600

    @ObservationIgnored private let staging = SharedContent.stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    @ObservationIgnored private var loading: Task<SharedContent?, Never>?
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var session: ClientSession?
    @ObservationIgnored private var finished = false

    init(items: [NSExtensionItem]) {
        selection = macs.count == 1 ? macs[0].id : nil
        Task.detached(priority: .utility) { [root = SharedContent.stagingRoot, age = Self.leftoverAge] in
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for folder in folders {
                guard let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate, -created.timeIntervalSinceNow > age else { continue }
                try? FileManager.default.removeItem(at: folder)
            }
        }
        // With no Mac to send to, nothing is copied.
        guard !macs.isEmpty else { return }
        loading = Task { [staging] in
            do {
                let content = try await SharedContent.load(items, into: staging)
                withAnimation { self.content = content }
                return content
            } catch {
                Log.app.error("Shared items unreadable: \(String(describing: error), privacy: .public)")
                withAnimation {
                    self.loadFailure = (error as? ClientError)?.message(macName: "")
                        ?? String(localized: "The app you shared from didn’t allow access to these files. Share them from Files or Photos.")
                }
                return nil
            }
        }
    }

    func send() {
        guard let mac = macs.first(where: { $0.id == selection }), !phase.isBusy else { return }
        // Leaving the app the sheet is over suspends the extension with it: iOS gives it some time
        // to finish (the activity lasts while its block waits), then the send is cancelled cleanly.
        let finished = DispatchSemaphore(value: 0)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Sending to a Mac") { [weak self] expired in
            guard !expired else {
                Task { @MainActor in self?.cancel() }
                return
            }
            finished.wait()
        }
        sending = Task {
            defer { finished.signal() }
            do {
                if content == nil { withAnimation { phase = .preparing } }
                guard let loading, let content = await loading.value else {
                    withAnimation { phase = .choosing }
                    return
                }
                withAnimation { phase = .connecting(macName: mac.name) }
                let name = Phone.name
                // Keychain reads block.
                let phone = try await Task.detached { try Phone.load() }.value
                let session = try await ClientSession.open(to: mac, phone: phone, name: name)
                guard !Task.isCancelled else { return await session.close() }
                self.session = session
                let macName = session.mac.name
                var copied = false
                withAnimation { phase = .sending(nil, macName: macName) }
                switch content {
                case .files(let items):
                    // In order, and only the newest: reports come every 100 ms from the session's task.
                    let (updates, continuation) = AsyncStream.makeStream(of: TransferProgress.self, bufferingPolicy: .bufferingNewest(1))
                    Task {
                        for await progress in updates {
                            guard case .sending(let last, _) = phase else { continue }
                            withAnimation(last?.phase != progress.phase ? .default : nil) { phase = .sending(progress, macName: macName) }
                        }
                    }
                    defer { continuation.finish() }
                    let report: @Sendable (TransferProgress) -> Void = { continuation.yield($0) }
                    try await session.send(items, progress: report)
                case .text(let text, _):
                    copied = session.mac.capabilities.contains(ProtocolConstants.clipboardReceiveCapability) && text.utf8.count <= ProtocolConstants.maxTextSize
                    try await session.send(text: text)
                }
                await session.close()
                guard phase != .cancelling else { return }
                withAnimation { phase = .sent(macName: macName, copied: copied) }
                try? await Task.sleep(for: Self.sentDelay)
                end(sent: true)
            } catch {
                // A rejection leaves the session open.
                await session?.close()
                session = nil
                guard phase != .cancelling, !Task.isCancelled else { return }
                let failure = error as? ClientError ?? .identityUnavailable
                withAnimation { phase = .failed(failure.message(macName: mac.name)) }
            }
        }
    }

    /// A running transfer is cancelled on the Mac too (`close` sends cancel and waits for the Mac to
    /// close, at most 2 s) before the sheet goes; anything else just ends.
    func cancel() {
        switch phase {
        case .sending:
            guard let session else { return end(sent: false) }
            withAnimation { phase = .cancelling }
            Task {
                await session.close()
                end(sent: false)
            }
        case .cancelling:
            break
        case .sent:
            end(sent: true)
        default:
            sending?.cancel()
            end(sent: false)
        }
    }

    private func end(sent: Bool) {
        guard !finished else { return }
        finished = true
        loading?.cancel()
        try? FileManager.default.removeItem(at: staging)
        finish(sent)
    }
}
