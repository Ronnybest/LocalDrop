import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// While files are being dragged anywhere on the Mac, a small panel at the screen's right edge
/// offers the paired phones as drop targets. The menu bar is hard to reach with a drag (the top
/// edge opens Mission Control), so the targets come to the files instead.
///
/// Mouse monitors need no permission; the drag pasteboard tells a file drag from any other.
@MainActor
final class DropZoneController {
    /// On unless turned off in Settings › General.
    static let enabledKey = "localdrop.dropZone"

    private let model: AppModel
    private let state = DropZoneState()
    private var monitors: [Any] = []
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// The drag pasteboard's change count when the last drag was looked at: one look per drag.
    private var seenDrag = NSPasteboard(name: .drag).changeCount

    private static let margin: CGFloat = 16
    /// How long "Sending" stays on screen after a drop.
    private static let confirmation: Duration = .milliseconds(1200)

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    init(model: AppModel) {
        self.model = model
        let dragged: NSEvent.EventTypeMask = [.leftMouseDragged]
        let released: NSEvent.EventTypeMask = [.leftMouseUp]
        // Global monitors see other apps' events; local ones this app's (e.g. dragging from Settings).
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: dragged) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDragged() }
            },
            NSEvent.addGlobalMonitorForEvents(matching: released) { [weak self] _ in
                MainActor.assumeIsolated { self?.dragEnded() }
            },
            NSEvent.addLocalMonitorForEvents(matching: released) { [weak self] event in
                MainActor.assumeIsolated { self?.dragEnded() }
                return event
            },
        ].compactMap { $0 }
    }

    private func mouseDragged() {
        guard panel == nil else { return }
        let pasteboard = NSPasteboard(name: .drag)
        // Until the dragging app writes the pasteboard, this is a plain mouse drag (selecting
        // text, moving a window): look again on the next event.
        guard pasteboard.changeCount != seenDrag else { return }
        seenDrag = pasteboard.changeCount
        guard Self.isEnabled,
              Self.carriesFiles(pasteboard),
              model.deviceList.contains(where: \.canReceive) else { return }
        show()
    }

    /// Files or folders, or files an app writes only once dropped (photos from Photos).
    private static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])
        let promised = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) })
        return types.contains(.fileURL) || !types.isDisjoint(with: promised)
    }

    private func dragEnded() {
        guard panel != nil, hideTask == nil else { return }
        // The mouse-up can come before the drop is delivered: give it a moment. A drop on the
        // panel shows its confirmation first; otherwise the panel goes.
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.state.sentTo == nil else { return }
            self.hide()
        }
    }

    private func show() {
        hideTask?.cancel()
        state.sentTo = nil
        let view = DropZoneView(model: model, state: state) { [weak self] deviceId in
            self?.dropped(on: deviceId)
        }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        // On the screen the drag is on, at its right edge, vertically centered.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let origin = NSPoint(x: visible.maxX - size.width - Self.margin, y: visible.midY - size.height / 2)
        panel.setFrameOrigin(NSPoint(x: origin.x + 24, y: origin.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
        self.panel = panel
    }

    private func dropped(on deviceId: String) {
        state.sentTo = deviceId
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmation)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            // AppKit runs animation completions on the main thread.
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

@Observable
final class DropZoneState {
    /// The phone files were just dropped on.
    var sentTo: String?
}

/// The phones as drop targets, one tile each.
private struct DropZoneView: View {
    let model: AppModel
    let state: DropZoneState
    let dropped: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Send with LocalDrop")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            ForEach(model.deviceList.filter(\.canReceive)) { phone in
                PhoneDropTile(phone: phone, sent: state.sentTo == phone.id) { providers in
                    let deviceId = phone.id
                    Task {
                        let dropped = await DroppedFiles.load(providers)
                        if !dropped.files.isEmpty { model.send(dropped.files, to: deviceId) }
                        if let directory = dropped.directory { model.sendStaged(dropped.written, in: directory, to: deviceId) }
                    }
                    dropped(phone.id)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .panelCard(width: 170, cornerRadius: 24)
    }
}

private struct PhoneDropTile: View {
    let phone: DeviceListItem
    let sent: Bool
    let send: ([NSItemProvider]) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: sent ? "checkmark" : phone.symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isTargeted || sent ? .white : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 60, height: 60)
                .background(isTargeted || sent ? Color.accentColor : Color.accentColor.opacity(0.16), in: Circle())
                .scaleEffect(isTargeted ? 1.1 : 1)
            Text(phone.name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            // Always two lines' height, so the panel keeps its size when it says "Sending".
            Text(sent ? String(localized: "Drop zone sending") : phone.status.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .animation(.spring(duration: 0.2), value: isTargeted)
        .animation(.easeOut(duration: 0.2), value: sent)
        // Item providers rather than URLs: Photos hands over files only as promises.
        .onDrop(of: [.fileURL, .image, .movie], isTargeted: $isTargeted) { providers in
            send(providers)
            return true
        }
    }
}

/// What was dropped: files and folders as they are, and files written for the drop (photos and
/// videos from Photos) into a staging folder.
nonisolated struct DroppedFiles {
    var files: [URL] = []
    var written: [URL] = []
    var directory: URL?

    static func load(_ providers: [NSItemProvider]) async -> DroppedFiles {
        var dropped = DroppedFiles()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await fileURL(from: provider) { dropped.files.append(url) }
                continue
            }
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) else { continue }
            do {
                let directory = try dropped.directory ?? AppModel.makeStagingDirectory()
                dropped.directory = directory
                if let file = try await write(provider, type: type, into: directory) { dropped.written.append(file) }
            } catch {
                Log.transfer.error("Could not take a dropped item: \(error.localizedDescription, privacy: .public)")
            }
        }
        return dropped
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
    }

    /// The file the app provides disappears when its callback returns: a copy is kept.
    private static func write(_ provider: NSItemProvider, type: String, into directory: URL) async throws -> URL? {
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                var name = suggested ?? url.deletingPathExtension().lastPathComponent
                if !url.pathExtension.isEmpty, (name as NSString).pathExtension.isEmpty { name += "." + url.pathExtension }
                let copy = directory.appendingPathComponent(name)
                continuation.resume(with: Result { try FileManager.default.copyItem(at: url, to: copy); return copy })
            }
        }
    }
}
