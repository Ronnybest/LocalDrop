import AppKit
import SwiftUI

/// The menu bar drop: shows LocalDrop's state, opens the menu on click and takes files dropped
/// on it, like AirDrop in Finder. AppKit rather than MenuBarExtra, whose item can't be a drop target.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: MenuPanel?
    private var monitors: [Any] = []
    /// Opens the menu when files hover over the drop for a moment, so they can go onto one phone.
    private var springTask: Task<Void, Never>?

    private static let springDelay: Duration = .milliseconds(500)
    private static let cornerRadius: CGFloat = 18
    /// Between the menu bar and the top of the menu.
    private static let gap: CGFloat = 5

    init(model: AppModel) {
        self.model = model
        super.init()
        // Keeps the place the user ⌘-dragged it to.
        statusItem.autosaveName = "LocalDrop"
        guard let button = statusItem.button else { return }
        // VoiceOver presses the button itself; the drop view takes mouse clicks and drags.
        button.target = self
        button.action = #selector(togglePanel)
        let dropView = StatusDropView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.controller = self
        button.addSubview(dropView)
        updateIcon()
    }

    // MARK: Icon

    private func updateIcon() {
        withObservationTracking {
            let (image, label) = MenuBarIcon.current(model)
            statusItem.button?.image = image
            statusItem.button?.setAccessibilityLabel(label)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    // MARK: Menu panel

    @objc func togglePanel() {
        if panel != nil {
            closePanel()
        } else {
            openPanel(takingFocus: true)
        }
    }

    /// - Parameter takingFocus: false while a drag from another app is going on.
    private func openPanel(takingFocus: Bool) {
        guard panel == nil, let button = statusItem.button else { return }
        // The panel follows the content's height itself, a moment later and without animation.
        // NSHostingView sizing the window resized it from inside layout, and rendering the glass
        // there laid it out again, recursing until the stack overflowed (macOS 26).
        let content = MenuBarView(model: model)
            .background(PanelGlassBackground(cornerRadius: Self.cornerRadius))
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                DispatchQueue.main.async { self?.fit(size) }
            }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []

        let panel = MenuPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.closePanel() }
        self.panel = panel
        position(panel, below: button)

        if takingFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        button.highlight(true)
        watchClicksOutside()
    }

    func closePanel() {
        springTask?.cancel()
        springTask = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        statusItem.button?.highlight(false)
        // A drop waiting for a phone is abandoned with the menu.
        model.filesToSend = nil
    }

    /// Under the drop, left edges aligned like a menu, kept on screen.
    private func position(_ panel: NSPanel, below button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let item = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? item
        let size = panel.frame.size
        let x = min(max(item.minX, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(item.minY, visible.maxY) - Self.gap
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    }

    /// Content grows downwards: the top stays under the menu bar.
    private func fit(_ size: CGSize) {
        guard let panel, let button = statusItem.button, size.height > 0,
              abs(panel.frame.height - size.height) > 0.5 || abs(panel.frame.width - size.width) > 0.5 else { return }
        panel.setContentSize(size)
        position(panel, below: button)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Settings opened from the menu, or another window of this app clicked.
        closePanel()
    }

    /// Clicks in other apps close the menu, as do clicks in this app's other windows; the
    /// drop's own clicks toggle it instead.
    private func watchClicksOutside() {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if event.window !== panel && event.window !== self.statusItem.button?.window {
                    self.closePanel()
                }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    // MARK: Files dragged onto the drop

    fileprivate func dragEntered() -> Bool {
        guard !model.receivingPhones.isEmpty else { return false }
        statusItem.button?.highlight(true)
        guard panel == nil else { return true }
        springTask = Task { [weak self] in
            try? await Task.sleep(for: Self.springDelay)
            guard !Task.isCancelled else { return }
            self?.openPanel(takingFocus: false)
        }
        return true
    }

    fileprivate func dragExited() {
        springTask?.cancel()
        springTask = nil
        if panel == nil { statusItem.button?.highlight(false) }
    }

    fileprivate func dropped(_ urls: [URL]) {
        springTask?.cancel()
        springTask = nil
        openPanel(takingFocus: true)
        model.sendDropped(urls)
    }
}

/// Covers the status item button: clicks open the menu, files can be dropped on it.
private final class StatusDropView: NSView {
    weak var controller: StatusItemController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        controller?.togglePanel()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.togglePanel()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.files(in: sender).isEmpty || controller?.dragEntered() != true ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.files(in: sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        controller?.dragExited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = Self.files(in: sender)
        guard !files.isEmpty else { return false }
        controller?.dropped(files)
        return true
    }

    /// Regular files only: folders can't be sent.
    private static func files(in info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}

/// A borderless panel still takes keyboard focus (⌘, ⌘Q, Escape) when opened.
private final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
