import Foundation

/// Time-domain analyses derived from the impulse response: ETC (impulse response
/// envelope via Hilbert transform), step response, and minimum phase support.
public enum Analysis {

    /// Impulse response envelope (Energy-Time Curve) in dB, normalized to 0 dB peak.
    /// Computed as the magnitude of the analytic signal: FFT → zero negative
    /// frequencies (double positive) → IFFT → |·|.
    public static func energyTimeCurveDB(ir: [Float]) -> [Float] {
        let l = FFT.nextPowerOfTwo(ir.count)
        guard let fft = FFT(length: l) else { return [] }

        var re = ir + [Float](repeating: 0, count: l - ir.count)
        var im = [Float](repeating: 0, count: l)
        fft.forward(&re, &im)

        // Analytic signal spectrum: keep DC and Nyquist, double 1..N/2-1, zero the rest.
        let half = l / 2
        for i in 1..<half {
            re[i] *= 2
            im[i] *= 2
        }
        for i in (half + 1)..<l {
            re[i] = 0
            im[i] = 0
        }
        fft.inverse(&re, &im)

        var envelope = [Float](repeating: 0, count: ir.count)
        var peak: Float = 0
        for i in 0..<ir.count {
            let m = sqrt(re[i] * re[i] + im[i] * im[i])
            envelope[i] = m
            peak = max(peak, m)
        }
        guard peak > 0 else { return envelope }
        return envelope.map { 20 * log10(max($0 / peak, 1e-10)) }
    }

    /// Step response: running integral of the impulse response, peak-normalized.
    public static func stepResponse(ir: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: ir.count)
        var acc: Double = 0
        var peak: Double = 0
        for i in 0..<ir.count {
            acc += Double(ir[i])
            out[i] = Float(acc)
            peak = max(peak, abs(acc))
        }
        if peak > 0 {
            let inv = Float(1.0 / peak)
            for i in 0..<out.count { out[i] *= inv }
        }
        return out
    }

    /// Minimum phase (degrees) from a magnitude response via the cepstral/Hilbert
    /// method (as in ARTA; accurate below fs/4). `magnitudeDB` covers bins 0...N/2.
    public static func minimumPhaseDegrees(magnitudeDB: [Float], fftSize: Int) -> [Float] {
        let bins = magnitudeDB.count
        guard bins == fftSize / 2 + 1, let fft = FFT(length: fftSize) else { return [] }

        // Build full symmetric log-magnitude spectrum ln|H|.
        var logMag = [Float](repeating: 0, count: fftSize)
        for i in 0..<bins { logMag[i] = magnitudeDB[i] * Float(log(10.0) / 20.0) }
        for i in bins..<fftSize { logMag[i] = logMag[fftSize - i] }

        // Real cepstrum.
        var re = logMag
        var im = [Float](repeating: 0, count: fftSize)
        fft.inverse(&re, &im) // IFFT of even-real spectrum -> real cepstrum

        // Fold: double causal part, zero anticausal (keep c[0] and c[N/2]).
        let half = fftSize / 2
        for i in 1..<half {
            re[i] *= 2
            re[fftSize - i] = 0
        }
        for i in 0..<fftSize { im[i] = 0 }

        // Forward FFT: imaginary part is the minimum phase.
        fft.forward(&re, &im)
        return (0..<bins).map { Float(Double(im[$0]) * 180.0 / .pi) }
    }

    /// Cumulative Spectral Decay: repeated FFTs over the IR with the start point
    /// advancing `blockShift` samples each slice and an apodizing rising edge.
    /// Returns one magnitude-dB slice per time step, normalized to the 0 dB peak
    /// of the first slice. Slice time axis: step index × blockShift / sampleRate.
    public static func cumulativeSpectralDecay(
        ir: [Float],
        startIndex: Int,
        fftLength: Int,
        blockShift: Int,
        maxBlocks: Int,
        risingEdgeSamples: Int = 8
    ) -> [[Float]] {
        guard let fft = FFT(length: fftLength), blockShift > 0 else { return [] }
        let bins = fftLength / 2 + 1
        var slices: [[Float]] = []
        var globalPeak: Float = 1e-20

        var magnitudes: [[Float]] = []
        for block in 0..<maxBlocks {
            let start = startIndex + block * blockShift
            guard start < ir.count else { break }

            var re = [Float](repeating: 0, count: fftLength)
            var im = [Float](repeating: 0, count: fftLength)
            let available = min(fftLength, ir.count - start)
            for i in 0..<available { re[i] = ir[start + i] }
            // Apodizing rising edge (Blackman-shaped) to avoid rectangular truncation splash.
            let edge = min(risingEdgeSamples, available)
            for i in 0..<edge {
                let x = Double(i) / Double(max(edge - 1, 1))
                re[i] *= Float(0.42 - 0.5 * cos(.pi * x) + 0.08 * cos(2 * .pi * x))
            }
            fft.forward(&re, &im)
            var mag = [Float](repeating: 0, count: bins)
            for b in 0..<bins {
                mag[b] = sqrt(re[b] * re[b] + im[b] * im[b])
                if block == 0 { globalPeak = max(globalPeak, mag[b]) }
            }
            magnitudes.append(mag)
        }

        for mag in magnitudes {
            slices.append(mag.map { 20 * log10(max($0 / globalPeak, 1e-10)) })
        }
        return slices
    }
}
