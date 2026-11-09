import Photos
import SwiftUI

/// Everything that isn't needed every day.
struct SettingsView: View {
    private static let privacyPolicy = URL(string: "https://ronnybest.github.io/LocalDrop/privacy/")!
    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()
    /// Files › On My iPhone › Dewlet.
    private static let receivedFiles = URL(string: "shareddocuments://" + URL.documentsDirectory.path(percentEncoded: true))!

    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var name = Phone.name
    @AppStorage(AppModel.savesToPhotosKey) private var savesToPhotos = true

    var body: some View {
        let photosDenied = [.denied, .restricted].contains(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        NavigationStack {
            Form {
                Section {
                    TextField("Name on your Mac", text: $name, prompt: Text(verbatim: UIDevice.current.name))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onChange(of: name) { _, new in Phone.name = new }
                } header: {
                    Text("Name on your Mac")
                } footer: {
                    Text("Your Macs show this iPhone under this name, from the next time it connects.")
                }

                Section {
                    Toggle("Save photos and videos to Photos", isOn: $savesToPhotos.animation())
                    if savesToPhotos && photosDenied {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Dewlet isn’t allowed to add to Photos, so photos and videos stay in Files.", systemImage: "exclamationmark.triangle")
                            Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                                .buttonStyle(.bordered)
                        }
                    }
                    Button("Show Received Files", systemImage: "folder") { openURL(Self.receivedFiles) }
                } header: {
                    Text("Receiving")
                } footer: {
                    Text("Received files are in the Files app › On My iPhone › Dewlet. Text and links go to the clipboard.")
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    Link("Privacy Policy", destination: Self.privacyPolicy)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .modifier(IncomingOfferAlert(model: model))
    }
}
