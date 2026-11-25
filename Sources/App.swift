import SwiftUI

@main
struct EqualizerApp: App {
    @StateObject private var model = EQModel()

    var body: some Scene {
        // Resizable main window: can be stretched or opened full screen (green button).
        Window("Эквалайзер", id: "main") {
            EqualizerView(model: model)
        }
        .defaultSize(width: 1120, height: 820)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.isOn ? "slider.vertical.3" : "speaker.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
