import Foundation

/// ISO 3382 room acoustical parameters from a measured impulse response,
/// via Schroeder backward integration (as ARTA does).
public struct RoomAcousticParams {
    public var t30: Double?      // seconds, from -5..-35 dB regression
    public var t20: Double?      // seconds, from -5..-25 dB
    public var edt: Double?      // seconds, from 0..-10 dB
    public var rT30: Double?     // regression correlation coefficient
    public var rT20: Double?
    public var c50: Double       // dB
    public var c80: Double       // dB
    public var d50: Double       // percent
    public var ts: Double        // centre time, ms
}

public enum RoomAcoustics {

    /// Schroeder decay: 10·log10 of the normalized backward integral of h²(t).
    public static func schroederDecayDB(ir: [Float]) -> [Double] {
        let n = ir.count
        guard n > 0 else { return [] }
        var decay = [Double](repeating: 0, count: n)
        var acc: Double = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            acc += Double(ir[i]) * Double(ir[i])
            decay[i] = acc
        }
        let total = decay[0]
        guard total > 0 else { return decay }
        for i in 0..<n {
            decay[i] = 10.0 * log10(max(decay[i] / total, 1e-15))
        }
        return decay
    }

    /// Noise-tail truncation per ISO 3382: find where signal+noise is ~5 dB above
    /// the mean noise level estimated from the last `noiseTailFraction` of the IR.
    /// Returns the truncation index (ir.count if no truncation point found).
    public static func truncationIndex(ir: [Float], noiseTailFraction: Double = 0.1) -> Int {
        let n = ir.count
        let tailStart = Int(Double(n) * (1.0 - noiseTailFraction))
        guard tailStart < n - 1 else { return n }
        var noise: Double = 0
        for i in tailStart..<n { noise += Double(ir[i]) * Double(ir[i]) }
        noise /= Double(n - tailStart)
        guard noise > 0 else { return n }
        let threshold = noise * pow(10.0, 0.5) // +5 dB

        // Scan a short moving average of h² from the end toward the peak.
        let windowLen = max(32, n / 200)
        var i = n - windowLen - 1
        while i > 0 {
            var e: Double = 0
            for j in i..<(i + windowLen) { e += Double(ir[j]) * Double(ir[j]) }
            e /= Double(windowLen)
            if e > threshold { return min(i + windowLen, n) }
            i -= windowLen
        }
        return n
    }

    /// Full parameter set. `truncate` = apply ISO 3382 noise truncation first.
    public static func analyze(ir: [Float], sampleRate: Double, truncate: Bool = true) -> RoomAcousticParams {
        var work = ir
        if truncate {
            let idx = truncationIndex(ir: ir)
            if idx < ir.count { work = Array(ir[0..<idx]) }
        }

        // Align t=0 to the IR peak (direct sound arrival).
        var peakIdx = 0
        var peakVal: Float = 0
        for (i, v) in work.enumerated() where abs(v) > peakVal {
            peakVal = abs(v)
            peakIdx = i
        }
        let aligned = Array(work[peakIdx...])
        let decay = schroederDecayDB(ir: aligned)

        let (t30, r30) = reverbTime(decay: decay, sampleRate: sampleRate, from: -5, to: -35)
        let (t20, r20) = reverbTime(decay: decay, sampleRate: sampleRate, from: -5, to: -25)
        let (edt, _) = reverbTime(decay: decay, sampleRate: sampleRate, from: 0, to: -10)

        // Energy ratios on the aligned IR.
        let n = aligned.count
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(aligned[i]) * Double(aligned[i]) }
        let total = prefix[n]
        let i50 = min(n, Int(0.050 * sampleRate))
        let i80 = min(n, Int(0.080 * sampleRate))
        let e50 = prefix[i50]
        let e80 = prefix[i80]

        let c50 = 10 * log10(max(e50, 1e-15) / max(total - e50, 1e-15))
        let c80 = 10 * log10(max(e80, 1e-15) / max(total - e80, 1e-15))
        let d50 = total > 0 ? 100.0 * e50 / total : 0

        var tsNum: Double = 0
        for i in 0..<n {
            let h2 = Double(aligned[i]) * Double(aligned[i])
            tsNum += (Double(i) / sampleRate) * h2
        }
        let ts = total > 0 ? (tsNum / total) * 1000.0 : 0

        return RoomAcousticParams(
            t30: t30, t20: t20, edt: edt, rT30: r30, rT20: r20,
            c50: c50, c80: c80, d50: d50, ts: ts
        )
    }

    /// Reverberation time by linear regression of the Schroeder decay between two
    /// levels; T = -60 / slope. Also returns the regression correlation coefficient.
    static func reverbTime(decay: [Double], sampleRate: Double, from levelHi: Double, to levelLo: Double)
        -> (t: Double?, r: Double?) {
        guard decay.count > 2 else { return (nil, nil) }
        var startIdx: Int?
        var endIdx: Int?
        for (i, v) in decay.enumerated() {
            if startIdx == nil && v <= levelHi { startIdx = i }
            if endIdx == nil && v <= levelLo { endIdx = i; break }
        }
        guard let s = startIdx, let e = endIdx, e > s + 2 else { return (nil, nil) }

        // Least-squares fit of decay dB vs time over [s, e].
        let count = Double(e - s + 1)
        var sumX: Double = 0, sumY: Double = 0, sumXY: Double = 0, sumXX: Double = 0, sumYY: Double = 0
        for i in s...e {
            let x = Double(i) / sampleRate
            let y = decay[i]
            sumX += x; sumY += y
            sumXY += x * y; sumXX += x * x; sumYY += y * y
        }
        let denom = count * sumXX - sumX * sumX
        guard abs(denom) > 1e-15 else { return (nil, nil) }
        let slope = (count * sumXY - sumX * sumY) / denom
        guard slope < 0 else { return (nil, nil) }

        let rDenom = sqrt((count * sumXX - sumX * sumX) * (count * sumYY - sumY * sumY))
        let r = rDenom > 0 ? (count * sumXY - sumX * sumY) / rDenom : 0
        return (-60.0 / slope, r)
    }
}
