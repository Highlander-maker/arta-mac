import Foundation

/// Fractional-octave band filtering and IEC 61672 frequency weightings.
///
/// Band filtering is done zero-phase in the frequency domain with a 6-pole
/// Butterworth bandpass magnitude (ARTA uses IEC class I 6-pole Butterworth
/// filters; zero-phase application avoids smearing decay tails, which matters
/// for per-band RT60 and MTF work on stored impulse responses).
public enum BandFilters {

    /// Standard 1/1-octave centre frequencies (IEC 1260).
    public static let octaveCenters: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Standard 1/3-octave centre frequencies.
    public static let thirdOctaveCenters: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
        630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
        10000, 12500, 16000
    ]

    /// Zero-phase 6-pole Butterworth bandpass. `fraction` = 1 for octave,
    /// 3 for third-octave. Returns the filtered signal (same length).
    public static func bandpass(
        signal: [Float],
        center f0: Double,
        fraction: Int,
        sampleRate: Double
    ) -> [Float] {
        let l = FFT.nextPowerOfTwo(signal.count)
        guard let fft = FFT(length: l), f0 < sampleRate / 2 else { return signal }

        var re = signal + [Float](repeating: 0, count: l - signal.count)
        var im = [Float](repeating: 0, count: l)
        fft.forward(&re, &im)

        // Bandwidth per IEC: B = f0 * (2^(1/2n) - 2^(-1/2n))
        let half = pow(2.0, 1.0 / (2.0 * Double(fraction)))
        let bandwidth = f0 * (half - 1.0 / half)
        let binHz = sampleRate / Double(l)

        for i in 0..<l {
            // Mirror bins map to negative frequencies with the same magnitude gain.
            let binIdx = i <= l / 2 ? i : l - i
            let f = Double(binIdx) * binHz
            let gain: Double
            if f <= 0 {
                gain = 0
            } else {
                let u = (f * f - f0 * f0) / (bandwidth * f)
                gain = 1.0 / sqrt(1.0 + pow(u, 6)) // 6-pole Butterworth BP magnitude
            }
            re[i] *= Float(gain)
            im[i] *= Float(gain)
        }
        fft.inverse(&re, &im)
        return Array(re[0..<signal.count])
    }

    // MARK: IEC 61672 weighting

    public enum Weighting {
        case a, c, z
    }

    /// Weighting gain in dB at frequency f, per the IEC 61672 analytic curves
    /// (normalized to 0 dB at 1 kHz).
    public static func weightingGainDB(frequency f: Double, _ weighting: Weighting) -> Double {
        guard f > 0 else { return -Double.infinity }
        switch weighting {
        case .z:
            return 0
        case .c:
            let f2 = f * f
            let num = 12194.0 * 12194.0 * f2
            let den = (f2 + 20.6 * 20.6) * (f2 + 12194.0 * 12194.0)
            return 20 * log10(num / den) + 0.06
        case .a:
            let f2 = f * f
            let num = 12194.0 * 12194.0 * f2 * f2
            let den = (f2 + 20.6 * 20.6)
                * sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9))
                * (f2 + 12194.0 * 12194.0)
            return 20 * log10(num / den) + 2.00
        }
    }
}

// MARK: - Per-band room acoustics

extension RoomAcoustics {
    /// ISO 3382 parameters per octave band (63 Hz – 8 kHz by default, ARTA's
    /// extended range), by zero-phase band filtering the IR then analyzing each band.
    public static func analyzeOctaveBands(
        ir: [Float],
        sampleRate: Double,
        centers: [Double] = [63, 125, 250, 500, 1000, 2000, 4000, 8000],
        truncate: Bool = true
    ) -> [(center: Double, params: RoomAcousticParams)] {
        centers.compactMap { f0 in
            guard f0 < sampleRate / 2 else { return nil }
            let banded = BandFilters.bandpass(signal: ir, center: f0, fraction: 1, sampleRate: sampleRate)
            return (f0, analyze(ir: banded, sampleRate: sampleRate, truncate: truncate))
        }
    }
}
