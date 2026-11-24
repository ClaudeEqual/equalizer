import SwiftUI

@main
struct EqualizerApp: App {
    @StateObject private var model = EQModel()

    var body: some Scene {
        Window("Эквалайзер", id: "main") {
            EqualizerView(model: model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            EqualizerView(model: model, showsQuit: true)
        } label: {
            Image(systemName: model.isOn ? "slider.vertical.3" : "speaker.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
