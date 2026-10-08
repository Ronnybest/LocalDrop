import SwiftUI

/// What the pairing prompt shows. Observed by the SwiftUI content of the panel.
@Observable
final class PairingPrompt {
    enum Phase {
        case awaitingUser
        /// This Mac's user confirmed; the other device's user hasn't yet.
        case awaitingPeer
    }

    let entryId: UUID
    let peerDeviceId: String
    let peerName: String
    let code: String
    let keyChanged: Bool
    var phase: Phase = .awaitingUser

    init(entryId: UUID, peerDeviceId: String, peerName: String, code: String, keyChanged: Bool) {
        self.entryId = entryId
        self.peerDeviceId = peerDeviceId
        self.peerName = peerName
        self.code = code
        self.keyChanged = keyChanged
    }
}

/// Shows the pairing prompt in a floating panel.
final class PairingPanelController {
    private let panel = FloatingPanel()
    private var onDecision: ((Bool) -> Void)?
    private var prompt: PairingPrompt?

    func show(_ prompt: PairingPrompt, onDecision: @escaping (Bool) -> Void) {
        self.prompt = prompt
        self.onDecision = onDecision
        let content = PairingView(prompt: prompt) { [weak self] accepted in self?.decide(accepted) }
        panel.show(title: String(localized: "Pair with \(prompt.peerName)"), content: content) { [weak self] in
            // Closing the panel before deciding counts as declining.
            guard let self, self.prompt?.phase == .awaitingUser else { return }
            self.decide(false)
        }
    }

    func close() {
        onDecision = nil
        prompt = nil
        panel.close()
    }

    private func decide(_ accepted: Bool) {
        guard let onDecision else { return }
        if accepted {
            prompt?.phase = .awaitingPeer
        } else {
            self.onDecision = nil
        }
        onDecision(accepted)
    }
}

private struct PairingView: View {
    let prompt: PairingPrompt
    let decide: (Bool) -> Void

    var body: some View {
        VStack(spacing: 14) {
            IconBadge(symbol: prompt.keyChanged ? "exclamationmark.shield.fill" : "lock.shield.fill",
                      tint: prompt.keyChanged ? .orange : .accentColor, size: 60)

            Text("Pair with \(prompt.peerName)?")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            if prompt.keyChanged {
                Text("The security key of \(prompt.peerName) has changed. This happens after reinstalling LocalDrop — or if another device is impersonating it. Continue only if the device is in front of you.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Make sure \(prompt.peerName) shows the same code:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(prompt.code)
                .font(.system(size: 36, weight: .semibold, design: .monospaced))
                .textSelection(.disabled)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .glassCard(cornerRadius: 16)

            switch prompt.phase {
            case .awaitingUser:
                HStack(spacing: 12) {
                    Button { decide(false) } label: {
                        Text("Decline").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
                    Button { decide(true) } label: {
                        Text("Pair").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
                }
                .controlSize(.large)
            case .awaitingPeer:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for confirmation on \(prompt.peerName)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        .panelCard(width: 380, cornerRadius: 30)
    }
}
