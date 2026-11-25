import Foundation
import CoreAudio
import os

// MARK: - Biquad filter math (RBJ Audio EQ Cookbook)

struct BiquadCoefficients: Equatable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

enum FilterKind: String, Codable, CaseIterable {
    case peak, lowShelf, highShelf, highPass, lowPass
}

func makeBiquad(kind: FilterKind, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
    guard sampleRate > 0 else { return .identity }
    let usesGain = kind == .peak || kind == .lowShelf || kind == .highShelf
    if usesGain && abs(gainDB) < 0.01 { return .identity }
    let a = pow(10.0, gainDB / 40.0)
    let freq = min(max(frequency, 5), sampleRate * 0.45)
    let w0 = 2.0 * Double.pi * freq / sampleRate
    let cosw = cos(w0)
    let sinw = sin(w0)
    let alpha = sinw / (2.0 * max(q, 0.05))

    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
    switch kind {
    case .peak:
        b0 = 1 + alpha * a
        b1 = -2 * cosw
        b2 = 1 - alpha * a
        a0 = 1 + alpha / a
        a1 = -2 * cosw
        a2 = 1 - alpha / a
    case .lowShelf:
        let sq = 2 * sqrt(a) * alpha
        b0 = a * ((a + 1) - (a - 1) * cosw + sq)
        b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
        b2 = a * ((a + 1) - (a - 1) * cosw - sq)
        a0 = (a + 1) + (a - 1) * cosw + sq
        a1 = -2 * ((a - 1) + (a + 1) * cosw)
        a2 = (a + 1) + (a - 1) * cosw - sq
    case .highShelf:
        let sq = 2 * sqrt(a) * alpha
        b0 = a * ((a + 1) + (a - 1) * cosw + sq)
        b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
        b2 = a * ((a + 1) + (a - 1) * cosw - sq)
        a0 = (a + 1) - (a - 1) * cosw + sq
        a1 = 2 * ((a - 1) - (a + 1) * cosw)
        a2 = (a + 1) - (a - 1) * cosw - sq
    case .highPass:
        b0 = (1 + cosw) / 2
        b1 = -(1 + cosw)
        b2 = (1 + cosw) / 2
        a0 = 1 + alpha
        a1 = -2 * cosw
        a2 = 1 - alpha
    case .lowPass:
        b0 = (1 - cosw) / 2
        b1 = 1 - cosw
        b2 = (1 - cosw) / 2
        a0 = 1 + alpha
        a1 = -2 * cosw
        a2 = 1 - alpha
    }
    return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
}

