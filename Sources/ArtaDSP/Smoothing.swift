import Foundation

/// 1/n-octave smoothing of a power spectrum. ARTA smooths on a log-frequency
/// axis with filters approximating IEC class I fractional-octave bands; power
/// averaging over the band [f·2^(-1/2n), f·2^(+1/2n)] is the standard
/// implementation and matches within a fraction of a dB.
public enum Smoothing {

    /// `power`: bins 0...N/2 of a power spectrum (|H|²).
    /// `n`: octave fraction denominator (1, 2, 3, 6, 12, 24 — ARTA's set).
    /// Returns the smoothed power spectrum, same bin count.
    public static func fractionalOctave(power: [Float], sampleRate: Double, fftSize: Int, n: Int) -> [Float] {
        let bins = power.count
        guard bins > 2, n >= 1 else { return power }

        // Prefix sums for O(1) band averaging per bin.
        var prefix = [Double](repeating: 0, count: bins + 1)
        for i in 0..<bins { prefix[i + 1] = prefix[i] + Double(power[i]) }

        let halfBand = pow(2.0, 1.0 / (2.0 * Double(n)))
        let binHz = sampleRate / Double(fftSize)
        var out = [Float](repeating: 0, count: bins)
        out[0] = power[0]

        for i in 1..<bins {
            let f = Double(i) * binHz
            var lo = Int((f / halfBand) / binHz + 0.5)
            var hi = Int((f * halfBand) / binHz + 0.5)
            lo = max(1, lo)
            hi = min(bins - 1, hi)
            if hi <= lo {
                out[i] = power[i]
            } else {
                out[i] = Float((prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1))
            }
        }
        return out
    }

    public static func powerToDB(_ power: [Float], floor: Float = -200) -> [Float] {
        power.map { $0 > 0 ? max(10 * log10($0), floor) : floor }
    }
}
