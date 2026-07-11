import Foundation

/// Impulse response extraction and delay estimation from excitation/response pairs.
public enum Deconvolution {

    /// Round-trip / propagation delay via generalized cross-correlation:
    /// peak of IFFT(conj(X)·Y). This is ARTA's "Crosscorrelation/delay estimation".
    /// Returns the lag in samples (positive = `measured` lags `reference`) and the
    /// normalized correlation coefficient at the peak (1.0 = identical signals).
    public static func estimateDelay(reference: [Float], measured: [Float]) -> (lagSamples: Int, correlation: Float) {
        let l = FFT.nextPowerOfTwo(reference.count + measured.count)
        guard let fft = FFT(length: l) else { return (0, 0) }

        var xRe = reference + [Float](repeating: 0, count: l - reference.count)
        var xIm = [Float](repeating: 0, count: l)
        var yRe = measured + [Float](repeating: 0, count: l - measured.count)
        var yIm = [Float](repeating: 0, count: l)
        fft.forward(&xRe, &xIm)
        fft.forward(&yRe, &yIm)

        var (cRe, cIm) = ComplexOps.conjugateMultiply(aRe: xRe, aIm: xIm, bRe: yRe, bIm: yIm)
        fft.inverse(&cRe, &cIm)

        var peakIdx = 0
        var peakVal: Float = -.infinity
        for i in 0..<l where abs(cRe[i]) > peakVal {
            peakVal = abs(cRe[i])
            peakIdx = i
        }
        // Lags >= L/2 are negative (circular correlation with zero padding).
        let lag = peakIdx >= l / 2 ? peakIdx - l : peakIdx

        let energyX = reference.reduce(Float(0)) { $0 + $1 * $1 }
        let energyY = measured.reduce(Float(0)) { $0 + $1 * $1 }
        let norm = sqrt(energyX * energyY)
        let coeff = norm > 0 ? peakVal / norm : 0
        return (lag, min(coeff, 1.0))
    }

    /// Impulse response by spectral division H = Y·conj(X) / (|X|² + ε), h = IFFT(H).
    /// Works for any excitation with energy across the band (sweep, noise, MLS).
    /// `relativeRegularization` guards division in bands where the excitation has
    /// no energy (outside sweep range); it is relative to the peak of |X|².
    public static func impulseResponse(
        excitation: [Float],
        response: [Float],
        relativeRegularization: Float = 1e-6
    ) -> [Float] {
        let l = FFT.nextPowerOfTwo(max(excitation.count, response.count) * 2)
        guard let fft = FFT(length: l) else { return [] }

        var xRe = excitation + [Float](repeating: 0, count: l - excitation.count)
        var xIm = [Float](repeating: 0, count: l)
        var yRe = response + [Float](repeating: 0, count: l - response.count)
        var yIm = [Float](repeating: 0, count: l)
        fft.forward(&xRe, &xIm)
        fft.forward(&yRe, &yIm)

        let xMagSq = ComplexOps.magnitudeSquared(re: xRe, im: xIm)
        let eps = (xMagSq.max() ?? 1) * relativeRegularization

        var (hRe, hIm) = ComplexOps.regularizedDivide(aRe: yRe, aIm: yIm, bRe: xRe, bIm: xIm, eps: eps)
        fft.inverse(&hRe, &hIm)
        return hRe
    }
}
