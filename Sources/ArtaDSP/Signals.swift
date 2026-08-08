import Foundation

/// Excitation signal generators. Sweep phase math follows the Farina log-sweep
/// definition used by ARTA: phi(t) = f1*T/ln(f2/f1) * (e^(t/T * ln(f2/f1)) - 1).
public enum SignalGenerator {

    /// Logarithmic (exponential) swept sine from f1 to f2 over `duration` seconds.
    /// Short raised-cosine fades avoid clicks at the ends.
    public static func logSweep(
        f1: Double,
        f2: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Double = 0.5,
        fadeSeconds: Double = 0.005
    ) -> [Float] {
        precondition(f1 > 0 && f2 > f1 && duration > 0)
        let n = Int(duration * sampleRate)
        let lnRatio = log(f2 / f1)
        let k = f1 * duration / lnRatio
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2.0 * Double.pi * k * (exp(t / duration * lnRatio) - 1.0)
            out[i] = Float(amplitude * sin(phase))
        }
        applyFades(&out, fadeSamples: Int(fadeSeconds * sampleRate))
        return out
    }

    /// Linear swept sine: phi(t) = f1*t + (f2-f1)*t^2 / (2T).
    public static func linearSweep(
        f1: Double,
        f2: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Double = 0.5,
        fadeSeconds: Double = 0.005
    ) -> [Float] {
        let n = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2.0 * Double.pi * (f1 * t + (f2 - f1) * t * t / (2.0 * duration))
            out[i] = Float(amplitude * sin(phase))
        }
        applyFades(&out, fadeSamples: Int(fadeSeconds * sampleRate))
        return out
    }

    /// Envelope shaping the tone burst. Both are symmetric about T/2, so the arrival
    /// detector's "envelope peak = burst centre" assumption holds for either.
    public enum BurstEnvelope: String, Codable, CaseIterable, Sendable {
        /// Full raised cosine, w(t) = ½ − ½cos(2πt/T). Linkwitz's original.
        case raisedCosine
        /// Gaussian (Gabor) pulse. Uniquely minimises the time–bandwidth product,
        /// so it is the most sharply localised burst available in both domains at
        /// once — the reason it gives the cleanest centre to align to. Jonathan
        /// Digby specifies this envelope for wavelet alignment work.
        case gaussian
    }

    /// Shaped tone burst (Linkwitz, JAES 1980): `cycles` of a sine at `frequency`
    /// multiplied by a symmetric envelope, where the burst length T = cycles /
    /// frequency. The envelope tapers the burst to zero at both ends, confining its
    /// spectrum to ≈⅓ octave around f0 and killing the click a rectangular burst
    /// would make. Played into a system, the PEAK of the received burst's envelope
    /// is the frequency-response magnitude at f0, while the SHAPE of that envelope
    /// (slow build-up, extended ring-out) exposes localized resonances a swept
    /// measurement smooths over.
    ///
    /// On `cycles`: 5 is Linkwitz's figure and what Digby uses — enough ramp to show
    /// the shape, short enough that the envelope peak stays sharp and catches fewer
    /// reflections. Pat Brown's published wavelet library uses 6.5, which is what
    /// puts it at ~⅓-octave bandwidth. Either aligns; longer bursts trade centre
    /// sharpness for frequency selectivity.
    public static func shapedToneBurst(
        frequency: Double,
        cycles: Int = 5,
        sampleRate: Double,
        amplitude: Double = 0.5,
        envelope: BurstEnvelope = .raisedCosine
    ) -> [Float] {
        precondition(frequency > 0 && cycles > 0 && sampleRate > 0)
        let burstLength = Double(cycles) / frequency        // T, seconds
        let n = max(1, Int((burstLength * sampleRate).rounded()))
        // Gaussian truncated at ±3σ: the untruncated curve never reaches zero, and a
        // step at the ends would splatter the spectrum the taper exists to contain.
        // The 3σ pedestal (e^-4.5 ≈ 0.011) is subtracted and the result renormalised,
        // so the burst starts and ends at exactly zero and still peaks at 1.
        let sigma = burstLength / 6.0
        let pedestal = exp(-4.5)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let window: Double
            switch envelope {
            case .raisedCosine:
                window = 0.5 - 0.5 * cos(2.0 * .pi * t / burstLength)
            case .gaussian:
                let z = (t - burstLength / 2) / sigma
                window = max(0, (exp(-0.5 * z * z) - pedestal) / (1 - pedestal))
            }
            let carrier = sin(2.0 * .pi * frequency * t)
            out[i] = Float(amplitude * window * carrier)
        }
        return out
    }

    public static func sine(frequency: Double, duration: Double, sampleRate: Double, amplitude: Double = 0.5) -> [Float] {
        let n = Int(duration * sampleRate)
        return (0..<n).map { Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / sampleRate)) }
    }

    public static func whiteNoise(count: Int, amplitude: Float = 0.5, seed: UInt64 = 0x5EED) -> [Float] {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in (Float(rng.nextUniform()) * 2 - 1) * amplitude }
    }

    /// Pink noise via the Paul Kellet filter (-3dB/oct, accurate within ±0.05dB above 9.2Hz @ 44.1k).
    public static func pinkNoise(count: Int, amplitude: Float = 0.5, seed: UInt64 = 0x5EED) -> [Float] {
        var rng = SeededRNG(seed: seed)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let white = Float(rng.nextUniform()) * 2 - 1
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
            out[i] = pink * 0.11 * amplitude
        }
        return out
    }

    /// Short broadband tick: fast attack, exponential decay noise burst. Full-band
    /// so it's audible through both a sub (low content) and a top (high content) —
    /// the classic system-tech "click" used to check sub/top alignment by ear.
    public static func clickBurst(sampleRate: Double, durationMs: Double = 4.0, amplitude: Float = 0.95) -> [Float] {
        let n = max(4, Int(sampleRate * durationMs / 1000.0))
        var rng = SeededRNG(seed: 0xC1C4)
        var out = [Float](repeating: 0, count: n)
        let decay = 6.0 // time constants across the burst
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let env = exp(-decay * t)
            let white = Float(rng.nextUniform()) * 2 - 1
            out[i] = Float(env) * white
        }
        let peak = out.map(abs).max() ?? 1
        if peak > 0 {
            let g = amplitude / peak
            for i in 0..<n { out[i] *= g }
        }
        return out
    }

    private static func applyFades(_ signal: inout [Float], fadeSamples: Int) {
        let n = signal.count
        let fade = min(fadeSamples, n / 2)
        guard fade > 0 else { return }
        for i in 0..<fade {
            let w = Float(0.5 * (1.0 - cos(Double.pi * Double(i) / Double(fade))))
            signal[i] *= w
            signal[n - 1 - i] *= w
        }
    }
}

/// Deterministic RNG (SplitMix64) so tests and periodic-noise sequences are reproducible.
public struct SeededRNG {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1)
    public mutating func nextUniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}
