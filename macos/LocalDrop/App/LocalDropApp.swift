import AppKit
import SwiftUI

@main
struct LocalDropApp: App {
    @State private var model: AppModel
    @State private var statusItem: StatusItemController

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
        _statusItem = State(initialValue: StatusItemController(model: model))
    }

    var body: some Scene {
        // The menu bar item is AppKit (StatusItemController): MenuBarExtra's can't take dropped files.
        Settings {
            SettingsView(model: model)
        }
    }
}
