import SwiftUI

/// The menu bar popover: what's happening now and the few things used every day. Everything
/// else is in Settings.
struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    private static let recentDeviceCount = 3

    var body: some View {
        GlassGroup(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                header
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)

                if model.startupState == .running {
                    VisibilityRow(model: model)
                        // Full width, so the card doesn't resize as its subtitle changes.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .glassCard()
                }

                ForEach(Array(problems.enumerated()), id: \.offset) { _, status in
                    StatusRow(status: status)
                        .padding(12)
                        .glassCard(tint: status.tint)
                }
                if model.startupState == .running, !model.notifications.isAuthorized {
                    notificationsOffRow
                        .padding(12)
                        .glassCard(tint: .orange)
                }

                if model.startupState == .running, !model.shareMenu.isEnabled, model.deviceList.contains(where: \.canReceive) {
                    shareMenuOffRow
                        .glassCard(tint: .accentColor)
                }

                if let transfer = model.incomingTransfer, transfer.phase == .receiving {
                    ReceivingRow(transfer: transfer) { model.showPrompt(for: transfer.entryId) }
                        .padding(12)
                        .glassCard(tint: .accentColor)
                }

                let devices = model.deviceList
                if !devices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Devices")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("All Devices") { showSettings(.devices) }
                                .buttonStyle(.link)
                        }
                        .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            let recent = Array(devices.prefix(Self.recentDeviceCount))
                            ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                                DeviceSummaryRow(item: item, showPrompt: model.showPrompt,
                                                 send: model.chooseFiles, cancelDelivery: model.cancelDelivery)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                    .sendsDroppedFiles(to: item, using: model.send)
                                if index < recent.count - 1 {
                                    Divider().padding(.leading, 54)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .glassCard()
                    }
                }

                HStack(spacing: 10) {
                    Button { showSettings(.general) } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .keyboardShortcut(",")
                    Button { NSApplication.shared.terminate(nil) } label: {
                        Label("Quit", systemImage: "power")
                            .labelStyle(.iconOnly)
                            // 17 pt makes the circle exactly as tall as the Settings button.
                            .frame(width: 17, height: 17)
                    }
                    .glassButton()
                    .buttonBorderShape(.circle)
                    .keyboardShortcut("q")
                    .help(String(localized: "Quit LocalDrop"))
                }
                .controlSize(.large)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 330)
        .task {
            // The menu is where users look after changing System Settings; show the current state.
            await model.notifications.refreshAuthorization()
            model.loginItem.refresh()
            model.saveFolder.refresh()
            model.shareMenu.refresh()
        }
    }

    private var header: some View {
        let (tint, text) = summary
        return HStack(spacing: 12) {
            IconBadge(symbol: "laptopcomputer", tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.localDevice.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One line: "all good", or the main thing that isn't. Details are in the cards below.
    private var summary: (Color, String) {
        switch model.startupState {
        case .loadingIdentity: return (.orange, String(localized: "Starting…"))
        case .failed: return (.red, String(localized: "Can't start"))
        case .running: break
        }
        if let transfer = model.incomingTransfer, transfer.phase == .receiving {
            return (.accentColor, String(localized: "Receiving from \(transfer.peerName)"))
        }
        if model.bluetoothStatus.needsAttention { return (.orange, String(localized: "Bluetooth unavailable")) }
        if model.listener.port == nil || model.lanAddresses.isEmpty { return (.orange, String(localized: "No Wi-Fi network")) }
        if model.slowWiFiStatus != nil { return (.orange, String(localized: "Slow Wi-Fi")) }
        return (.green, String(localized: "All good"))
    }

    /// Only what needs the user's attention; the full state is in Settings › General.
    private var problems: [StatusDescription] {
        switch model.startupState {
        case .loadingIdentity:
            return [StatusDescription(symbol: "key.fill", tint: .orange, title: String(localized: "Waiting for Keychain access…"),
                                      detail: String(localized: "If macOS asks, allow LocalDrop to use its device key (Always Allow)."), needsAttention: true)]
        case .failed(let reason):
            return [StatusDescription(symbol: "exclamationmark.triangle.fill", tint: .red, title: String(localized: "LocalDrop can't start"),
                                      detail: reason, needsAttention: true)]
        case .running:
            var list = [model.bluetoothStatus, model.networkStatus].filter(\.needsAttention)
            if let slow = model.slowWiFiStatus { list.append(slow) }
            if let error = model.trustStoreError {
                list.append(StatusDescription(symbol: "exclamationmark.triangle.fill", tint: .red,
                                              title: String(localized: "Trusted devices unavailable"), detail: error, needsAttention: true))
            }
            return list
        }
    }

    private var notificationsOffRow: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(symbol: "bell.slash.fill", tint: .orange, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off")
                Text("Results will show in a window instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Turn On") { NSWorkspace.shared.open(NotificationController.settingsURL) }
                .glassButton()
        }
    }

    /// Until the user turns it on: macOS doesn't let an app add itself to Share menus.
    /// The whole card opens the switch in System Settings, so the text keeps the full width.
    private var shareMenuOffRow: some View {
        Button { NSWorkspace.shared.open(ShareMenu.settingsURL) } label: {
            HStack(spacing: 10) {
                IconBadge(symbol: "square.and.arrow.up", tint: .accentColor, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add LocalDrop to Share")
                    Text("Send to your phone from Finder, Photos and other apps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // Inside the button, so the card's edges are clickable too.
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Opens System Settings: turn on LocalDrop in the list"))
    }

    private func showSettings(_ tab: SettingsTab) {
        model.settingsTab = tab
        // A menu bar app has no active window; bring Settings to the front.
        NSApp.activate()
        openSettings()
    }
}

/// An incoming transfer in progress, so it can be found again once its window is closed.
private struct ReceivingRow: View {
    let transfer: IncomingTransfer
    let show: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "arrow.down", tint: .accentColor, size: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(transfer.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: transfer.fraction)
            }
            Button("Show", action: show)
                .glassButton()
        }
    }
}
