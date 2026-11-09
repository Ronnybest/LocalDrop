import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What the share sheet handed over, in the form `ClientSession` sends it.
nonisolated enum SharedContent: Sendable {
    /// Local copies, so the size is known before `transfer_request` and nothing is read lazily
    /// (from iCloud, from Photos) once the Mac waits for data.
    case files([OutgoingItem])
    /// For the Mac's clipboard: the links, else the texts, one per line.
    case text(String, isLink: Bool)

    /// One folder per share in the App Group container, removed when the share ends.
    static let stagingRoot = (AppGroup.container?.appending(path: "Library/Caches", directoryHint: .isDirectory) ?? URL.cachesDirectory)
        .appending(path: "Sharing", directoryHint: .isDirectory)

    /// Files win over text: a photo shared with its caption goes as the photo. The work happens in
    /// the providers' completion handlers, off the main actor.
    static func load(_ items: [NSExtensionItem], into staging: URL) async throws -> SharedContent {
        let providers = items.flatMap { $0.attachments ?? [] }
        let files = providers.filter(isFile)
        if !files.isEmpty {
            var loaded: [OutgoingItem] = []
            for (index, provider) in files.enumerated() {
                loaded.append(try await file(from: provider, into: staging.appending(path: "\(index)", directoryHint: .isDirectory)))
            }
            return .files(loaded)
        }
        var links: [String] = []
        var texts: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = try? await transferable(URL.self, from: provider) {
                if !links.contains(url.absoluteString) { links.append(url.absoluteString) }
            } else if provider.canLoadObject(ofClass: String.self), let text = try? await transferable(String.self, from: provider), !text.isEmpty {
                texts.append(text)
            }
        }
        // Some apps put the text on the item and attach nothing.
        for item in items where (item.attachments ?? []).isEmpty {
            if let text = item.attributedContentText?.string, !text.isEmpty { texts.append(text) }
        }
        let text = (links.isEmpty ? texts : links).joined(separator: "\n")
        guard !text.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return .text(text, isLink: !links.isEmpty)
    }

    /// A file, a photo or a video rather than a link or text (the Mac's `ShareModel.isFile`). A text
    /// file from Files counts too: it opens in place, where a snippet of text doesn't.
    private static func isFile(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || !provider.registeredContentTypesForOpenInPlace.isEmpty
            || provider.registeredContentTypes.contains { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }
    }

    /// Copies the provider's file into `folder` under its own name (one folder per item, as two
    /// photos may both be "image.jpeg"). The file the provider hands over is gone once its handler
    /// returns; `copyItem` clones it on APFS, never through memory.
    private static func file(from provider: NSItemProvider, into folder: URL) async throws -> OutgoingItem {
        // The richest real data type: not a link, not a private thumbnail of Photos.
        let type = provider.registeredContentTypes.first {
            $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.isDynamic && !$0.identifier.hasPrefix("com.apple.private.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let keep: @Sendable (URL?, (any Error)?) -> Void = { url, error in
                guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                // The Mac's "Photos and videos" policy checks the extension.
                var name = url.lastPathComponent
                if url.pathExtension.isEmpty, let ext = type?.preferredFilenameExtension { name += ".\(ext)" }
                let copy = folder.appending(path: name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: try OutgoingItem.file(copy))
                } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
                    continuation.resume(throwing: ClientError.storageFailed)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            if let type {
                _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in keep(url, error) }
            } else {
                // Only a file URL, as some file managers share: read it under its security scope.
                _ = provider.loadTransferable(type: URL.self) { result in
                    switch result {
                    case .success(let url):
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        keep(url, nil)
                    case .failure(let error):
                        keep(nil, error)
                    }
                }
            }
        }
    }

    private static func transferable<T: Transferable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: type) { continuation.resume(with: $0) }
        }
    }
}
