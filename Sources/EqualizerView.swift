import SwiftUI
import AppKit
import ServiceManagement

/// The main window: graphic (10/15/20/31/41 bands) or parametric equalizer, bass and power sections.
struct EqualizerView: View {
    @ObservedObject var model: EQModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderRow(model: model)
            ToolbarRow(model: model)
            PresetRow(model: model)
            HStack(alignment: .top, spacing: 18) {
                EditorPanel(model: model)
                ScrollView {
                    VStack(spacing: 12) {
                        PowerPanel(model: model)
                        BassPanel(model: model)
                        FooterPanel(model: model)
                    }
                }
                .frame(width: 300)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 980, maxWidth: .infinity, minHeight: 720, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .background(NoWindowDrag())
        .overlay {
            if model.needsPermission { AccessCard(model: model) }
        }
    }
}

// MARK: - Top

struct HeaderRow: View {
    @ObservedObject var model: EQModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Эквалайзер").font(.system(size: 24, weight: .bold))
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isError ? Theme.red : (model.isOn && !model.comparing ? Theme.green : Theme.muted))
                        .frame(width: 8, height: 8)
                    Text(model.comparing ? "Сейчас без эквалайзера — отпустите, чтобы вернуть" : model.status)
                        .font(.system(size: 13))
                        .foregroundStyle(model.isError ? Theme.red : Theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            CompareButton(model: model)
            PowerSwitch(isOn: $model.isOn)
        }
    }
}

struct CompareButton: View {
    @ObservedObject var model: EQModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path")
            Text(model.comparing ? "Без эквалайзера…" : "Удерживайте — сравнить")
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10).fill(model.comparing ? Theme.accent.opacity(0.25) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.comparing { model.comparing = true } }
                .onEnded { _ in model.comparing = false }
        )
        .help("Пока держите, звук идёт без эквалайзера: легко услышать разницу")
    }
}

struct ToolbarRow: View {
    @ObservedObject var model: EQModel