/// Combined level (dB) of a chain of filters at frequency f.
func responseDB(_ filters: [BiquadCoefficients], at f: Double, sampleRate sr: Double) -> Double {
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

// MARK: - Real-time processor

/// Stereo chain: up to 64 filters + harmonic bass enhancer + output gain + protection (off = hard clip, soft = soft clip).
/// `process` runs on the Core Audio real-time thread: no allocations, no blocking locks.
final class EQProcessor {
    static let maxFilters = 64
    static let enhancerFilters = 4
    static let spectrumSize = 4096

    // Parameter layout: [0] filter count, [1] output gain (linear), [2] bass power 0...1, [3] protection (0 off, 1 soft),
    // then maxFilters * 5 coefficients, then enhancerFilters * 5 coefficients.
    private static let headerCount = 4
    private static let chainOffset = headerCount
    private static let enhancerOffset = headerCount + maxFilters * 5
    private static let paramCount = enhancerOffset + enhancerFilters * 5
    private static let chainStateCount = 2 * maxFilters * 2
    private static let enhancerStateCount = enhancerFilters * 2

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let pending: UnsafeMutablePointer<Double>
    private let pendingFlag: UnsafeMutablePointer<Bool>
    private let target: UnsafeMutablePointer<Double>
    private let current: UnsafeMutablePointer<Double>
    private let chainState: UnsafeMutablePointer<Double>
    private let enhState: UnsafeMutablePointer<Double>
    private let bypassFlag: UnsafeMutablePointer<Bool>
    /// [0] decaying peak level (linear, before protection), [1] number of samples that went over full scale
    private let meters: UnsafeMutablePointer<Double>
    private let ring: UnsafeMutablePointer<Float>
    private let ringIndex: UnsafeMutablePointer<Int>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending = .allocate(capacity: Self.paramCount)
        pending.initialize(repeating: 0, count: Self.paramCount)
        pendingFlag = .allocate(capacity: 1)
        pendingFlag.initialize(to: false)
        target = .allocate(capacity: Self.paramCount)
        target.initialize(repeating: 0, count: Self.paramCount)
        current = .allocate(capacity: Self.paramCount)
        current.initialize(repeating: 0, count: Self.paramCount)
        chainState = .allocate(capacity: Self.chainStateCount)
        chainState.initialize(repeating: 0, count: Self.chainStateCount)
        enhState = .allocate(capacity: Self.enhancerStateCount)
        enhState.initialize(repeating: 0, count: Self.enhancerStateCount)
        bypassFlag = .allocate(capacity: 1)
        bypassFlag.initialize(to: false)
        meters = .allocate(capacity: 2)
        meters.initialize(repeating: 0, count: 2)
        ring = .allocate(capacity: Self.spectrumSize)
        ring.initialize(repeating: 0, count: Self.spectrumSize)
        ringIndex = .allocate(capacity: 1)
        ringIndex.initialize(to: 0)

        Self.writeDefaults(into: target)
        Self.writeDefaults(into: current)
    }

    deinit {
        lock.deallocate()
        pending.deallocate()
        pendingFlag.deallocate()
        target.deallocate()
        current.deallocate()
        chainState.deallocate()
        enhState.deallocate()
        bypassFlag.deallocate()
        meters.deallocate()
        ring.deallocate()
        ringIndex.deallocate()
    }

    private static func writeDefaults(into p: UnsafeMutablePointer<Double>) {
        for i in 0..<paramCount { p[i] = 0 }
        p[1] = 1
        for b in 0..<(maxFilters + enhancerFilters) {
            p[chainOffset + b * 5] = 1
        }
    }

    // MARK: Main-thread API

    func setParameters(filters: [BiquadCoefficients], enhancer: [BiquadCoefficients],
                       outputGainDB: Double, bassPower: Double, softProtection: Bool) {
        let count = min(filters.count, Self.maxFilters)
        os_unfair_lock_lock(lock)
        pending[0] = Double(count)
        pending[1] = pow(10.0, outputGainDB / 20.0)
        pending[2] = min(max(bassPower, 0), 1)
        pending[3] = softProtection ? 1 : 0
        for b in 0..<Self.maxFilters {
            let c = b < count ? filters[b] : .identity
            let o = Self.chainOffset + b * 5
            pending[o] = c.b0; pending[o + 1] = c.b1; pending[o + 2] = c.b2
            pending[o + 3] = c.a1; pending[o + 4] = c.a2
        }
        for b in 0..<Self.enhancerFilters {
            let c = b < enhancer.count ? enhancer[b] : .identity
            let o = Self.enhancerOffset + b * 5
            pending[o] = c.b0; pending[o + 1] = c.b1; pending[o + 2] = c.b2
            pending[o + 3] = c.a1; pending[o + 4] = c.a2
        }
        pendingFlag.pointee = true
        os_unfair_lock_unlock(lock)
    }

    /// While true the sound passes untouched (the "compare" button).
    func setBypass(_ on: Bool) { bypassFlag.pointee = on }

    /// Peak level in dB (before protection) and the total number of samples that went over full scale.
    func readMeters() -> (peakDB: Double, clips: Int) {
        let peak = meters[0]
        return (peak > 1e-6 ? 20 * log10(peak) : -120, Int(meters[1]))
    }

    /// Copies the latest `count` output samples (mono) for the spectrum display.
    func copyRecentSamples(into out: inout [Float]) {
        let n = min(out.count, Self.spectrumSize)
        let end = ringIndex.pointee
        for i in 0..<n {
            out[i] = ring[(end - n + i + Self.spectrumSize) & (Self.spectrumSize - 1)]
        }
    }

    /// Called before audio starts (never while `process` is running).
    func prepare() {
        for i in 0..<Self.chainStateCount { chainState[i] = 0 }
        for i in 0..<Self.enhancerStateCount { enhState[i] = 0 }
        os_unfair_lock_lock(lock)
        if pendingFlag.pointee {
            for i in 0..<Self.paramCount { target[i] = pending[i] }
            pendingFlag.pointee = false
        }
        os_unfair_lock_unlock(lock)
        for i in 0..<Self.paramCount { current[i] = target[i] }
        meters[0] = 0
    }

    // MARK: Real-time

    @inline(__always)
    private static func softClip(_ x: Double) -> Double {
        let t = 0.6
        let a = abs(x)
        if a <= t { return x }
        let y = t + (1 - t) * tanh((a - t) / (1 - t))
        return x < 0 ? -y : y
    }

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        // Pick up new parameters without ever blocking the audio thread.
        if os_unfair_lock_trylock(lock) {
            if pendingFlag.pointee {
                for i in 0..<Self.paramCount { target[i] = pending[i] }
                pendingFlag.pointee = false
            }
            os_unfair_lock_unlock(lock)
        }
        if Int(target[0]) != Int(current[0]) {
            // The chain changed shape (another band count or mode): switch at once and start clean.
            for i in 0..<Self.paramCount { current[i] = target[i] }
            for i in 0..<Self.chainStateCount { chainState[i] = 0 }
        } else {
            // Glide towards the new settings (no clicks).
            current[3] = target[3]
            for i in 1..<3 { current[i] += (target[i] - current[i]) * 0.35 }
            for i in Self.headerCount..<Self.paramCount { current[i] += (target[i] - current[i]) * 0.35 }
        }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // Locate input channels L/R.
        var inL: UnsafeMutablePointer<Float>? = nil, inLStride = 1
        var inR: UnsafeMutablePointer<Float>? = nil, inRStride = 1
        var inFrames = Int.max
        var channel = 0
        for buf in inList {
            guard let data = buf.mData else { continue }
            let nch = Int(buf.mNumberChannels)
            if nch == 0 { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * nch)
            for c in 0..<nch {
                if channel == 0 {
                    inL = p + c; inLStride = nch; inFrames = min(inFrames, frames)
                } else if channel == 1 {
                    inR = p + c; inRStride = nch; inFrames = min(inFrames, frames)
                }
                channel += 1
            }
        }
        if inR == nil { inR = inL; inRStride = inLStride }
        if inL == nil { inFrames = 0 }

        // Clear all outputs, then locate output channels L/R.
        var outL: UnsafeMutablePointer<Float>? = nil, outLStride = 1
        var outR: UnsafeMutablePointer<Float>? = nil, outRStride = 1
        var outFrames = 0
        channel = 0
        for buf in outList {
            guard let data = buf.mData else { continue }
            memset(data, 0, Int(buf.mDataByteSize))
            let nch = Int(buf.mNumberChannels)
            if nch == 0 { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * nch)
            for c in 0..<nch {
                if channel == 0 {
                    outL = p + c; outLStride = nch; outFrames = frames
                } else if channel == 1 {
                    outR = p + c; outRStride = nch; outFrames = min(outFrames, frames)
                }
                channel += 1
            }
        }
        guard let oL = outL, let iL = inL, let iR = inR else { return }

        let count = min(Int(current[0]), Self.maxFilters)
        let gain = current[1]
        let power = current[2]
        let soft = current[3] > 0.5
        let bypass = bypassFlag.pointee
        let rightOffset = Self.maxFilters * 2
        let eo = Self.enhancerOffset
        var peak = meters[0] * 0.9
        var clips = meters[1]
        var idx = ringIndex.pointee

        for f in 0..<outFrames {
            var l = 0.0, r = 0.0
            if f < inFrames {
                l = Double(iL[f * inLStride])
                r = Double(iR[f * inRStride])
            }

            if !bypass {
                // Harmonic bass enhancer: takes the lowest bass, adds its overtones so it is felt even on small drivers.
                var enh = 0.0
                if power > 0.001 {
                    var m = (l + r) * 0.5
                    for k in 0..<4 {
                        let o = eo + k * 5
                        let s = k * 2
                        let y = current[o] * m + enhState[s]
                        enhState[s] = current[o + 1] * m - current[o + 3] * y + enhState[s + 1]
                        enhState[s + 1] = current[o + 2] * m - current[o + 4] * y
                        m = y
                        if k == 1 {
                            // after the two low-pass stages: generate harmonics
                            m = tanh(3 * m) + 0.5 * tanh(3 * abs(m))
                        }
                    }
                    enh = m * power * 1.5
                }

                for b in 0..<count {
                    let o = Self.chainOffset + b * 5
                    let b0 = current[o], b1 = current[o + 1], b2 = current[o + 2]
                    let a1 = current[o + 3], a2 = current[o + 4]

                    let sl = b * 2
                    let yl = b0 * l + chainState[sl]
                    chainState[sl] = b1 * l - a1 * yl + chainState[sl + 1]
                    chainState[sl + 1] = b2 * l - a2 * yl
                    l = yl

                    let sr = rightOffset + b * 2
                    let yr = b0 * r + chainState[sr]
                    chainState[sr] = b1 * r - a1 * yr + chainState[sr + 1]
                    chainState[sr + 1] = b2 * r - a2 * yr
                    r = yr
                }

                l = (l + enh) * gain
                r = (r + enh) * gain

                if !(l.isFinite && r.isFinite) {
                    for i in 0..<Self.chainStateCount { chainState[i] = 0 }
                    for i in 0..<Self.enhancerStateCount { enhState[i] = 0 }
                    l = 0; r = 0
                }

                let p = max(abs(l), abs(r))
                if p > peak { peak = p }
                if p > 1 { clips += 1 }

                if soft {
                    l = Self.softClip(l)
                    r = Self.softClip(r)
                } else {
                    // No limits: anything over full scale is simply cut off (audible distortion, by choice).
                    l = min(max(l, -1), 1)
                    r = min(max(r, -1), 1)
                }
            }

            ring[idx] = Float((l + r) * 0.5)
            idx = (idx + 1) & (Self.spectrumSize - 1)

            if let oR = outR {
                oL[f * outLStride] = Float(l)
                oR[f * outRStride] = Float(r)
            } else {
                oL[f * outLStride] = Float((l + r) * 0.5)
            }
        }
        meters[0] = peak
        meters[1] = clips
        ringIndex.pointee = idx
    }
}
