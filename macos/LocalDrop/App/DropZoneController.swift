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
    /// The tab, or the phones once a drag reached the tab.
    private var panel: NSPanel?
    private var expanded = false
    /// The screen the drag started on.
    private weak var screen: NSScreen?
    private var hideTask: Task<Void, Never>?
    /// While the phones are out: folds them back into the tab once the drag moves away.
    private var leaveTask: Task<Void, Never>?
    /// The drag pasteboard's change count once the last drag was settled: one decision per drag.
    private var seenDrag = NSPasteboard(name: .drag).changeCount
    /// When the current drag's pasteboard change was first noticed.
    private var dragNoticed: (changeCount: Int, at: ContinuousClock.Instant)?

    private static let margin: CGFloat = 16
    /// How far past the phones' panel a drag may wander, and for how long, before it folds back.
    private static let leaveSlop: CGFloat = 32
    private static let leaveTime: Duration = .milliseconds(300)
    /// How long a drag pasteboard may stay without files before the drag counts as something else.
    private static let settleTime: Duration = .milliseconds(500)
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
        let changeCount = pasteboard.changeCount
        guard changeCount != seenDrag else { return }
        guard Self.isEnabled, model.deviceList.contains(where: \.canReceive) else {
            seenDrag = changeCount
            return
        }
        if Self.carriesFiles(pasteboard) {
            seenDrag = changeCount
            dragNoticed = nil
            show()
            return
        }
        // Apps fill the drag pasteboard in steps: right after it changes it can still be empty,
        // and a file drag taken for something else never showed the panel. Look again on the
        // next events for a moment before deciding.
        let now = ContinuousClock.now
        if dragNoticed?.changeCount != changeCount { dragNoticed = (changeCount, now) }
        if let noticed = dragNoticed, now - noticed.at >= Self.settleTime {
            seenDrag = changeCount
            dragNoticed = nil
            let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ", ")
            Log.app.info("Drag without files: \(types, privacy: .public)")
        }
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

    /// First only a tab at the screen's edge, so a drag elsewhere isn't covered by the phones;
    /// dragging onto the tab slides the phones out.
    private func show() {
        hideTask?.cancel()
        state.sentTo = nil
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        showTab()
    }

    private func showTab() {
        let visible = screen?.visibleFrame ?? .zero
        let tab = DropZoneTab { [weak self] in self?.expand() }
        let size = NSHostingView(rootView: tab).fittingSize
        // Against the edge, so a drag pushed to the edge lands on it.
        let origin = NSPoint(x: visible.maxX - size.width, y: visible.midY - size.height / 2)
        present(tab, size: size, at: origin)
    }

    private func expand() {
        guard let tab = panel, !expanded else { return }
        expanded = true
        slideAway(tab)
        let view = DropZoneView(model: model, state: state) { [weak self] deviceId in
            self?.dropped(on: deviceId)
        }
        let size = NSHostingView(rootView: view).fittingSize
        // On the screen the drag is on, at its right edge, vertically centered.
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let origin = NSPoint(x: visible.maxX - size.width - Self.margin, y: visible.midY - size.height / 2)
        present(view, size: size, at: origin)
        watchForLeaving()
    }

    /// The mouse position rather than drag events: a drag between other apps reaches this app
    /// only over its own windows.
    private func watchForLeaving() {
        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            var outsideSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.expanded, let panel = self.panel else { return }
                // Files just dropped: the panel stays for its confirmation.
                guard self.state.sentTo == nil else { return }
                let area = panel.frame.insetBy(dx: -Self.leaveSlop, dy: -Self.leaveSlop)
                if area.contains(NSEvent.mouseLocation) {
                    outsideSince = nil
                } else if let since = outsideSince {
                    if ContinuousClock.now - since >= Self.leaveTime {
                        self.collapse()
                        return
                    }
                } else {
                    outsideSince = .now
                }
            }
        }
    }

    private func collapse() {
        guard expanded, let panel else { return }
        expanded = false
        slideAway(panel)
        showTab()
    }

    /// Slides a panel's content out from the screen's right edge. The content moves, not the
    /// window: a window's frame animation stopped short or jumped while another app dragged.
    private func present(_ view: some View, size: NSSize, at origin: NSPoint) {
        // The window reaches the screen's edge, so the content comes out from behind it.
        let edge = screen?.visibleFrame.maxX ?? origin.x + size.width
        let width = max(size.width, edge - origin.x)
        let panel = EdgePanel(contentRect: NSRect(x: origin.x, y: origin.y, width: width, height: size.height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: size.height))
        container.wantsLayer = true
        container.clipsToBounds = true
        let content = NSHostingView(rootView: view)
        content.sizingOptions = []
        content.frame = NSRect(x: width, y: 0, width: size.width, height: size.height)
        container.addSubview(content)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window's shadow doesn't follow moving content: on once it settles.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            content.animator().setFrameOrigin(.zero)
        } completionHandler: {
            // AppKit runs animation completions on the main thread.
            MainActor.assumeIsolated {
                guard !panel.isLeaving else { return }
                panel.hasShadow = true
                panel.invalidateShadow()
            }
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
        leaveTask?.cancel()
        leaveTask = nil
        expanded = false
        guard let panel else { return }
        self.panel = nil
        slideAway(panel)
    }

    /// Slides the content back behind the screen's edge.
    private func slideAway(_ panel: NSPanel) {
        guard let panel = panel as? EdgePanel, let content = panel.contentView?.subviews.first else {
            panel.orderOut(nil)
            return
        }
        panel.isLeaving = true
        panel.hasShadow = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            content.animator().setFrameOrigin(NSPoint(x: panel.frame.width, y: 0))
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

private final class EdgePanel: NSPanel {
    /// Sliding away: the shadow stays off.
    var isLeaving = false
}

@Observable
final class DropZoneState {
    /// The phone files were just dropped on.
    var sentTo: String?
}

/// The tab at the screen's edge: a drag that reaches it brings out the phones.
private struct DropZoneTab: View {
    let reached: () -> Void
    @State private var isTargeted = false

    var body: some View {
        Image(systemName: "chevron.compact.left")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 24, height: 96)
            .background(EdgeGlassBackground(cornerRadius: 12))
            .contentShape(Rectangle())
            .accessibilityLabel(Text("Send with Dewlet"))
            // Only to notice the drag: files go to the phones that slide out.
            .onDrop(of: [.fileURL, .image, .movie], isTargeted: $isTargeted) { _ in false }
            .onChange(of: isTargeted) { _, targeted in
                if targeted { reached() }
            }
    }
}

/// Panel glass rounded only on the left: the right side lies against the screen's edge.
private struct EdgeGlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    private static let overhang: CGFloat = 40

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        container.layer?.masksToBounds = true
        let glass: NSView
        if #available(macOS 26, *) {
            let effect = NSGlassEffectView()
            effect.cornerRadius = cornerRadius
            glass = effect
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            glass = blur
        }
        // Wider than the tab: the glass's own right edge and corners lie past the screen's edge
        // and are cut off, so the tab sits flush against it.
        glass.frame = NSRect(x: 0, y: 0, width: container.bounds.width + Self.overhang, height: container.bounds.height)
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The phones as drop targets, one tile each.
private struct DropZoneView: View {
    let model: AppModel
    let state: DropZoneState
    let dropped: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Send with Dewlet")
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