    var body: some View {
        HStack(spacing: 12) {
            Segmented(options: ["Графический", "Параметрический"],
                      selected: model.settings.mode == .graphic ? 0 : 1) { i in
                model.setMode(i == 0 ? .graphic : .parametric)
            }
            .fixedSize()
            if model.settings.mode == .graphic {
                HStack(spacing: 8) {
                    Text("Полос").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Segmented(options: EQModel.bandCounts.map { String($0) },
                              selected: EQModel.bandCounts.firstIndex(of: model.settings.bandCount) ?? 0) { i in
                        model.setBandCount(EQModel.bandCounts[i])
                    }
                    .fixedSize()
                }
            } else {
                Text("Тяните точки на графике. Двойной клик по пустому месту — новая точка (до 10).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer()
        }
    }
}

struct PresetRow: View {
    @ObservedObject var model: EQModel

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EQModel.builtIn) { p in
                        Chip(title: p.name, selected: model.activePreset == p.name) {
                            model.apply(p, isUser: false)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            Menu {
                if model.userPresets.isEmpty {
                    Text("Пока нет своих пресетов")
                } else {
                    ForEach(model.userPresets) { p in
                        Button(p.name) { model.apply(p, isUser: true) }
                    }
                    Divider()
                    Menu("Удалить") {
                        ForEach(model.userPresets) { p in
                            Button(p.name) { model.deleteUserPreset(p) }
                        }
                    }
                }
            } label: {
                Label(userPresetTitle, systemImage: "star")
            }
            .fixedSize()
        }
    }

    private var userPresetTitle: String {
        if let name = model.activePreset, model.userPresets.contains(where: { $0.name == name }) { return name }
        return "Мои пресеты"
    }
}

// MARK: - Editor (left)

struct EditorPanel: View {
    @ObservedObject var model: EQModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Как сейчас звучит").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.activePreset ?? "Своя настройка")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            CurveView(model: model, live: model.live)
                .frame(minHeight: model.settings.mode == .graphic ? 200 : 300)
                .frame(maxHeight: model.settings.mode == .graphic ? 260 : .infinity)
            if model.settings.mode == .graphic {
                GraphicBands(model: model)
            } else {
                ParametricEditor(model: model)
            }
        }
        .panel()
        .opacity(model.isOn ? 1 : 0.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct GraphicBands: View {
    @ObservedObject var model: EQModel

    var body: some View {
        let n = model.settings.bandCount
        let freqs = EQModel.frequencies(for: n)
        let every = n <= 10 ? 1 : (n <= 20 ? 2 : (n <= 31 ? 3 : 4))
        VStack(spacing: 6) {
            HStack(spacing: n > 20 ? 1 : 4) {
                ForEach(0..<n, id: \.self) { i in
                    BandSlider(value: binding(i),
                               label: i % every == 0 ? EQModel.label(freqs[i]) : "",
                               showValue: n <= 20)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            GeometryReader { geo in
                let wBand = geo.size.width / 10
                HStack(spacing: 0) {
                    groupLabel("Низкие (бас)", width: wBand * 3)
                    groupLabel("Средние", width: wBand * 4)
                    groupLabel("Высокие", width: wBand * 3)
                }
            }
            .frame(height: 22)
            Text("Тяните кружок. Двойной клик по ползунку — вернуть в ноль. Диапазон каждой полосы: от −24 до +24 дБ.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
    }

    private func binding(_ i: Int) -> Binding<Double> {
        Binding(
            get: { i < model.settings.gains.count ? model.settings.gains[i] : 0 },
            set: { v in if i < model.settings.gains.count { model.settings.gains[i] = v } }
        )
    }

    private func groupLabel(_ text: String, width: CGFloat) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.control).frame(height: 2).padding(.horizontal, 6)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .frame(width: max(width, 0))
    }
}

struct ParametricEditor: View {
    @ObservedObject var model: EQModel

    static let kinds: [(FilterKind, String)] = [(.peak, "Пик"), (.lowShelf, "Полка НЧ"), (.highShelf, "Полка ВЧ"),
                                                 (.highPass, "Срез НЧ"), (.lowPass, "Срез ВЧ")]

    static func kindName(_ k: FilterKind) -> String {
        kinds.first(where: { $0.0 == k })?.1 ?? ""
    }

    static func freqText(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.2f кГц", f / 1000) : String(format: "%.0f Гц", f)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.settings.bands.enumerated()), id: \.element.id) { i, b in
                        Chip(title: "\(i + 1) · \(Self.kindName(b.kind)) · \(Self.freqText(b.frequency))",
                             selected: b.id == model.selectedBand) {
                            model.selectedBand = b.id
                        }
                    }
                    if model.settings.bands.count < 10 {
                        Button("+ Точка") { model.addBand(frequency: 1000, gain: 0) }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(.vertical, 1)
            }
            if let id = model.selectedBand,
               let index = model.settings.bands.firstIndex(where: { $0.id == id }) {
                let band = model.settings.bands[index]
                HStack(spacing: 10) {
                    Text("Точка \(index + 1)").font(.system(size: 14, weight: .bold))
                    Segmented(options: Self.kinds.map { $0.1 },
                              selected: Self.kinds.firstIndex(where: { $0.0 == band.kind }) ?? 0,
                              compact: true) { i in
                        model.updateBand(id) { $0.kind = Self.kinds[i].0 }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Удалить точку") { model.removeSelectedBand() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(model.settings.bands.count <= 1)
                }
                HStack(alignment: .top, spacing: 18) {
                    ValueSlider(title: "Частота", valueText: Self.freqText(band.frequency),
                                value: bandValue(id, get: { log($0.frequency / 20) / log(1000) },
                                                 set: { $0.frequency = 20 * pow(1000, $1) }),
                                range: 0...1, step: 0.001)
                    ValueSlider(title: "Усиление",
                                valueText: (band.kind == .highPass || band.kind == .lowPass) ? "—" : dbText(band.gain),
                                value: bandValue(id, get: { $0.gain }, set: { $0.gain = $1 }),
                                range: -24...24, step: 0.5, resetValue: 0)
                    ValueSlider(title: "Ширина (Q)", valueText: String(format: "%.2f", band.q),
                                value: bandValue(id, get: { log($0.q / 0.1) / log(100) },
                                                 set: { $0.q = 0.1 * pow(100, $1) }),
                                range: 0...1, step: 0.005)
                }
            } else {
                Text("Выберите точку на графике или нажмите «+ Точка».")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            if model.selectedBand == nil { model.selectedBand = model.settings.bands.first?.id }
        }
    }

    private func bandValue(_ id: UUID, get: @escaping (ParamBand) -> Double,
                           set: @escaping (inout ParamBand, Double) -> Void) -> Binding<Double> {
        Binding(
            get: { model.settings.bands.first(where: { $0.id == id }).map(get) ?? 0 },
            set: { v in model.updateBand(id) { set(&$0, v) } }
        )
    }
}

// MARK: - Sidebar (right)

struct PowerPanel: View {
    @ObservedObject var model: EQModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Мощность").font(.system(size: 15, weight: .bold))
            ValueSlider(title: "Общее усиление", valueText: dbText(model.settings.outputGain),
                        value: $model.settings.outputGain, range: -24...24, step: 0.5, resetValue: 0,
                        hint: "Громче или тише всё сразу, до +24 дБ")
            ValueSlider(title: "Мощный бас", valueText: "\(Int(model.settings.bassPower.rounded()))%",
                        value: $model.settings.bassPower, range: 0...100, step: 1, resetValue: 0,
                        hint: "Плотность и глубина: бас слышен даже там, где наушники не тянут самые низы")
            VStack(alignment: .leading, spacing: 6) {
                Text("Защита от перегруза").font(.system(size: 13, weight: .semibold))
                Segmented(options: ["Выкл", "Мягкая"], selected: model.settings.softProtection ? 1 : 0, fill: true) { i in
                    model.settings.softProtection = i == 1
                }
                Text(model.settings.softProtection
                     ? "Громко и плотно: пики сглаживаются мягко, без треска"
                     : "Без ограничений: громкость упирается только в возможности Mac и наушников, можно до искажения")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Theme.border)
            LevelMeter(live: model.live, soft: model.settings.softProtection)
        }
        .panel()
    }
}

struct BassPanel: View {
    @ObservedObject var model: EQModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Бас").font(.system(size: 15, weight: .bold))
                Spacer()
                Menu("Стиль") {
                    ForEach(EQModel.bassStyles, id: \.name) { s in
                        Button(s.name) { model.applyBassStyle(s) }
                    }
                    Divider()
                    Button("Сбросить") {
                        model.applyBassStyle(BassStyle(name: "", sub: 0, punch: 0, body: 0, mud: 0))
                    }
                }
                .fixedSize()
            }
            ValueSlider(title: "Саб · 40 Гц", valueText: dbText(model.settings.bass.sub),
                        value: $model.settings.bass.sub, range: -24...24, resetValue: 0)
            ValueSlider(title: "Удар · 90 Гц", valueText: dbText(model.settings.bass.punch),
                        value: $model.settings.bass.punch, range: -24...24, resetValue: 0)
            ValueSlider(title: "Тело · 180 Гц", valueText: dbText(model.settings.bass.body),
                        value: $model.settings.bass.body, range: -24...24, resetValue: 0)
            ValueSlider(title: "Гул · 350 Гц", valueText: dbText(model.settings.bass.mud),
                        value: $model.settings.bass.mud, range: -24...24, resetValue: 0,
                        hint: "Если бас «бубнит» — убавьте")
            Toggle("Убрать инфразвук ниже 20 Гц", isOn: $model.settings.bass.subsonic)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
        }
        .panel()
    }
}

