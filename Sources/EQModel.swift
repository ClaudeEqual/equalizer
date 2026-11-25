import Foundation
import AppKit
import Combine
import CoreAudio

// MARK: - Settings

enum EQMode: String, Codable { case graphic, parametric }

struct ParamBand: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: FilterKind
    var frequency: Double
    var gain: Double
    var q: Double
}

struct BassSettings: Codable, Equatable {
    var sub = 0.0     // ~40 Hz, the deepest rumble
    var punch = 0.0   // ~90 Hz, the kick
    var body = 0.0    // ~180 Hz, warmth and weight
    var mud = 0.0     // ~350 Hz, boominess (usually cut)
    var subsonic = true
}

struct SoundSettings: Codable, Equatable {
    var mode: EQMode = .graphic
    var bandCount: Int = 10
    var gains: [Double] = Array(repeating: 0, count: 10)
    var bands: [ParamBand] = SoundSettings.defaultBands
    var outputGain: Double = 0      // dB
    var bassPower: Double = 0       // 0...100 %
    var bass = BassSettings()
    var softProtection = false

    static let defaultBands: [ParamBand] = [
        ParamBand(kind: .lowShelf, frequency: 60, gain: 8, q: 0.7),
        ParamBand(kind: .peak, frequency: 110, gain: 4, q: 1.2),
        ParamBand(kind: .peak, frequency: 300, gain: -2, q: 1.4),
        ParamBand(kind: .peak, frequency: 3200, gain: 1, q: 1.0),
        ParamBand(kind: .highShelf, frequency: 10000, gain: 1, q: 0.7)
    ]
}

struct Preset: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var settings: SoundSettings
}

struct BassStyle {
    let name: String
    let sub: Double, punch: Double, body: Double, mud: Double
}

/// Small object for things that change many times a second (spectrum, level), so the rest of the UI does not redraw.
final class LiveData: ObservableObject {
    @Published var spectrum: [Double] = Array(repeating: -100, count: 96)
    @Published var levelDB: Double = -120
    @Published var clips: Int = 0
}

// MARK: - Model

final class EQModel: ObservableObject {
    static let gainRange: ClosedRange<Double> = -24...24
    static let bandCounts = [10, 15, 20, 31, 41]

    static let bassStyles: [BassStyle] = [
        BassStyle(name: "Глубокий саб", sub: 10, punch: 3, body: 0, mud: -2),
        BassStyle(name: "Удар (кик)", sub: 3, punch: 9, body: 2, mud: -3),
        BassStyle(name: "Тёплый", sub: 2, punch: 3, body: 6, mud: 0),
        BassStyle(name: "Плотный", sub: 6, punch: 6, body: 4, mud: -2),
        BassStyle(name: "Чистый", sub: 3, punch: 2, body: 0, mud: -5),
        BassStyle(name: "Клубный", sub: 12, punch: 8, body: 2, mud: -4)
    ]

    private static func factory(_ name: String, _ g: [Double], gain: Double = 0, power: Double = 0,
                                bass: BassSettings = BassSettings()) -> Preset {
        var s = SoundSettings()
        s.gains = g
        s.outputGain = gain
        s.bassPower = power
        s.bass = bass
        return Preset(name: name, settings: s)
    }

