import SwiftUI

@main
struct EqualizerApp: App {
    @StateObject private var model = EQModel()

    var body: some Scene {
        // Resizable main window: can be stretched or opened full screen (green button).
        Window("Эквалайзер", id: "main") {
            EqualizerView(model: model, fillsWindow: true)
        }
        .defaultSize(width: 640, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            EqualizerView(model: model, showsQuit: true)
        } label: {
            Image(systemName: model.isOn ? "slider.vertical.3" : "speaker.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
