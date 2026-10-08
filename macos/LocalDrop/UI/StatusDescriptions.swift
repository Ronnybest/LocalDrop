import SwiftUI

/// One line of state: an icon, a title and what it means. Shared by the menu and Settings.
struct StatusDescription {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    /// False when everything is as it should be: the menu then doesn't show it.
    let needsAttention: Bool
}

extension AppModel {
    var bluetoothStatus: StatusDescription {
        let state = advertiser?.state ?? .idle
        let (symbol, tint, detail, attention): (String, Color, String, Bool) = switch state {
        case .idle: ("antenna.radiowaves.left.and.right", .secondary, String(localized: "Waiting for the network listener"), false)
        case .starting: ("antenna.radiowaves.left.and.right", .secondary, String(localized: "Starting…"), false)
        case .advertising: ("antenna.radiowaves.left.and.right", .green, String(localized: "Your devices can find this Mac nearby"), false)
        case .poweredOff: ("antenna.radiowaves.left.and.right.slash", .orange, String(localized: "Bluetooth is turned off. Phones can't find this Mac."), true)
        case .unauthorized: ("lock.fill", .orange, String(localized: "Allow LocalDrop in System Settings › Privacy & Security › Bluetooth."), true)
        case .unsupported: ("xmark.octagon.fill", .red, String(localized: "This Mac doesn't support Bluetooth LE advertising."), true)
        case .failed(let reason): ("exclamationmark.triangle.fill", .red, reason, true)
        }
        return StatusDescription(symbol: symbol, tint: tint, title: String(localized: "Bluetooth"), detail: detail, needsAttention: attention)
    }

    var networkStatus: StatusDescription {
        let (symbol, tint, detail, attention): (String, Color, String, Bool) = switch listener.state {
        case .stopped: ("network.slash", .secondary, String(localized: "Stopped"), true)
        case .starting: ("network", .secondary, String(localized: "Starting…"), false)
        case .ready where lanAddresses.isEmpty:
            ("wifi.slash", .orange, String(localized: "Not connected to Wi-Fi or Ethernet. Phones can't send until it is."), true)
        case .ready(let port):
            ("network", .green, "\(lanAddresses.joined(separator: ", ")) · port \(port)", false)
        case .waiting(let reason): ("network", .orange, reason, true)
        case .failed(let reason): ("exclamationmark.triangle.fill", .red, String(localized: "\(reason) — retrying"), true)
        }
        return StatusDescription(symbol: symbol, tint: tint, title: String(localized: "Local network"), detail: detail, needsAttention: attention)
    }

    /// On 2.4 GHz, files arrive at a few MB/s; shown only then.
    var slowWiFiStatus: StatusDescription? {
        guard wifiBand == .ghz2_4, !lanAddresses.isEmpty else { return nil }
        return StatusDescription(
            symbol: "tortoise.fill", tint: .orange, title: String(localized: "Slow Wi-Fi (2.4 GHz)"),
            detail: String(localized: "Files arrive at only a few MB/s on this network. A 5 GHz network — or your phone's 5 GHz hotspot — is many times faster."),
            needsAttention: true
        )
    }
}

struct StatusRow: View {
    let status: StatusDescription

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(symbol: status.symbol, tint: status.tint == .secondary ? .gray : status.tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                Text(status.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Pairing mode: the only time this Mac is discoverable by devices that aren't paired yet.
struct VisibilityRow: View {
    let model: AppModel

    var body: some View {
        if model.trustStore?.devices.isEmpty ?? true {
            StatusRow(status: StatusDescription(
                symbol: "plus.circle.fill", tint: .accentColor, title: String(localized: "Ready to pair"),
                detail: String(localized: "On your phone, open LocalDrop and tap “Add a Mac”."), needsAttention: true
            ))
        } else {
            // The switch is pinned to the trailing edge; a Toggle with a label would follow the
            // label's width, which changes with the countdown.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Visible to new devices")
                    // Both subtitles occupy the same single line, so switching never changes
                    // the card's (and the menu's) height.
                    ZStack(alignment: .leading) {
                        Text("Only paired devices see it").hidden()
                        Text("Open for pairing · 10:00").hidden()
                        if let until = model.pairingWindowUntil, until > Date() {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let remaining = max(0, Int(until.timeIntervalSince(context.date)))
                                Text("Open for pairing · \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                                    .monospacedDigit()
                            }
                        } else {
                            Text("Only paired devices see it")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle("Visible to new devices", isOn: Binding(
                    get: { model.isPairingModeActive },
                    set: { $0 ? model.openPairingWindow() : model.closePairingWindow() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .help("For 10 minutes, phones that aren't paired yet can find this Mac.")
        }
    }
}
