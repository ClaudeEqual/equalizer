import SwiftUI
import AppKit

/// Compact panel under the menu bar icon.
struct MenuBarView: View {
    @ObservedObject var model: EQModel
    @Environment(\.openWindow) private var openWindow

    static let quick = ["Мощный бас", "Глубокий бас", "Бас ↑ Верха ↓", "Ровно", "Голос", "Кино"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Эквалайзер").font(.system(size: 16, weight: .bold))
                    Text(model.status)
                        .font(.system(size: 12))
                        .foregroundStyle(model.isError ? Theme.red : Theme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                PowerSwitch(isOn: $model.isOn, big: false)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Self.quick, id: \.self) { name in
                    if let p = EQModel.builtIn.first(where: { $0.name == name }) {
                        Button {
                            model.apply(p, isUser: false)
                        } label: {
                            Text(name)
                                .font(.system(size: 13, weight: model.activePreset == name ? .semibold : .regular))
                                .foregroundStyle(model.activePreset == name ? Theme.onAccent : Theme.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: 9).fill(model.activePreset == name ? Theme.accent : Theme.panel))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.activePreset == name ? Theme.accent : Theme.border, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Menu("Все пресеты") {
                ForEach(EQModel.builtIn) { p in
                    Button(p.name) { model.apply(p, isUser: false) }
                }
                if !model.userPresets.isEmpty {
                    Divider()
                    ForEach(model.userPresets) { p in
                        Button(p.name) { model.apply(p, isUser: true) }
                    }
                }
            }

            ValueSlider(title: "Общее усиление", valueText: dbText(model.settings.outputGain),
                        value: $model.settings.outputGain, range: -24...24, step: 0.5, resetValue: 0)
            ValueSlider(title: "Мощный бас", valueText: "\(Int(model.settings.bassPower.rounded()))%",
                        value: $model.settings.bassPower, range: 0...100, step: 1, resetValue: 0)

            HStack {
                Text("Защита от перегруза").font(.system(size: 12, weight: .semibold))
                Spacer()
                Segmented(options: ["Выкл", "Мягкая"], selected: model.settings.softProtection ? 1 : 0, compact: true) { i in
                    model.settings.softProtection = i == 1
                }
                .fixedSize()
            }

            LevelMeter(live: model.live, soft: model.settings.softProtection, compact: true)

            Divider().overlay(Theme.border)

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Открыть эквалайзер").frame(maxWidth: .infinity)
                }
                .buttonStyle(GhostButtonStyle())
                Button("Выйти") { NSApp.terminate(nil) }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .background(NoWindowDrag())
    }
}
