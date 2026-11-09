import SwiftUI

/// A paired Mac: how it is doing, the code to check the pair with, receiving, and Forget.
struct MacDetailsView: View {
    let model: AppModel
    let macId: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsForget = false

    var body: some View {
        if let mac = model.macs.first(where: { $0.id == macId }) {
            Form {
                Section {
                    LabeledContent("Name", value: mac.name)
                    if model.links[mac.id]?.state != .connected {
                        LabeledContent("Last seen", value: min(mac.lastSeen, .now).formatted(.relative(presentation: .named)))
                    }
                    Text(model.statusText(of: mac))
                        .foregroundStyle(.secondary)
                }

                if let phone = model.phone {
                    Section {
                        Text(PairVerification.code(phone.identity.publicKeyX963, mac.publicKey))
                            .font(.title2.monospacedDigit())
                            .textSelection(.enabled)
                    } header: {
                        Text("Verification code")
                    } footer: {
                        Text("Dewlet on the Mac shows the same code in Settings › Devices, under the shield next to this iPhone. If it ever differs, forget the Mac and pair again.")
                    }
                }

                // Only a Mac that sends to phones offers anything to accept.
                if mac.canSend {
                    Section {
                        Toggle("Receive without asking", isOn: Binding(
                            get: { mac.receiveAutomatically },
                            set: { on in
                                do {
                                    try MacStore.shared.setReceiveAutomatically(on, id: mac.id)
                                } catch {
                                    Log.app.error("Could not change receiving for \(mac.id, privacy: .public)")
                                }
                            }
                        ))
                    } footer: {
                        Text("Files from this Mac are saved right away. Text and links always go to the clipboard.")
                    }
                }

                Section {
                    Button("Forget This Mac", role: .destructive) { confirmsForget = true }
                        .confirmationDialog("Forget \(mac.name)?", isPresented: $confirmsForget, titleVisibility: .visible) {
                            Button("Forget", role: .destructive) {
                                do {
                                    try MacStore.shared.forget(mac.id)
                                    dismiss()
                                } catch {
                                    Log.app.error("Could not forget \(mac.id, privacy: .public)")
                                }
                            }
                        } message: {
                            Text("You’ll need to pair again before sending files to this Mac.")
                        }
                }
            }
            .navigationTitle(mac.name)
            .navigationBarTitleDisplayMode(.inline)
            .animation(.default, value: model.links[mac.id]?.state)
        }
    }
}