struct FooterPanel: View {
    @ObservedObject var model: EQModel
    @State private var saving = false
    @State private var newName = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if saving {
                TextField("Название, например «Для наушников»", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack {
                    Button("Сохранить", action: save)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Отмена") { saving = false; newName = "" }
                        .buttonStyle(GhostButtonStyle())
                }
            } else {
                Button {
                    newName = ""
                    saving = true
                } label: {
                    Label("Сохранить как свой пресет", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(GhostButtonStyle())
            }
            Toggle("Запускать при включении Mac", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Button("Нет звука?") { model.openPrivacySettings() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .help("Откроет настройки: разрешите «Equalizer» доступ к системному звуку")
        }
        .panel(padding: 14)
    }

    private func save() {
        model.saveUserPreset(named: newName)
        newName = ""
        saving = false
    }
}

// MARK: - No access

struct AccessCard: View {
    @ObservedObject var model: EQModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 14) {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.15)))
                Text("Нужен доступ к системному звуку")
                    .font(.system(size: 20, weight: .bold))
                Text("Без него эквалайзер не может менять звук Mac. Звук никуда не записывается и не отправляется.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Нажмите «Открыть настройки»")
                    Text("2. Найдите «Equalizer» в списке записи системного звука")
                    Text("3. Включите переключатель — эквалайзер запустится сам")
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(padding: 14)
                HStack(spacing: 10) {
                    Button("Открыть настройки") { model.openPrivacySettings() }
                        .buttonStyle(AccentButtonStyle())
                    Button("Выключить эквалайзер") { model.isOn = false }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(28)
            .frame(width: 480)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
        }
    }
}
