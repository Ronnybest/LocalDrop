import AppKit
import SwiftUI

/// A borderless panel still takes keyboard focus (Return/Escape on its buttons) when clicked.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A floating window for prompts that must be seen without opening the menu (a menu bar app
/// has no window of its own).
final class FloatingPanel: NSObject, NSWindowDelegate {
    enum Style {
        /// Centered and focused: for decisions that must not be missed (pairing codes).
        case alert
        /// Top-right corner like a notification, without taking focus from the current app,
        /// with its buttons always visible (system notification actions are hidden until hover).
        case banner
    }

    private var panel: NSPanel?
    private var style: Style = .alert
    private var onUserClose: (() -> Void)?

    private static let bannerMargin: CGFloat = 12

    var isVisible: Bool { panel != nil }

    func show<Content: View>(title: String, style: Style = .alert, content: Content, onUserClose: @escaping () -> Void) {
        close()
        self.style = style
        self.onUserClose = onUserClose
        // Borderless and transparent: the SwiftUI content draws its own glass card, like a
        // system notification. Buttons inside are the only way to dismiss it.
        var styleMask: NSWindow.StyleMask = [.borderless]
        if style == .banner { styleMask.insert(.nonactivatingPanel) }
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        // NSPanel hides itself whenever its app is inactive, which a menu bar app usually is.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        position()

        switch style {
        case .alert:
            // Activation is only a request since macOS 14; ordering front regardless keeps the
            // prompt visible even when another app keeps focus.
            NSApp.activate()
            panel.orderFrontRegardless()
            panel.makeKey()
        case .banner:
            panel.orderFrontRegardless()
        }
    }

    /// Closes programmatically, without calling `onUserClose`.
    func close() {
        onUserClose = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }

    private func position() {
        guard let panel else { return }
        switch style {
        case .alert:
            panel.center()
        case .banner:
            guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - Self.bannerMargin,
                y: visible.maxY - size.height - Self.bannerMargin
            ))
        }
    }

    // Content changes size (request → progress); keep the banner anchored to its corner.
    func windowDidResize(_ notification: Notification) {
        if style == .banner { position() }
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onUserClose
        onUserClose = nil
        panel = nil
        callback?()
    }
}
