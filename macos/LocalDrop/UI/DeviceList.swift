import SwiftUI

/// One device in the lists: a trusted device, a connected device, or both.
struct DeviceListItem: Identifiable {
    enum Activity {
        case none
        case handshaking(remote: String)
        case connection(ConnectionEntry.State)
    }

    let id: String
    let name: String
    let platform: String?
    let fingerprint: Data?
    /// Trusted with the key it currently presents (or, when not connected, with its stored key).
    let isTrusted: Bool
    let trustedDevice: TrustedDevice?
    let activity: Activity
    /// Set while this device's incoming transfer is running.
    var receivingFraction: Double?
    var receivingTimeLeft: String?
    /// Connection entry with a pairing or transfer prompt waiting for the user.
    var pendingPromptEntryId: UUID?
    /// Files on their way to this device, if any.
    var delivery: OutgoingDelivery?

    /// A paired phone whose LocalDrop can receive from this Mac.
    var canReceive: Bool {
        isTrusted && trustedDevice?.capabilities?.contains(ProtocolConstants.receiveCapability) == true
    }
}

extension AppModel {
    /// Connected devices first (newest first), then the remaining trusted devices by last seen.
    var deviceList: [DeviceListItem] {
        rawDeviceList.map { item in
            var item = item
            item.delivery = delivery(for: item.id)
            return item
        }
    }

    private var rawDeviceList: [DeviceListItem] {
        let trusted = trustStore?.devices ?? []
        var items: [DeviceListItem] = []
        var listedDeviceIds = Set<String>()

        for entry in connections {
            guard let peer = entry.state.peer else {
                items.append(DeviceListItem(
                    id: entry.id.uuidString, name: entry.remote, platform: nil, fingerprint: nil,
                    isTrusted: false, trustedDevice: nil, activity: .handshaking(remote: entry.remote)
                ))
                continue
            }
            // Several entries can exist for one device (an ended session lingering next to a new one).
            guard listedDeviceIds.insert(peer.deviceId).inserted else { continue }
            let record = trusted.first { $0.deviceId == peer.deviceId }
            let transfer = incomingTransfer.flatMap { $0.entryId == entry.id && $0.phase == .receiving ? $0 : nil }
            items.append(DeviceListItem(
                id: peer.deviceId,
                name: peer.name,
                platform: peer.platform,
                fingerprint: peer.fingerprint,
                isTrusted: record?.publicKey == peer.identityKey,
                trustedDevice: record,
                activity: .connection(entry.state),
                receivingFraction: transfer?.fraction,
                receivingTimeLeft: transfer?.timeLeft,
                pendingPromptEntryId: hasPendingPrompt(for: entry.id) ? entry.id : nil
            ))
        }

        for record in trusted.sorted(by: { $0.lastSeen > $1.lastSeen }) where !listedDeviceIds.contains(record.deviceId) {
            items.append(DeviceListItem(
                id: record.deviceId, name: record.deviceName, platform: record.platform,
                fingerprint: record.fingerprint, isTrusted: true, trustedDevice: record, activity: .none
            ))
        }
        return items
    }
}

extension DeviceListItem {
    var symbol: String { platform == "macos" ? "desktopcomputer" : "smartphone" }

    /// What the device is doing now, or when it was last seen.
    var status: (tint: Color, text: String) {
        if let delivery {
            switch delivery.phase {
            case .waiting:
                return (.accentColor, String(localized: "Waiting to send \(delivery.title)"))
            case .awaitingAcceptance:
                return (.accentColor, String(localized: "Waiting for acceptance on the phone"))
            case .sending:
                let sending = String(localized: "Sending · \(Int(delivery.fraction * 100))%")
                return (.accentColor, delivery.timeLeft.map { sending + " · " + $0 } ?? sending)
            }
        }
        if let fraction = receivingFraction {
            let receiving = String(localized: "Receiving · \(Int(fraction * 100))%")
            return (.accentColor, receivingTimeLeft.map { receiving + " · " + $0 } ?? receiving)
        }
        switch activity {
        case .none:
            let lastSeen = trustedDevice?.lastSeen.formatted(.relative(presentation: .named)) ?? String(localized: "never")
            return (.secondary, String(localized: "Last seen \(lastSeen)"))
        case .handshaking(let remote):
            return (.secondary, String(localized: "Connecting from \(remote)…"))
        case .connection(let state):
            switch state {
            case .handshaking:
                return (.secondary, String(localized: "Connecting…"))
            case .pairing:
                return (.orange, String(localized: "Pairing — compare the code on both devices"))
            case .connected(_, let status):
                switch status {
                case .trusted: return (.green, String(localized: "Connected"))
                case .pairingRequired: return (.orange, String(localized: "Connected · not paired"))
                case .keyChanged: return (.red, String(localized: "Security key changed — pair again only if you trust this device"))
                }
            case .ended(_, nil):
                return (.secondary, String(localized: "Disconnected"))
            case .ended(_, let error?):
                return (.red, error.userMessage)
            }
        }
    }
}

