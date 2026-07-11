import Foundation

/// Speech Transmission Index per IEC 60268-16, using the indirect (impulse
/// response) method: MTF from the Schroeder expression
/// m(F) = |∫h²(t)e^(-j2πFt)dt| / ∫h²(t)dt per octave band, then the STI
/// weighting/summation. Matches ARTA's STI window (male speech weights).
public struct STIResult {
    /// mtf[band][modFreq] — 7 octave bands (125 Hz – 8 kHz) × 14 modulation frequencies.
    public let mtf: [[Double]]
    /// Octave transmission index per band.
    public let oti: [Double]
    public let sti: Double
    public let alcons: Double

    public var rating: String {
        switch sti {
        case ..<0.30: return "BAD"
        case ..<0.45: return "POOR"
        case ..<0.60: return "FAIR"
        case ..<0.75: return "GOOD"
        default: return "EXCELLENT"
        }
    }
}

public enum STI {

    public static let octaveBands: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000]

    /// 14 modulation frequencies, 0.63–12.5 Hz in 1/3-octave steps.
    public static let modulationFrequencies: [Double] = [
        0.63, 0.80, 1.00, 1.25, 1.60, 2.00, 2.50, 3.15, 4.00, 5.00, 6.30, 8.00, 10.00, 12.50
    ]

    /// Male-speech band weighting factors (IEC 60268-16:2011), alpha for each
    /// band, beta for each adjacent-band pair.
    static let alphaMale: [Double] = [0.085, 0.127, 0.230, 0.233, 0.309, 0.224, 0.173]
    static let betaMale: [Double] = [0.085, 0.078, 0.065, 0.011, 0.047, 0.095]

    /// Compute STI from a measured impulse response.
    /// - Parameters:
    ///   - snrPerBand: optional per-band S/N in dB (7 values) applied as
    ///     m' = m / (1 + 10^(-SNR/10)); omit for a noise-free IR measurement
    ///     where the noise is already embedded in the IR.
    public static func compute(
        ir: [Float],
        sampleRate: Double,
        snrPerBand: [Double]? = nil
    ) -> STIResult {
        var mtfMatrix: [[Double]] = []
        var otis: [Double] = []

        for (bandIdx, f0) in octaveBands.enumerated() {
            let banded = BandFilters.bandpass(signal: ir, center: f0, fraction: 1, sampleRate: sampleRate)

            // h²(t) and its total energy.
            let n = banded.count
            var h2 = [Double](repeating: 0, count: n)
            var total: Double = 0
            for i in 0..<n {
                let v = Double(banded[i])
                h2[i] = v * v
                total += h2[i]
            }

            var bandMTF: [Double] = []
            for fm in modulationFrequencies {
                var sumRe: Double = 0
                var sumIm: Double = 0
                let w = 2.0 * Double.pi * fm / sampleRate
                for i in 0..<n where h2[i] != 0 {
                    let ph = w * Double(i)
                    sumRe += h2[i] * cos(ph)
                    sumIm -= h2[i] * sin(ph)
                }
                var m = total > 0 ? sqrt(sumRe * sumRe + sumIm * sumIm) / total : 0
                if let snr = snrPerBand, bandIdx < snr.count {
                    m /= (1.0 + pow(10.0, -snr[bandIdx] / 10.0))
                }
                bandMTF.append(min(m, 1.0))
            }
            mtfMatrix.append(bandMTF)

            // Octave transmission index: X = 10log(m/(1-m)) clipped to ±15 dB,
            // TI = (X+15)/30, OTI = mean over modulation frequencies.
            let tis = bandMTF.map { m -> Double in
                let clamped = min(max(m, 1e-6), 1.0 - 1e-6)
                var x = 10.0 * log10(clamped / (1.0 - clamped))
                x = min(max(x, -15.0), 15.0)
                return (x + 15.0) / 30.0
            }
            otis.append(tis.reduce(0, +) / Double(tis.count))
        }

        var sti: Double = 0
        for i in 0..<7 { sti += alphaMale[i] * otis[i] }
        for i in 0..<6 { sti -= betaMale[i] * sqrt(otis[i] * otis[i + 1]) }
        sti = min(max(sti, 0), 1)

        let alcons = 170.5405 * exp(-5.419 * sti)
        return STIResult(mtf: mtfMatrix, oti: otis, sti: sti, alcons: alcons)
    }
}
