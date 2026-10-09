import AppKit
import SwiftUI

@main
struct LocalDropApp: App {
    @State private var model: AppModel
    @State private var dropZone: DropZoneController

    init() {
        // MenuBarExtra content is built lazily, so services start here, at launch.
        let model = AppModel()
        // Hosting unit tests: no Bluetooth, network or panels next to the running LocalDrop.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            model.start()
        }
        _model = State(initialValue: model)
        _dropZone = State(initialValue: DropZoneController(model: model))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            let icon = MenuBarIcon.current(model)
            Image(nsImage: icon.image)
                .accessibilityLabel(icon.label)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
