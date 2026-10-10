import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// "Share → Dewlet" in Finder, Photos and other apps: pick a paired phone, and the files go
/// to it through the LocalDrop app (ShareInbox).
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let model = ShareModel(items: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        model.finish = { [weak self] sent in
            if sent {
                self?.extensionContext?.completeRequest(returningItems: nil)
            } else {
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }
        // The share sheet takes its size from this controller: pass the SwiftUI size on.
        let hosting = NSHostingController(rootView: ShareView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        addChild(hosting)
        view = NSView()
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let size = hosting.view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        preferredContentSize = size
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        preferredContentSize = viewController.preferredContentSize
    }
}

@Observable
final class ShareModel {
    enum Phase: Equatable {
        case choosing
        case preparing
        case failed(String)
    }

    /// Files go to Downloads on the phone; a link or text goes to its clipboard.
    enum Kind {
        case files
        case link
        case text
    }

    let phones = ShareInbox.phones()
    var phase: Phase = .choosing
    var finish: (Bool) -> Void = { _ in }
    let kind: Kind
    private let items: [NSExtensionItem]

    private static let log = Logger(subsystem: "dev.localdrop.mac", category: "share")

    init(items: [NSExtensionItem]) {
        self.items = items
        let providers = items.flatMap { $0.attachments ?? [] }
        for item in items {
            Self.log.info("Item: userInfo keys \((item.userInfo?.keys.map { "\($0)" } ?? []).description, privacy: .public), title \(item.attributedTitle != nil, privacy: .public), text \(item.attributedContentText?.length ?? 0, privacy: .public) chars")
        }
        Self.log.info("Shared: \(items.count) item(s), types \(providers.map(\.registeredTypeIdentifiers).description, privacy: .public), text \(items.contains { $0.attributedContentText != nil }, privacy: .public), link in text \(items.contains { Self.link(in: $0) != nil }, privacy: .public)")
        if !providers.isEmpty, providers.allSatisfy(Self.isFile) {
            kind = .files
        } else if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) })
                    || items.contains(where: { Self.link(in: $0) != nil }) {
            kind = .link
        } else {
            kind = .text
        }
    }

    var itemCount: Int { items.reduce(0) { $0 + ($1.attachments?.count ?? 0) } }

    func send(to phone: ShareInbox.Phone) {
        phase = .preparing
        Task {
            do {
                if kind != .files {
                    try ShareInbox.submit(text: try await sharedText(), to: phone.deviceId)
                    await Self.openAppIfNeeded()
                    finish(true)
                    return
                }
                // Files are copied while their temporary access (e.g. from Photos) is valid.
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                var files: [URL] = []
                for provider in items.flatMap({ $0.attachments ?? [] }) {
                    files.append(try await Self.file(from: provider, into: staging))
                }
                try ShareInbox.submit(files, to: phone.deviceId)
                await Self.openAppIfNeeded()
                finish(true)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { finish(false) }

    /// A file, a photo or a video, rather than a link or text.
    private static func isFile(_ provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return true }
        return provider.registeredTypeIdentifiers.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
        }
    }

    /// A link given as the item's text rather than as an attachment: Safari shares a page with no
    /// attachments, only the text — the address itself, or the title carrying it as a link.
    private static func link(in item: NSExtensionItem) -> URL? {
        guard let text = item.attributedContentText, text.length > 0 else { return nil }
        var link: URL?
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            link = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            if link != nil { stop.pointee = true }
        }
        if let link { return link }
        let string = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.contains(where: \.isWhitespace), let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return url
    }

    /// The shared link (a web page from Safari) or text, one per line when there are several.
    private func sharedText() async throws -> String {
        var parts: [String] = []
        for item in items where (item.attachments ?? []).isEmpty {
            if let link = Self.link(in: item) {
                parts.append(link.absoluteString)
            } else if let text = item.attributedContentText?.string, !text.isEmpty {
                parts.append(text)
            }
        }
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                if let url = item as? URL {
                    parts.append(url.absoluteString)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    parts.append(url.absoluteString)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                if let text = item as? String {
                    parts.append(text)
                } else if let text = item as? NSAttributedString {
                    parts.append(text.string)
                } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    parts.append(text)
                }
            }
        }
        let text = parts.joined(separator: "\n")
        guard !text.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return text
    }

    /// The share waits in the inbox either way; LocalDrop picks it up when it starts.
    private static func openAppIfNeeded() async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "dev.localdrop.mac").isEmpty else { return }
        // LocalDrop.app/Contents/PlugIns/LocalDropShare.appex
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    /// A file URL as is; anything else (a photo from Photos) as the file the app provides.
    private static func file(from provider: NSItemProvider, into staging: URL) async throws -> URL {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
            if let url = item as? URL { return url }
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
        }
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                // The provided file disappears when this callback returns: keep a copy.
                let copy = staging.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct ShareView: View {
    let model: ShareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send with Dewlet")
                    .font(.headline)
                Group {
                    switch model.kind {
                    case .files: Text("\(model.itemCount) files")
                    case .link: Text("A link, to the phone's clipboard")
                    case .text: Text("Text, to the phone's clipboard")
                    }
                }
                .foregroundStyle(.secondary)
            }
            switch model.phase {
            case .choosing:
                if model.phones.isEmpty {
                    Text("No phone can receive yet. Pair an Android phone with Dewlet and open Dewlet on it once.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(model.phones) { phone in
                            PhoneRow(phone: phone) { model.send(to: phone) }
                        }
                    }
                    Text("The phone gets the files as soon as it's nearby, even if Dewlet isn't open on it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing…").foregroundStyle(.secondary)
                }
            case .failed(let reason):
                Text(reason)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

private struct PhoneRow: View {
    let phone: ShareInbox.Phone
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "smartphone")
                    .font(.title3)
                    .frame(width: 24)
                Text(phone.name)
                Spacer()
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(hovered ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(hovered ? 1 : 0.6), in: .rect(cornerRadius: 10))
        .onHover { hovered = $0 }
    }
}
