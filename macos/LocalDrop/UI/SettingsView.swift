import SwiftUI

enum SettingsTab: Hashable {
    case general
    case devices
}

/// The Settings window: everything that isn't needed every day.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView(selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 })) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            DevicesSettings(model: model)
                .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                .tag(SettingsTab.devices)
        }
        .frame(width: 600, height: 520)
        .hiddenToolbarBackground()
    }
}

private extension View {
    /// macOS 15+ shows the toolbar's background on hover and when content is under it; the tab
    /// bar here sits on the window background like the rest of the page.
    @ViewBuilder
    func hiddenToolbarBackground() -> some View {
        if #available(macOS 15, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @AppStorage(DropZoneController.enabledKey) private var showsDropZone = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    Text(model.localDevice.name)
                }
                StatusRow(status: model.bluetoothStatus)
                StatusRow(status: model.networkStatus)
                if let slow = model.slowWiFiStatus {
                    StatusRow(status: slow)
                }
                if let fingerprint = model.fingerprint {
                    LabeledContent("Device key") {
                        Text(fingerprint.fingerprintDisplay)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("The name is this Mac's computer name; change it in System Settings › General › Sharing. Phones show the device key when pairing.")
                    .foregroundStyle(.secondary)
            }

            Section("Receiving") {
                SaveFolderRow(folder: model.saveFolder)
                LabeledContent("Notifications") {
                    if model.notifications.isAuthorized {
                        Text("On")
                    } else {
                        HStack {
                            Text("Off — results show in a window")
                                .foregroundStyle(.secondary)
                            Button("Turn On…") { NSWorkspace.shared.open(NotificationController.settingsURL) }
                        }
                    }
                }
            }

            Section {
                LabeledContent("Share menu") {
                    if model.shareMenu.isEnabled {
                        Text("Share menu on")
                    } else {
                        HStack {
                            Text("Share menu off")
                                .foregroundStyle(.secondary)
                            Button("Turn On…") { NSWorkspace.shared.open(ShareMenu.settingsURL) }
                        }
                    }
                }
                Toggle("Drop zone while dragging files", isOn: $showsDropZone)
            } header: {
                Text("Sending")
            } footer: {
                Text("Send files from Finder, Photos and other apps with Share › LocalDrop. While you drag files, your phones also appear at the right edge of the screen: drop the files on one.")
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open at Login", isOn: Binding(
                    get: { model.loginItem.isEnabled },
                    set: { model.loginItem.setEnabled($0) }
                ))
                if model.loginItem.requiresApproval {
                    Text("Allow LocalDrop in System Settings › General › Login Items.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.notifications.refreshAuthorization()
            model.loginItem.refresh()
            model.saveFolder.refresh()
            model.shareMenu.refresh()
        }
        // Back from System Settings with the switch turned on.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.shareMenu.refresh()
        }
    }
}

/// Where received files go, with a way to change it.
private struct SaveFolderRow: View {
    let folder: SaveFolder

    var body: some View {
        LabeledContent("Save files to") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder.current])
                    } label: {
                        Label(folder.displayName, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help(folder.current.path)
                    Button("Change…") { folder.choose() }
                    if folder.chosen != nil {
                        Button("Use Downloads") { folder.useDownloads() }
                    }
                }
                if folder.isUnavailable {
                    Text("Folder unavailable — saving to Downloads until it's back.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct DevicesSettings: View {
    let model: AppModel
    @State private var pendingForget: TrustedDevice?

    var body: some View {
        Form {
            Section {
                VisibilityRow(model: model)
            } footer: {
                Text("A new phone pairs once, after both screens show the same code. Paired devices find this Mac without it being visible.")
                    .foregroundStyle(.secondary)
            }

            let devices = model.deviceList
            Section {
                if devices.isEmpty {
                    Text("No devices yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { item in
                    DeviceDetailRow(
                        item: item,
                        forget: { pendingForget = $0 },
                        showPrompt: model.showPrompt,
                        setAcceptPolicy: model.setAcceptPolicy,
                        send: model.chooseFiles,
                        cancelDelivery: model.cancelDelivery
                    )
                    .sendsDroppedFiles(to: item, using: model.send)
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("The menu next to each device sets which files it can save here without asking. Text and links always go to the clipboard.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert(
            "Forget \(pendingForget?.deviceName ?? "")?",
            isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }),
            presenting: pendingForget
        ) { device in
            Button("Forget", role: .destructive) { model.forgetTrustedDevice(device.deviceId) }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("\(device.deviceName) will no longer be able to send to this Mac until it pairs again. A transfer in progress stops.")
        }
    }
}
