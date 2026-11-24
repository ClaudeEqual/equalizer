import Foundation
import CoreAudio
import os

// MARK: - Biquad filter math (RBJ Audio EQ Cookbook)

struct BiquadCoefficients {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

enum FilterKind { case lowShelf, peak, highShelf }

func makeBiquad(kind: FilterKind, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
    if abs(gainDB) < 0.01 || sampleRate <= 0 { return .identity }
    let a = pow(10.0, gainDB / 40.0)
    let freq = min(frequency, sampleRate * 0.45)
    let w0 = 2.0 * Double.pi * freq / sampleRate
    let cosw = cos(w0)
    let sinw = sin(w0)
    let alpha = sinw / (2.0 * q)

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
    }
    return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
}

// MARK: - Real-time processor

/// Stereo 10-band EQ + auto preamp + peak limiter.
/// `process` runs on the Core Audio real-time thread: no allocations, no blocking locks.
final class EQProcessor {
    static let bands = 10
    private static let paramCount = bands * 5 + 1 // 5 coefficients per band + preamp (linear)

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let pending: UnsafeMutablePointer<Double>
    private let pendingFlag: UnsafeMutablePointer<Bool>
    private let target: UnsafeMutablePointer<Double>
    private let current: UnsafeMutablePointer<Double>
    private let state: UnsafeMutablePointer<Double>   // [channel][band][z1, z2]
    private let misc: UnsafeMutablePointer<Double>    // [0] limiter gain, [1] limiter release coefficient

    private static let stateCount = 2 * bands * 2
    private static let limiterThreshold = 0.977 // about -0.2 dBFS

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
        state = .allocate(capacity: Self.stateCount)
        state.initialize(repeating: 0, count: Self.stateCount)
        misc = .allocate(capacity: 2)
        misc.initialize(repeating: 0, count: 2)

        Self.writeIdentity(into: target)
        Self.writeIdentity(into: current)
        misc[0] = 1
        misc[1] = 1 - exp(-1 / (0.2 * 48_000))
    }

    deinit {
        lock.deallocate()
        pending.deallocate()
        pendingFlag.deallocate()
        target.deallocate()
        current.deallocate()
        state.deallocate()
        misc.deallocate()
    }

    private static func writeIdentity(into p: UnsafeMutablePointer<Double>) {
        for b in 0..<bands {
            let o = b * 5
            p[o] = 1; p[o + 1] = 0; p[o + 2] = 0; p[o + 3] = 0; p[o + 4] = 0
        }
        p[bands * 5] = 1
    }

    /// Called from the main thread whenever the user changes something.
    func setParameters(_ coeffs: [BiquadCoefficients], preampDB: Double) {
        os_unfair_lock_lock(lock)
        for b in 0..<Self.bands {
            let c = b < coeffs.count ? coeffs[b] : .identity
            let o = b * 5
            pending[o] = c.b0; pending[o + 1] = c.b1; pending[o + 2] = c.b2
            pending[o + 3] = c.a1; pending[o + 4] = c.a2
        }
        pending[Self.bands * 5] = pow(10.0, preampDB / 20.0)
        pendingFlag.pointee = true
        os_unfair_lock_unlock(lock)
    }

    /// Called before audio starts (never while `process` is running).
    func prepare(sampleRate: Double) {
        for i in 0..<Self.stateCount { state[i] = 0 }
        os_unfair_lock_lock(lock)
        if pendingFlag.pointee {
            for i in 0..<Self.paramCount { target[i] = pending[i] }
            pendingFlag.pointee = false
        }
        os_unfair_lock_unlock(lock)
        for i in 0..<Self.paramCount { current[i] = target[i] }
        misc[0] = 1
        misc[1] = 1 - exp(-1 / (0.2 * max(sampleRate, 8_000)))
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
        // Smoothly glide towards the new settings (no clicks).
        for i in 0..<Self.paramCount {
            current[i] += (target[i] - current[i]) * 0.35
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

        let bands = Self.bands
        let pre = current[bands * 5]
        let release = misc[1]
        var gain = misc[0]
        let threshold = Self.limiterThreshold
        let rightStateOffset = bands * 2

        for f in 0..<outFrames {
            var l = 0.0, r = 0.0
            if f < inFrames {
                l = Double(iL[f * inLStride]) * pre
                r = Double(iR[f * inRStride]) * pre
            }

            for b in 0..<bands {
                let o = b * 5
                let b0 = current[o], b1 = current[o + 1], b2 = current[o + 2]
                let a1 = current[o + 3], a2 = current[o + 4]

                let sl = b * 2
                let yl = b0 * l + state[sl]
                state[sl] = b1 * l - a1 * yl + state[sl + 1]
                state[sl + 1] = b2 * l - a2 * yl
                l = yl

                let sr = rightStateOffset + b * 2
                let yr = b0 * r + state[sr]
                state[sr] = b1 * r - a1 * yr + state[sr + 1]
                state[sr + 1] = b2 * r - a2 * yr
                r = yr
            }

            if !(l.isFinite && r.isFinite) {
                for i in 0..<Self.stateCount { state[i] = 0 }
                l = 0; r = 0
            }

            // Peak limiter: instant attack, smooth release.
            let peak = max(abs(l), abs(r))
            gain += (1 - gain) * release
            if peak * gain > threshold { gain = threshold / peak }
            l *= gain
            r *= gain

            if let oR = outR {
                oL[f * outLStride] = Float(l)
                oR[f * outRStride] = Float(r)
            } else {
                oL[f * outLStride] = Float((l + r) * 0.5)
            }
        }
        misc[0] = gain
    }
}