/// A device in the menu: name and what it is doing. Details live in Settings › Devices.
struct DeviceSummaryRow: View {
    let item: DeviceListItem
    let showPrompt: (UUID) -> Void
    var send: ((String) -> Void)?
    var cancelDelivery: ((UUID) -> Void)?

    var body: some View {
        let status = item.status
        HStack(spacing: 10) {
            IconBadge(symbol: item.symbol, tint: status.tint == .secondary ? .gray : status.tint, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let entryId = item.pendingPromptEntryId {
                Button("Show") { showPrompt(entryId) }
                    .glassButton()
                    .help("Show the request window again")
            }
            DeliveryActions(item: item, send: send, cancelDelivery: cancelDelivery)
        }
    }
}

/// Send to a phone, or cancel what is on its way.
private struct DeliveryActions: View {
    let item: DeviceListItem
    let send: ((String) -> Void)?
    let cancelDelivery: ((UUID) -> Void)?

    var body: some View {
        if let delivery = item.delivery, let cancelDelivery {
            CircleButton(symbol: "xmark", help: String(localized: "Cancel sending")) { cancelDelivery(delivery.id) }
        } else if item.canReceive, let send {
            CircleButton(symbol: "paperplane", help: String(localized: "Send files to \(item.name)")) { send(item.id) }
        }
    }
}

extension View {
    /// Right-click on a phone: files, or what is on the clipboard (text and links land on the phone's clipboard).
    func sendMenu(for item: DeviceListItem, model: AppModel) -> some View {
        contextMenu {
            if item.canReceive {
                Button("Send Files…") { model.chooseFiles(for: item.id) }
                Button("Send Clipboard") { model.sendClipboard(to: item.id) }
            }
        }
    }

    /// Files dropped anywhere on a phone's row are sent to it; the row lights up while files hover over it.
    func sendsDroppedFiles(to item: DeviceListItem, using drop: @escaping ([URL], String) -> Void) -> some View {
        modifier(DropToSend(item: item, drop: drop))
    }
}

private struct DropToSend: ViewModifier {
    let item: DeviceListItem
    let drop: ([URL], String) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            // Spacers are transparent to drops without a shape.
            .contentShape(Rectangle())
            .background {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.15))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-4)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard item.canReceive, !files.isEmpty else { return false }
                drop(files, item.id)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted && item.canReceive
            }
    }
}

/// A device in Settings › Devices: one line with what it may send; the key and Forget on demand.
struct DeviceDetailRow: View {
    let item: DeviceListItem
    let forget: (TrustedDevice) -> Void
    let showPrompt: (UUID) -> Void
    let setAcceptPolicy: (AcceptPolicy, String) -> Void
    var send: ((String) -> Void)?
    var cancelDelivery: ((UUID) -> Void)?
    @State private var showsKey = false

    var body: some View {
        let status = item.status
        HStack(spacing: 12) {
            IconBadge(symbol: item.symbol, tint: status.tint == .secondary ? .gray : status.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if item.isTrusted {
                        Badge(text: String(localized: "Trusted"), color: .green)
                    }
                }
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let entryId = item.pendingPromptEntryId {
                Button("Show") { showPrompt(entryId) }
            }
            DeliveryActions(item: item, send: send, cancelDelivery: cancelDelivery)
            if item.isTrusted, let record = item.trustedDevice {
                Picker("Receive", selection: Binding(
                    get: { record.effectiveAcceptPolicy },
                    set: { setAcceptPolicy($0, record.deviceId) }
                )) {
                    ForEach(AcceptPolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Which files from \(record.deviceName) are saved without asking. Text and links always go to the clipboard, unless set to decline.")
            }
            if let fingerprint = item.fingerprint {
                Button {
                    showsKey.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Device key")
                .popover(isPresented: $showsKey, arrowEdge: .bottom) {
                    KeyPopover(name: item.name, fingerprint: fingerprint)
                }
            }
            if let record = item.trustedDevice {
                Menu {
                    Button("Forget \(record.deviceName)…", role: .destructive) { forget(record) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 4)
    }
}

/// The device key, for comparing with what the device itself shows.
private struct KeyPopover: View {
    let name: String
    let fingerprint: Data

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Device key of \(name)")
                .font(.headline)
            Text(fingerprint.fingerprintDisplay)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text("It matches the key shown in LocalDrop on that device. If it ever changes, LocalDrop asks to pair again instead of trusting it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: Capsule())
    }
}
