import Foundation

/// Trial delay and complex summation of two measured responses.
///
/// A pure delay multiplies every bin by `e^(−j2πfτ)`: magnitude untouched, phase
/// rotated linearly with frequency. That makes "what would these two sources sum
/// to if one were delayed by τ?" pure arithmetic on data already captured, rather
/// than a re-measure per guess — the laptop half of a crossover alignment.
///
/// **The spectra must share a time origin.** A gated response's t=0 is its own
/// gate start, which the operator places by hand and moves between measurements;
/// summing two of those would silently align them and report τ=0 as correct. The
/// caller is responsible for referencing both to a common zero first (in this app,
/// impulse-response sample 0 — see `AppModel.recomputeFrequencyResponse`).
public enum Summation {

    /// Delay a complex spectrum by `seconds`. Negative advances it.
    public static func delayed(
        hRe: [Float], hIm: [Float], frequencies: [Double], seconds: Double
    ) -> (re: [Float], im: [Float]) {
        let n = min(hRe.count, min(hIm.count, frequencies.count))
        var outRe = [Float](repeating: 0, count: n)
        var outIm = [Float](repeating: 0, count: n)
        guard n > 0 else { return (outRe, outIm) }
        for i in 0..<n {
            let theta = -2.0 * Double.pi * frequencies[i] * seconds
            let c = Float(cos(theta))
            let s = Float(sin(theta))
            // (a + jb)(c + js)
            outRe[i] = hRe[i] * c - hIm[i] * s
            outIm[i] = hRe[i] * s + hIm[i] * c
        }
        return (outRe, outIm)
    }

    /// Complex sum of two spectra sampled on the same frequency grid. Returns nil
    /// on a length mismatch rather than summing the overlap — two responses on
    /// different grids are not comparable, and a partial answer would look valid.
    public static func sum(
        aRe: [Float], aIm: [Float], bRe: [Float], bIm: [Float]
    ) -> (re: [Float], im: [Float])? {
        let n = aRe.count
        guard n > 0, aIm.count == n, bRe.count == n, bIm.count == n else { return nil }
        var outRe = [Float](repeating: 0, count: n)
        var outIm = [Float](repeating: 0, count: n)
        for i in 0..<n {
            outRe[i] = aRe[i] + bRe[i]
            outIm[i] = aIm[i] + bIm[i]
        }
        return (outRe, outIm)
    }

    /// |H|² per bin — the form fractional-octave smoothing expects.
    public static func power(re: [Float], im: [Float]) -> [Float] {
        let n = min(re.count, im.count)
        return (0..<n).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }

    public static func magnitudeDB(re: [Float], im: [Float], floor: Float = -200) -> [Float] {
        let n = min(re.count, im.count)
        return (0..<n).map {
            let m = sqrt(re[$0] * re[$0] + im[$0] * im[$0])
            return m > 0 ? max(20 * log10(m), floor) : floor
        }
    }

    /// Wrapped phase in degrees, optionally with a delay removed — the same
    /// convention as `FrequencyResponse.phaseDegrees(removingDelay:)`, so a summed
    /// curve can be plotted against the sources it came from.
    public static func phaseDegrees(
        re: [Float], im: [Float], frequencies: [Double], removingDelay seconds: Double = 0
    ) -> [Float] {
        let n = min(re.count, min(im.count, frequencies.count))
        return (0..<n).map { i in
            var ph = Double(atan2(im[i], re[i])) + 2.0 * .pi * frequencies[i] * seconds
            ph = atan2(sin(ph), cos(ph))
            return Float(ph * 180.0 / .pi)
        }
    }
}