    static let builtIn: [Preset] = [
        factory("Ровно", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        factory("Бас ↑ Верха ↓", [6, 5, 4, 2, 0, 0, -1, -3, -5, -7]),
        factory("Мощный бас", [12, 10, 7, 3, 0, 0, 0, 1, 2, 2], gain: 2, power: 40,
                bass: BassSettings(sub: 4, punch: 4, body: 1, mud: -3, subsonic: true)),
        factory("Глубокий бас", [16, 12, 6, 1, 0, 0, 0, 1, 2, 2], gain: 2, power: 60,
                bass: BassSettings(sub: 8, punch: 2, body: 0, mud: -3, subsonic: true)),
        factory("Больше баса", [7, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
        factory("Больше высоких", [0, 0, 0, 0, 0, 0, 1, 3, 4, 5]),
        factory("Мягкий звук", [0, 0, 0, 0, 0, 0, -2, -4, -6, -8]),
        factory("Голос", [-4, -3, -1, 1, 3, 4, 4, 2, 0, -1]),
        factory("Громкость", [6, 4, 1, 0, -1, 0, 1, 3, 4, 5], gain: 3),
        factory("Кино", [6, 5, 3, 0, 0, 1, 2, 2, 1, 0], power: 20),
        factory("Ночь", [-3, -2, 0, 1, 2, 2, 1, 0, -2, -3]),
        factory("Игры", [5, 4, 1, -1, -1, 1, 3, 4, 3, 1], power: 20),
        factory("Рок", [5, 4, 2, -1, -2, 0, 2, 4, 5, 5]),
        factory("Поп", [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
        factory("Электроника", [8, 7, 3, 0, -2, 1, 0, 2, 4, 5], power: 30),
        factory("Хип-хоп", [9, 8, 4, 1, -1, -1, 1, 0, 2, 3], power: 40),
        factory("Джаз", [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        factory("Классика", [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        factory("Подкаст", [-6, -4, -1, 2, 3, 4, 3, 1, -1, -3])
    ]
    static let defaultPreset = builtIn[1]

    // MARK: Published state

    @Published var settings: SoundSettings {
        didSet {
            if !applyingPreset { activePreset = nil }
            pushParameters()
            save()
        }
    }

    @Published var isOn: Bool {
        didSet {
            guard oldValue != isOn else { return }
            UserDefaults.standard.set(isOn, forKey: "isOn")
            applyPower()
        }
    }

    @Published var comparing = false {
        didSet { engine.processor.setBypass(comparing) }
    }

    @Published var userPresets: [Preset] {
        didSet {
            if let data = try? JSONEncoder().encode(userPresets) {
                UserDefaults.standard.set(data, forKey: "presets.v2")
            }
        }
    }

    @Published var activePreset: String?
    @Published var selectedBand: UUID?
    @Published private(set) var status = ""
    @Published private(set) var isError = false
    @Published private(set) var needsPermission = false
    /// EQ + bass curve (dB) at `curveFrequencies`, for the graph.
    @Published private(set) var curve: [Double] = []

    let live = LiveData()
    static let curveFrequencies: [Double] = (0..<180).map { 20 * pow(1000, Double($0) / 179) }

    private let engine = SystemAudioEQ()
    private let analyzer = SpectrumAnalyzer()
    private var applyingPreset = false
    private var restartWork: DispatchWorkItem?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var permissionTimer: Timer?
    private var meterTimer: Timer?
    private var permissionGranted = false
    private var requestingPermission = false
    private var wakeObserver: NSObjectProtocol?

    init() {
        let d = UserDefaults.standard
        var loaded = SoundSettings()
        if let data = d.data(forKey: "settings.v2"),
           let s = try? JSONDecoder().decode(SoundSettings.self, from: data) {
            loaded = s
        } else if let old = d.array(forKey: "gains") as? [Double], old.count == 10 {
            loaded.gains = old // settings from version 1
        } else {
            loaded = Self.defaultPreset.settings
        }
        if !Self.bandCounts.contains(loaded.bandCount) || loaded.gains.count != loaded.bandCount {
            loaded.bandCount = 10
            loaded.gains = Array(repeating: 0, count: 10)
        }
        settings = loaded
        isOn = (d.object(forKey: "isOn") as? Bool) ?? true
        if let data = d.data(forKey: "presets.v2"),
           let list = try? JSONDecoder().decode([Preset].self, from: data) {
            userPresets = list
        } else {
            userPresets = []
        }

        engine.onNeedsRestart = { [weak self] in self?.scheduleRestart() }
        listenForDeviceChanges()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRestart() }
        pushParameters()
        applyPower()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.updateMeters()
        }
    }

    // MARK: Frequencies

    static func frequencies(for count: Int) -> [Double] {
        if count == 10 { return [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] }
        return (0..<count).map { 20 * pow(1000, Double($0) / Double(count - 1)) }
    }

    static func label(_ f: Double) -> String {
        if f >= 1000 {
            let k = (f / 100).rounded() / 10
            return k == k.rounded() ? "\(Int(k))K" : String(format: "%.1fK", k)
        }
        return "\(Int(f.rounded()))"
    }

    static func resample(_ gains: [Double], from: [Double], to: [Double]) -> [Double] {
        guard !gains.isEmpty, gains.count == from.count else { return Array(repeating: 0, count: to.count) }
        let lf = from.map { log($0) }
        return to.map { (f: Double) -> Double in
            let x = log(f)
            if x <= lf[0] { return gains[0] }
            if x >= lf[lf.count - 1] { return gains[gains.count - 1] }
            for i in 0..<(lf.count - 1) where x >= lf[i] && x <= lf[i + 1] {
                let t = (x - lf[i]) / (lf[i + 1] - lf[i])
                return ((gains[i] * (1 - t) + gains[i + 1] * t) * 2).rounded() / 2
            }
            return 0
        }
    }

    // MARK: Editing

    func setBandCount(_ n: Int) {
        guard Self.bandCounts.contains(n), n != settings.bandCount else { return }
        var s = settings
        s.gains = Self.resample(s.gains, from: Self.frequencies(for: s.bandCount), to: Self.frequencies(for: n))
        s.bandCount = n
        settings = s
    }

    func setMode(_ mode: EQMode) {
        guard mode != settings.mode else { return }
        settings.mode = mode
        if mode == .parametric, selectedBand == nil { selectedBand = settings.bands.first?.id }
    }

    func applyBassStyle(_ style: BassStyle) {
        var s = settings
        s.bass.sub = style.sub
        s.bass.punch = style.punch
        s.bass.body = style.body
        s.bass.mud = style.mud
        settings = s
    }

    func addBand(frequency: Double, gain: Double) {
        guard settings.bands.count < 10 else { return }
        let band = ParamBand(kind: .peak, frequency: min(max(frequency, 20), 20000),
                             gain: min(max(gain, -24), 24), q: 1.0)
        settings.bands.append(band)
        selectedBand = band.id
    }

    func removeSelectedBand() {
        guard let id = selectedBand, settings.bands.count > 1 else { return }
        settings.bands.removeAll { $0.id == id }
        selectedBand = settings.bands.first?.id
    }

    func updateBand(_ id: UUID, _ change: (inout ParamBand) -> Void) {
        guard let i = settings.bands.firstIndex(where: { $0.id == id }) else { return }
        var b = settings.bands[i]
        change(&b)
        b.frequency = min(max(b.frequency, 20), 20000)
        b.gain = min(max(b.gain, -24), 24)
        b.q = min(max(b.q, 0.1), 10)
        settings.bands[i] = b
    }

    // MARK: Presets

    func apply(_ preset: Preset, isUser: Bool) {
        applyingPreset = true
        var s = preset.settings
        if !isUser {
            // Factory presets keep the current band count and protection choice.
            let count = settings.bandCount
            s.gains = Self.resample(preset.settings.gains, from: Self.frequencies(for: 10), to: Self.frequencies(for: count))
            s.bandCount = count
            s.mode = .graphic
            s.bands = settings.bands
            s.softProtection = settings.softProtection
        }
        settings = s
        activePreset = preset.name
        applyingPreset = false
    }

    func saveUserPreset(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = Preset(name: name, settings: settings)
        if let i = userPresets.firstIndex(where: { $0.name == name }) {
            userPresets[i] = preset
        } else {
            userPresets.append(preset)
        }
        activePreset = name
    }

    func deleteUserPreset(_ preset: Preset) {
        userPresets.removeAll { $0.name == preset.name }
        if activePreset == preset.name { activePreset = nil }
    }

    // MARK: Audio parameters

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings.v2")
        }
    }

    /// The whole filter chain: subsonic cut, bass section, then the equalizer.
    private func buildFilters(sampleRate sr: Double) -> [BiquadCoefficients] {
        let s = settings
        var list: [BiquadCoefficients] = []
        if s.bass.subsonic {
            list.append(makeBiquad(kind: .highPass, frequency: 20, gainDB: 0, q: 0.707, sampleRate: sr))
        }
        let bassBands: [(Double, Double, Double)] = [(40, s.bass.sub, 1.0), (90, s.bass.punch, 1.4),
                                                     (180, s.bass.body, 1.2), (350, s.bass.mud, 1.4)]
        for (f, g, q) in bassBands where abs(g) >= 0.01 {
            list.append(makeBiquad(kind: .peak, frequency: f, gainDB: g, q: q, sampleRate: sr))
        }
        switch s.mode {
        case .graphic:
            list += graphicFilters(sampleRate: sr)
        case .parametric:
            for b in s.bands {
                list.append(makeBiquad(kind: b.kind, frequency: b.frequency, gainDB: b.gain, q: b.q, sampleRate: sr))
            }
        }
        return list
    }

    private static func graphicFilterSet(_ g: [Double], freqs: [Double], sampleRate sr: Double) -> [BiquadCoefficients] {
        let n = freqs.count
        let ratio = freqs[1] / freqs[0]
        let bw = log2(ratio)
        let q = sqrt(pow(2, bw)) / (pow(2, bw) - 1)
        var out: [BiquadCoefficients] = []
        for i in 0..<n {
            if i == 0 {
                out.append(makeBiquad(kind: .lowShelf, frequency: sqrt(freqs[0] * freqs[1]), gainDB: g[i], q: 0.707, sampleRate: sr))
            } else if i == n - 1 {
                out.append(makeBiquad(kind: .highShelf, frequency: sqrt(freqs[n - 2] * freqs[n - 1]), gainDB: g[i], q: 0.707, sampleRate: sr))
            } else {
                out.append(makeBiquad(kind: .peak, frequency: freqs[i], gainDB: g[i], q: q, sampleRate: sr))
            }
        }
        return out
    }

    private func graphicFilters(sampleRate sr: Double) -> [BiquadCoefficients] {
        let freqs = Self.frequencies(for: settings.bandCount)
        let targets = settings.gains.map { min(max($0, Self.gainRange.lowerBound), Self.gainRange.upperBound) }
        guard targets.count == freqs.count else { return [] }
        // Neighbouring bands overlap, so the real sound differs from the slider values.
        // Adjust the filter gains until the response at each band matches its slider.
        var adjusted = targets
        for _ in 0..<12 {
            let c = Self.graphicFilterSet(adjusted, freqs: freqs, sampleRate: sr)
            for i in 0..<adjusted.count {
                let actual = responseDB(c, at: freqs[i], sampleRate: sr)
                adjusted[i] = min(max(adjusted[i] + 0.8 * (targets[i] - actual), -30), 30)
            }
        }
        return Self.graphicFilterSet(adjusted, freqs: freqs, sampleRate: sr)
    }

    private func enhancerFilters(sampleRate sr: Double) -> [BiquadCoefficients] {
        [makeBiquad(kind: .lowPass, frequency: 120, gainDB: 0, q: 0.707, sampleRate: sr),
         makeBiquad(kind: .lowPass, frequency: 120, gainDB: 0, q: 0.707, sampleRate: sr),
         makeBiquad(kind: .highPass, frequency: 80, gainDB: 0, q: 0.707, sampleRate: sr),
         makeBiquad(kind: .lowPass, frequency: 450, gainDB: 0, q: 0.707, sampleRate: sr)]
    }

    private func pushParameters() {
        let sr = engine.sampleRate
        let filters = buildFilters(sampleRate: sr)
        engine.processor.setParameters(filters: filters,
                                       enhancer: enhancerFilters(sampleRate: sr),
                                       outputGainDB: settings.outputGain,
                                       bassPower: settings.bassPower / 100,
                                       softProtection: settings.softProtection)
        curve = Self.curveFrequencies.map { responseDB(filters, at: $0, sampleRate: sr) }
    }

    private func updateMeters() {
        guard engine.isRunning else {
            if live.levelDB > -120 { live.levelDB = -120 }
            return
        }
        let m = engine.processor.readMeters()
        live.levelDB = m.peakDB
        if m.clips != live.clips { live.clips = m.clips }
        live.spectrum = analyzer.analyze(engine.processor, sampleRate: engine.sampleRate, bins: live.spectrum.count)
    }

    // MARK: Power and permission

    private func applyPower() {
        restartWork?.cancel()
        permissionTimer?.invalidate()
        permissionTimer = nil
        if isOn && !permissionGranted {
            // Without access a tap gives silence and mutes the Mac, so never start it before access is given.
            switch AudioCapturePermission.status() {
            case .authorized:
                permissionGranted = true
            case .denied:
                engine.stop()
                showNoPermission()
                return
            case .unknown:
                guard !requestingPermission else { return }
                requestingPermission = true
                engine.stop()
                status = "Нажмите «Разрешить» в появившемся окне"
                isError = false
                AudioCapturePermission.request { [weak self] granted in
                    guard let self else { return }
                    self.requestingPermission = false
                    if granted {
                        self.permissionGranted = true
                        self.applyPower()
                    } else {
                        self.showNoPermission()
                    }
                }
                // If the system never answers, start anyway after 30 s: the tap then asks by itself.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, self.requestingPermission else { return }
                    self.requestingPermission = false
                    self.permissionGranted = true
                    self.applyPower()
                }
                return
            case .unavailable:
                break // cannot check: the system will ask by itself when the tap starts
            }
        }
        needsPermission = false
        if isOn {
            do {
                try engine.start()
                pushParameters() // sample rate may have changed
                engine.processor.setBypass(comparing)
                status = "Работает · \(engine.outputName)"
                isError = false
            } catch {
                status = error.localizedDescription
                isError = true
            }
        } else {
            engine.stop()
            status = "Выключен — звук идёт как обычно"
            isError = false
        }
    }

    private func showNoPermission() {
        status = "Нет доступа к звуку"
        isError = true
        needsPermission = true
        // Start by itself as soon as access is given in System Settings.
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.isOn {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.needsPermission = false
            } else if AudioCapturePermission.status() == .authorized {
                self.permissionGranted = true
                self.applyPower()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func scheduleRestart() {
        guard isOn else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyPower() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func listenForDeviceChanges() {
        var address = SystemAudioEQ.propAddr(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let newDevice = try? SystemAudioEQ.defaultOutputDevice()
            if newDevice != self.engine.outputDeviceID || !self.engine.isRunning {
                self.scheduleRestart()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        deviceListener = block
    }
}
