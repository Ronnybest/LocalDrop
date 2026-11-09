import SwiftUI

/// Add a Mac: the Macs Bonjour sees on this network that aren't paired yet, then pairing.
struct AddMacView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        // A paired Mac is listed again when it no longer trusts this iPhone, or answers with
        // another key (Dewlet reinstalled on it): pairing again is what fixes both.
        let candidates = model.browser.macs.filter { browsed in
            guard let deviceId = browsed.deviceId, model.macs.contains(where: { $0.id == deviceId }) else { return true }
            switch model.links[deviceId]?.state {
            case .notPaired, .unreachable(.authenticationFailed): return true
            default: return false
            }
        }

        NavigationStack {
            List {
                Section {
                    Label("On your Mac, click the drop in the menu bar and turn on “Visible to new devices”.", systemImage: "menubar.arrow.up.rectangle")
                } footer: {
                    Text("A Mac with nothing paired yet is ready without it.")
                }

                Section {
                    if !model.browser.isAvailable {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Dewlet can’t look for Macs. Allow Local Network for Dewlet in Settings.", systemImage: "wifi.exclamationmark")
                            Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                                .buttonStyle(.bordered)
                        }
                    } else if candidates.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for Macs on this network…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(candidates) { browsed in
                        NavigationLink(value: browsed) {
                            Label(browsed.hostName ?? "Mac", systemImage: "laptopcomputer")
                        }
                    }
                } header: {
                    Text("Macs on this network")
                } footer: {
                    if candidates.count < model.browser.macs.count {
                        Text("Macs that are already paired aren’t listed.")
                    }
                }
            }
            .animation(.default, value: candidates)
            .animation(.default, value: model.browser.isAvailable)
            .navigationTitle("Add a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: BrowsedMac.self) { browsed in
                PairingView(model: model, target: browsed) { dismiss() }
            }
        }
        .modifier(IncomingOfferAlert(model: model))
        .onAppear { model.browser.start() }
        .onDisappear { model.browser.stop() }
    }
}

/// Pairing with one Mac: connect, compare the code on both screens, wait for the Mac's user.
/// Leaving the screen before the end declines and closes, so the Mac drops its prompt.
private struct PairingView: View {
    private enum Phase: Equatable {
        case connecting
        case comparing(code: String, keyChanged: Bool)
        /// Pair tapped here; the Mac's user hasn't answered yet.
        case confirmed(code: String, keyChanged: Bool)
        case paired
        case alreadyPaired
        case failed(ClientError)
    }

    let model: AppModel
    let target: BrowsedMac
    let done: () -> Void
    @State private var phase = Phase.connecting
    @State private var session: ClientSession?
    /// From `server_hello`; before it, the Bonjour host name.
    @State private var name: String?
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let macName = name ?? target.hostName ?? "Mac"
        Group {
            switch phase {
            case .connecting:
                ProgressView("Connecting to \(macName)…")
            case .comparing(let code, let keyChanged), .confirmed(let code, let keyChanged):
                ScrollView {
                    VStack(spacing: 18) {
                        Image(systemName: keyChanged ? "exclamationmark.shield.fill" : "lock.shield.fill")
                            .font(.system(size: 64))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                            .padding(.top, 32)
                        Text("Pair with \(macName)?")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        if keyChanged {
                            Label("The security key of \(macName) has changed. This happens after reinstalling Dewlet — or if another device is impersonating it. Continue only if the device is in front of you.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .symbolRenderingMode(.multicolor)
                        }
                        Text("Make sure \(macName) shows the same code:")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text(code)
                            .font(.system(size: 48, weight: .semibold, design: .monospaced))
                            .accessibilityLabel(code.map(String.init).joined(separator: " "))
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 12) {
                        if case .confirmed = phase {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Waiting for confirmation on \(macName)…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                withAnimation { phase = .confirmed(code: code, keyChanged: keyChanged) }
                                Task { await session?.confirmPairing() }
                            } label: {
                                Text("Pair")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        // Codes that differ, or second thoughts: leaving declines on the Mac too.
                        Button(role: .cancel) {
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .padding()
                }
            case .paired:
                ContentUnavailableView {
                    Label {
                        Text("Paired with \(macName)")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, options: .nonRepeating, value: macName)
                    }
                } description: {
                    Text("Share photos and files from any app and pick \(macName). To send to this iPhone, drag files to the right edge of the Mac’s screen.")
                } actions: {
                    Button("Done", action: done)
                        .buttonStyle(.borderedProminent)
                }
            case .alreadyPaired:
                ContentUnavailableView {
                    Label("\(macName) is already paired", systemImage: "checkmark.circle")
                } description: {
                    Text("It’s on the home screen, ready to send to.")
                } actions: {
                    Button("Done", action: done)
                        .buttonStyle(.borderedProminent)
                }
            case .failed(let error):
                ContentUnavailableView {
                    if error == .peerError(code: ErrorCode.pairingUnavailable) {
                        Label("Turn on “Visible to new devices”", systemImage: "eye.slash")
                    } else {
                        Label("Couldn’t pair", systemImage: "exclamationmark.triangle")
                    }
                } description: {
                    if error == .peerError(code: ErrorCode.pairingUnavailable) {
                        Text("On \(macName), click the drop in the menu bar and turn on “Visible to new devices”. Then try again.")
                    } else {
                        Text(error.message(macName: macName))
                    }
                } actions: {
                    Button("Try Again") { attempt += 1 }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(macName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(phase == .paired)
        .animation(.default, value: phase)
        .sensoryFeedback(trigger: phase) { _, new in
            switch new {
            case .paired: .success
            case .failed: .error
            default: nil
            }
        }
        .task(id: attempt) { await pair() }
        .onDisappear { abandon() }
    }

    private func pair() async {
        guard let phone = model.phone else { return }
        phase = .connecting
        let opened: ClientSession
        do {
            opened = try await ClientSession.open(to: .bonjour(instance: target.id), phone: phone, name: Phone.name, expected: nil)
        } catch {
            phase = .failed(error)
            return
        }
        guard !Task.isCancelled else {
            // The screen went away while connecting.
            await opened.close()
            return
        }
        name = opened.mac.name
        guard case .pairingRequired(let code, let keyChanged) = opened.status else {
            // This iPhone and the Mac already trust each other.
            await opened.close()
            phase = .alreadyPaired
            return
        }
        session = opened
        phase = .comparing(code: code, keyChanged: keyChanged)
        do {
            // Read from the start: the Mac's user may decline before this one taps.
            let paired = try await opened.pairingResult()
            session = nil
            await opened.close()
            // A Mac paired again: its link was waiting for a reason to retry.
            model.links[paired.id]?.poke()
            phase = .paired
        } catch {
            // Nil after abandon(): leaving the screen isn't a failure to show.
            guard session === opened else { return }
            session = nil
            phase = .failed(error)
        }
    }

    private func abandon() {
        guard let session else { return }
        self.session = nil
        Task {
            await session.declinePairing()
            await session.close()
        }
    }
}
