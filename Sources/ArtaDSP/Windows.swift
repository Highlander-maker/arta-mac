import Foundation

/// Analysis windows for spectrum estimation, plus ARTA-style gate windows
/// (half-Hann applied to the tail portion of a gated impulse response).
public enum Window {
    case uniform
    case hann
    case hamming
    case blackman        // Blackman 3-term
    case flatTop

    public func samples(count: Int) -> [Float] {
        let n = count
        guard n > 1 else { return [Float](repeating: 1, count: n) }
        var w = [Float](repeating: 0, count: n)
        let m = Double(n - 1)
        for i in 0..<n {
            let x = Double(i) / m
            let v: Double
            switch self {
            case .uniform:
                v = 1.0
            case .hann:
                v = 0.5 - 0.5 * cos(2 * .pi * x)
            case .hamming:
                v = 0.54 - 0.46 * cos(2 * .pi * x)
            case .blackman:
                v = 0.42 - 0.5 * cos(2 * .pi * x) + 0.08 * cos(4 * .pi * x)
            case .flatTop:
                v = 0.21557895
                    - 0.41663158 * cos(2 * .pi * x)
                    + 0.277263158 * cos(4 * .pi * x)
                    - 0.083578947 * cos(6 * .pi * x)
                    + 0.006947368 * cos(8 * .pi * x)
            }
            w[i] = Float(v)
        }
        return w
    }

    /// Coherent gain (mean of window), used to correct spectrum magnitude.
    public func coherentGain(count: Int) -> Float {
        let s = samples(count: count)
        return s.reduce(0, +) / Float(count)
    }
}

public enum GateWindow {
    /// ARTA's gate windows: Uniform, Hann12%, Hann25%, Hann50%. The percentage is
    /// the fraction of the gate tail that gets a falling half-Hann taper.
    public static func gate(length: Int, tailFraction: Double) -> [Float] {
        var w = [Float](repeating: 1, count: length)
        let tail = Int(Double(length) * max(0, min(1, tailFraction)))
        guard tail > 1 else { return w }
        let start = length - tail
        for i in 0..<tail {
            let x = Double(i) / Double(tail - 1)
            w[start + i] = Float(0.5 * (1.0 + cos(.pi * x)))
        }
        return w
    }
}
