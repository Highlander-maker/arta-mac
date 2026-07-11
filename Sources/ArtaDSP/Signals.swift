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
