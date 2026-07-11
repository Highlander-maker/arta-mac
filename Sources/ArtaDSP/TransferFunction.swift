import Foundation

/// Result of a dual-channel transfer function estimate: complex H at bins 0...N/2,
/// plus the coherence function for measurement quality checking.
public struct FrequencyResponse {
    public let fftSize: Int
    public let sampleRate: Double
    public let hRe: [Float]
    public let hIm: [Float]
    public let coherence: [Float]
    public let averages: Int

    public var binCount: Int { hRe.count }

    public func frequencies() -> [Double] {
        let df = sampleRate / Double(fftSize)
        return (0..<binCount).map { Double($0) * df }
    }

    public func magnitudeDB(floor: Float = -200) -> [Float] {
        (0..<binCount).map {
            let m = sqrt(hRe[$0] * hRe[$0] + hIm[$0] * hIm[$0])
            return m > 0 ? max(20 * log10(m), floor) : floor
        }
    }

    /// Phase in degrees, optionally with a delay (seconds) removed — ARTA's
    /// "Delay for phase estimation".
    public func phaseDegrees(removingDelay delaySeconds: Double = 0) -> [Float] {
        let freqs = frequencies()
        return (0..<binCount).map { i in
            var ph = Double(atan2(hIm[i], hRe[i])) + 2.0 * .pi * freqs[i] * delaySeconds
            ph = atan2(sin(ph), cos(ph)) // wrap to [-pi, pi]
            return Float(ph * 180.0 / .pi)
        }
    }
}

/// Averaged H1 estimator: H = <Y·conj(X)> / <X·conj(X)>, coherence
/// gamma² = |<Sxy>|² / (<Sxx>·<Syy>). This is the core of ARTA's FR2 mode.
public enum TransferFunctionEstimator {

    public static func h1(
        x: [Float],
        y: [Float],
        fftSize: Int,
        sampleRate: Double,
        window: Window = .hann,
        overlap: Double = 0.5
    ) -> FrequencyResponse? {
        guard let fft = FFT(length: fftSize) else { return nil }
        let n = min(x.count, y.count)
        guard n >= fftSize else { return nil }

        let hop = max(1, Int(Double(fftSize) * (1.0 - overlap)))
        let w = window.samples(count: fftSize)
        let bins = fftSize / 2 + 1

        var sxx = [Float](repeating: 0, count: bins)
        var syy = [Float](repeating: 0, count: bins)
        var sxyRe = [Float](repeating: 0, count: bins)
        var sxyIm = [Float](repeating: 0, count: bins)
        var count = 0

        var start = 0
        while start + fftSize <= n {
            var xRe = [Float](repeating: 0, count: fftSize)
            var xIm = [Float](repeating: 0, count: fftSize)
            var yRe = [Float](repeating: 0, count: fftSize)
            var yIm = [Float](repeating: 0, count: fftSize)
            for i in 0..<fftSize {
                xRe[i] = x[start + i] * w[i]
                yRe[i] = y[start + i] * w[i]
            }
            fft.forward(&xRe, &xIm)
            fft.forward(&yRe, &yIm)

            for b in 0..<bins {
                sxx[b] += xRe[b] * xRe[b] + xIm[b] * xIm[b]
                syy[b] += yRe[b] * yRe[b] + yIm[b] * yIm[b]
                // conj(X) * Y
                sxyRe[b] += xRe[b] * yRe[b] + xIm[b] * yIm[b]
                sxyIm[b] += xRe[b] * yIm[b] - xIm[b] * yRe[b]
            }
            count += 1
            start += hop
        }
        guard count > 0 else { return nil }

        var hRe = [Float](repeating: 0, count: bins)
        var hIm = [Float](repeating: 0, count: bins)
        var coh = [Float](repeating: 0, count: bins)
        let tiny: Float = 1e-20
        for b in 0..<bins {
            hRe[b] = sxyRe[b] / (sxx[b] + tiny)
            hIm[b] = sxyIm[b] / (sxx[b] + tiny)
            let num = sxyRe[b] * sxyRe[b] + sxyIm[b] * sxyIm[b]
            coh[b] = num / (sxx[b] * syy[b] + tiny)
        }
        return FrequencyResponse(
            fftSize: fftSize, sampleRate: sampleRate,
            hRe: hRe, hIm: hIm, coherence: coh, averages: count
        )
    }

    /// Gated frequency response from an impulse response segment (ARTA's
    /// single-gated FR): window the gate, zero-pad to FFT size, transform.
    public static func gatedResponse(
        ir: [Float],
        gateStart: Int,
        gateLength: Int,
        fftSize: Int,
        sampleRate: Double,
        gateTailFraction: Double = 0.5
    ) -> FrequencyResponse? {
        guard let fft = FFT(length: fftSize), gateStart >= 0, gateLength > 0 else { return nil }
        let w = GateWindow.gate(length: gateLength, tailFraction: gateTailFraction)
        var re = [Float](repeating: 0, count: fftSize)
        var im = [Float](repeating: 0, count: fftSize)
        for i in 0..<gateLength {
            let src = gateStart + i
            if src < ir.count && i < fftSize {
                re[i] = ir[src] * w[i]
            }
        }
        fft.forward(&re, &im)
        let bins = fftSize / 2 + 1
        return FrequencyResponse(
            fftSize: fftSize, sampleRate: sampleRate,
            hRe: Array(re[0..<bins]), hIm: Array(im[0..<bins]),
            coherence: [Float](repeating: 1, count: bins), averages: 1
        )
    }
}
