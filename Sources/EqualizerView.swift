import SwiftUI
import AppKit
import ServiceManagement

private let bandWidth: CGFloat = 50
private let sliderHeight: CGFloat = 210

struct EqualizerView: View {
    @ObservedObject var model: EQModel
    var showsQuit = false

    @State private var isSaving = false
    @State private var newPresetName = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            presetGrid
            bandsSection
                .opacity(model.isOn ? 1 : 0.45)
            myPresets
            Divider()
            footer
        }
        .padding(20)
        .frame(width: bandWidth * CGFloat(EQModel.frequencies.count) + 40)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Эквалайзер").font(.title2.bold())
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: $model.isOn)
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .help(model.isOn ? "Выключить эквалайзер" : "Включить эквалайзер")
        }
    }

    // MARK: Presets

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(EQModel.builtIn) { preset in
                PresetButton(title: preset.name, selected: model.currentPresetName == preset.name) {
                    model.apply(preset)
                }
            }
        }
    }

    private var myPresets: some View {
        HStack(spacing: 8) {
            if isSaving {
                TextField("Название, например «Для наушников»", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Сохранить", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Отмена") { isSaving = false; newPresetName = "" }
            } else {
                Menu {
                    if model.userPresets.isEmpty {
                        Text("Пока нет своих пресетов")
                    } else {
                        ForEach(model.userPresets) { preset in
                            Button(preset.name) { model.apply(preset) }
                        }
                        Divider()
                        Menu("Удалить") {
                            ForEach(model.userPresets) { preset in
                                Button(preset.name) { model.deleteUserPreset(preset) }
                            }
                        }
                    }
                } label: {
                    Label(myPresetTitle, systemImage: "star")
                }
                .fixedSize()

                Button {
                    newPresetName = ""
                    isSaving = true
                } label: {
                    Label("Сохранить как свой", systemImage: "plus")
                }
                Spacer()
            }
        }
    }

    private var myPresetTitle: String {
        if let name = model.currentPresetName, model.userPresets.contains(where: { $0.name == name }) {
            return name
        }
        return "Мои пресеты"
    }

    private func save() {
        model.saveUserPreset(named: newPresetName)
        newPresetName = ""
        isSaving = false
    }

    // MARK: Bands

    private var bandsSection: some View {
        VStack(spacing: 6) {
            ZStack {
                // Zero line
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(height: 1)
                HStack(spacing: 0) {
                    ForEach(0..<EQModel.frequencies.count, id: \.self) { i in
                        BandSlider(value: $model.gains[i], label: EQModel.labels[i])
                            .frame(width: bandWidth)
                    }
                }
            }
            HStack(spacing: 0) {
                groupLabel("Низкие (бас)", bands: 3)
                groupLabel("Средние", bands: 4)
                groupLabel("Высокие", bands: 3)
            }
            Text("Тяните кружок вверх или вниз. Двойной клик по ползунку вернёт его в ноль.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func groupLabel(_ text: String, bands: Int) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.4))
                .frame(height: 2)
                .padding(.horizontal, 6)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(width: bandWidth * CGFloat(bands))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Toggle("Запускать при включении Mac", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button("Нет звука?") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .help("Откроет настройки: разрешите «Эквалайзеру» доступ к системному звуку")
            if showsQuit {
                Button("Выйти") { NSApp.terminate(nil) }
            }
        }
    }
}

// MARK: - Components

struct PresetButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct BandSlider: View {
    @Binding var value: Double
    let label: String

    private let range = EQModel.range
    private let knob: CGFloat = 20

    var body: some View {
        VStack(spacing: 4) {
            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == 0 ? Color.secondary : Color.primary)
                .frame(height: 12)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let y = yPosition(for: value, height: h)
                let y0 = yPosition(for: 0, height: h)
                ZStack {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 6, height: h - knob)
                        .position(x: w / 2, y: h / 2)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: max(abs(y - y0), 0))
                        .position(x: w / 2, y: (y + y0) / 2)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .frame(width: knob, height: knob)
                        .position(x: w / 2, y: y)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in value = valueFor(y: g.location.y, height: h) }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
            }
            .frame(height: sliderHeight)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var valueText: String {
        if value == 0 { return "0" }
        return String(format: "%+g", value)
    }

    private func yPosition(for v: Double, height h: CGFloat) -> CGFloat {
        let usable = h - knob
        let norm = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        return knob / 2 + (1 - CGFloat(norm)) * usable
    }

    private func valueFor(y: CGFloat, height h: CGFloat) -> Double {
        let usable = max(h - knob, 1)
        let norm = 1 - Double((y - knob / 2) / usable)
        let raw = range.lowerBound + norm * (range.upperBound - range.lowerBound)
        let stepped = (raw * 2).rounded() / 2 // 0.5 dB steps
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}
