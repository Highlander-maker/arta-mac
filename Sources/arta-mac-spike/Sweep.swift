import Foundation

/// Exponential (logarithmic) swept sine, ARTA/Farina style, with silence padding.
///
/// Phase math (Farina 2000):
///     phase(t) = 2*pi * (f1*T / ln(f2/f1)) * (e^(t/T * ln(f2/f1)) - 1)
///
/// so instantaneous frequency f(t) = f1 * e^(t/T * ln(f2/f1)) rises exponentially
/// from f1 at t=0 to f2 at t=T.
struct SweepSignal {
    /// Full playback signal: preSilence zeros + sweep + postSilence zeros.
    let samples: [Float]
    /// Index of the first sweep sample within `samples`.
    let sweepStart: Int
    /// Number of sweep samples.
    let sweepLength: Int
    let sampleRate: Double
    let f1: Double
    let f2: Double

    var totalDuration: Double { Double(samples.count) / sampleRate }

    static func generate(
        f1: Double,
        f2: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Double,
        preSilence: Double,
        postSilence: Double,
        fadeTime: Double = 0.005
    ) -> SweepSignal {
        precondition(f1 > 0 && f2 > f1, "need 0 < f1 < f2")
        precondition(duration > 0 && sampleRate > 0)

        let preN = Int((preSilence * sampleRate).rounded())
        let postN = Int((postSilence * sampleRate).rounded())
        let sweepN = Int((duration * sampleRate).rounded())

        // k = T / ln(f2/f1); phase(t) = 2*pi*f1*k*(e^(t/k) - 1)
        let k = duration / log(f2 / f1)
        let twoPiF1K = 2.0 * Double.pi * f1 * k

        var samples = [Float](repeating: 0, count: preN + sweepN + postN)
        for i in 0..<sweepN {
            let t = Double(i) / sampleRate
            let phase = twoPiF1K * (exp(t / k) - 1.0)
            samples[preN + i] = Float(amplitude * sin(phase))
        }

        // Raised-cosine fade in/out on the sweep edges to avoid clicks.
        let fadeN = min(sweepN / 2, Int(fadeTime * sampleRate))
        if fadeN > 0 {
            for i in 0..<fadeN {
                let w = Float(0.5 * (1.0 - cos(Double.pi * Double(i) / Double(fadeN))))
                samples[preN + i] *= w
                samples[preN + sweepN - 1 - i] *= w
            }
        }

        return SweepSignal(
            samples: samples,
            sweepStart: preN,
            sweepLength: sweepN,
            sampleRate: sampleRate,
            f1: f1,
            f2: f2
        )
    }
}
