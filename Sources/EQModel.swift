import Foundation
import Combine
import CoreAudio

struct Preset: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var gains: [Double]
}

final class EQModel: ObservableObject {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let range: ClosedRange<Double> = -12...12

    static let builtIn: [Preset] = [
        Preset(name: "Ровно", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Бас ↑ Верха ↓", gains: [6, 5, 4, 2, 0, 0, -1, -3, -5, -7]),
        Preset(name: "Больше баса", gains: [7, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Мягкий звук", gains: [0, 0, 0, 0, 0, 0, -2, -4, -6, -8]),
        Preset(name: "Больше высоких", gains: [0, 0, 0, 0, 0, 0, 1, 3, 4, 5]),
        Preset(name: "Голос", gains: [-4, -3, -1, 1, 3, 4, 4, 2, 0, -1]),
        Preset(name: "Кино", gains: [5, 4, 2, 0, 0, 1, 2, 2, 1, 0]),
        Preset(name: "Тихо ночью", gains: [-3, -2, 0, 1, 2, 2, 1, 0, -2, -3]),
    ]
    static let defaultPreset = builtIn[1]

    @Published var gains: [Double] {
        didSet {
            pushParameters()
            defaults.set(gains, forKey: "gains")
        }
    }

    @Published var isOn: Bool {
        didSet {
            guard oldValue != isOn else { return }
            defaults.set(isOn, forKey: "isOn")
            applyPower()
        }
    }

    @Published var userPresets: [Preset] {
        didSet {
            if let data = try? JSONEncoder().encode(userPresets) {
                defaults.set(data, forKey: "userPresets")
            }
        }
    }

    @Published private(set) var status = ""
    @Published private(set) var isError = false

    private let engine = SystemAudioEQ()
    private let defaults = UserDefaults.standard
    private var restartWork: DispatchWorkItem?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: "gains") as? [Double], saved.count == Self.frequencies.count {
            gains = saved
        } else {
            gains = Self.defaultPreset.gains
        }
        isOn = (defaults.object(forKey: "isOn") as? Bool) ?? true
        if let data = defaults.data(forKey: "userPresets"),
           let list = try? JSONDecoder().decode([Preset].self, from: data) {
            userPresets = list
        } else {
            userPresets = []
        }

        engine.onNeedsRestart = { [weak self] in self?.scheduleRestart() }
        listenForDeviceChanges()
        pushParameters()
        applyPower()
    }

    // MARK: - Presets

    var allPresets: [Preset] { Self.builtIn + userPresets }

    var currentPresetName: String? {
        allPresets.first { preset in
            zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.01 }
        }?.name
    }

    func apply(_ preset: Preset) {
        guard preset.gains.count == Self.frequencies.count else { return }
        gains = preset.gains
    }

    func saveUserPreset(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = Preset(name: name, gains: gains)
        if let i = userPresets.firstIndex(where: { $0.name == name }) {
            userPresets[i] = preset
        } else {
            userPresets.append(preset)
        }
    }

    func deleteUserPreset(_ preset: Preset) {
        userPresets.removeAll { $0.name == preset.name }
    }

    // MARK: - Audio

    private func pushParameters() {
        let sr = engine.sampleRate
        let targets = gains.map { min(max($0, Self.range.lowerBound), Self.range.upperBound) }

        // Neighbouring bands overlap, so the real sound differs from the slider values.
        // Adjust the filter gains until the response at each band matches its slider.
        var adjusted = targets
        for _ in 0..<12 {
            let c = Self.filters(adjusted, sampleRate: sr)
            for i in 0..<adjusted.count {
                let actual = Self.responseDB(c, at: Self.frequencies[i], sampleRate: sr)
                adjusted[i] = min(max(adjusted[i] + 0.8 * (targets[i] - actual), -24), 24)
            }
        }
        let coeffs = Self.filters(adjusted, sampleRate: sr)

        // Lower the overall level a bit when boosting, so the limiter rarely has to work.
        let maxBoost = max(0, targets.max() ?? 0)
        engine.processor.setParameters(coeffs, preampDB: -0.6 * maxBoost)
    }

    /// Lowest band is a bass shelf, highest a treble shelf, the rest are peaks.
    private static func filters(_ g: [Double], sampleRate sr: Double) -> [BiquadCoefficients] {
        var out: [BiquadCoefficients] = []
        for i in 0..<g.count {
            if i == 0 {
                out.append(makeBiquad(kind: .lowShelf, frequency: 45, gainDB: g[i], q: 0.707, sampleRate: sr))
            } else if i == g.count - 1 {
                out.append(makeBiquad(kind: .highShelf, frequency: 11_300, gainDB: g[i], q: 0.707, sampleRate: sr))
            } else {
                out.append(makeBiquad(kind: .peak, frequency: frequencies[i], gainDB: g[i], q: 1.41, sampleRate: sr))
            }
        }
        return out
    }

    /// Combined level (dB) of all filters at frequency f.
    private static func responseDB(_ filters: [BiquadCoefficients], at f: Double, sampleRate sr: Double) -> Double {
        let w = 2 * Double.pi * min(f, sr * 0.49) / sr
        let c1 = cos(w), s1 = -sin(w), c2 = cos(2 * w), s2 = -sin(2 * w)
        var power = 1.0
        for k in filters {
            let nr = k.b0 + k.b1 * c1 + k.b2 * c2
            let ni = k.b1 * s1 + k.b2 * s2
            let dr = 1 + k.a1 * c1 + k.a2 * c2
            let di = k.a1 * s1 + k.a2 * s2
            power *= (nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30)
        }
        return 10 * log10(max(power, 1e-30))
    }

    private func applyPower() {
        restartWork?.cancel()
        if isOn {
            do {
                try engine.start()
                pushParameters() // sample rate may have changed
                status = "Работает: \(engine.outputName)"
                isError = false
            } catch {
                status = error.localizedDescription
                isError = true
            }
        } else {
            engine.stop()
            status = "Выключен: звук идёт как обычно"
            isError = false
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
