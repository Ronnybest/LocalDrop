import AppKit
import SwiftUI

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
              pasteboard.types?.contains(.fileURL) == true,
              model.deviceList.contains(where: \.canReceive) else { return }
        show()
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
            panel.orderOut(nil)
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
            ForEach(model.deviceList.filter(\.canReceive)) { phone in
                PhoneDropTile(phone: phone, sent: state.sentTo == phone.id) { urls in
                    model.send(urls, to: phone.id)
                    dropped(phone.id)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .panelCard(width: 150, cornerRadius: 24)
    }
}

private struct PhoneDropTile: View {
    let phone: DeviceListItem
    let sent: Bool
    let send: ([URL]) -> Void
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
            // Always one line, so the panel keeps its size when it says "Sending".
            Text(sent ? String(localized: "Drop zone sending") : phone.status.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .animation(.spring(duration: 0.2), value: isTargeted)
        .animation(.easeOut(duration: 0.2), value: sent)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            guard !files.isEmpty else { return false }
            send(files)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
