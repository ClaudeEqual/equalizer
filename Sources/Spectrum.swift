import Foundation
import Accelerate

/// Turns the latest output samples into a live spectrum (dB per band, 20 Hz – 20 kHz, log spaced).
final class SpectrumAnalyzer {
    static let size = 2048
    private let setup: vDSP_DFT_Setup?
    private var window: [Float]
    private var samples: [Float]
    private var inReal: [Float]
    private var inImag: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var smoothed: [Double] = []

    init() {
        let n = Self.size
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        samples = [Float](repeating: 0, count: n)
        inReal = [Float](repeating: 0, count: n / 2)
        inImag = [Float](repeating: 0, count: n / 2)
        outReal = [Float](repeating: 0, count: n / 2)
        outImag = [Float](repeating: 0, count: n / 2)
    }

    deinit {
        if let setup { vDSP_DFT_DestroySetup(setup) }
    }

    /// Returns `bins` levels in dB (about −100…0).
    func analyze(_ processor: EQProcessor, sampleRate: Double, bins: Int) -> [Double] {
        guard let setup else { return [Double](repeating: -100, count: bins) }
        let n = Self.size
        processor.copyRecentSamples(into: &samples)
        for i in 0..<(n / 2) {
            inReal[i] = samples[2 * i] * window[2 * i]
            inImag[i] = samples[2 * i + 1] * window[2 * i + 1]
        }
        vDSP_DFT_Execute(setup, inReal, inImag, &outReal, &outImag)

        let binHz = sampleRate / Double(n)
        let norm = Double(n) / 2
        var result = [Double](repeating: -100, count: bins)
        for b in 0..<bins {
            let fLo = 20 * pow(1000, Double(b) / Double(bins))
            let fHi = 20 * pow(1000, Double(b + 1) / Double(bins))
            var k0 = max(1, Int(fLo / binHz))
            var k1 = min(n / 2 - 1, Int(fHi / binHz))
            if k1 < k0 { k1 = k0 }
            if k0 > n / 2 - 1 { k0 = n / 2 - 1; k1 = k0 }
            var mag: Float = 0
            for k in k0...k1 {
                let m = outReal[k] * outReal[k] + outImag[k] * outImag[k]
                if m > mag { mag = m }
            }
            let db = 10 * log10(max(Double(mag), 1e-20)) - 20 * log10(norm)
            result[b] = max(-100, min(6, db))
        }
        // Fast rise, slow fall, so the display does not flicker.
        if smoothed.count != bins { smoothed = result }
        for b in 0..<bins {
            smoothed[b] = result[b] > smoothed[b] ? result[b] : smoothed[b] * 0.8 + result[b] * 0.2
        }
        return smoothed
    }
}
