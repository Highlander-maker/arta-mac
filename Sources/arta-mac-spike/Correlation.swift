import Accelerate
import Foundation

/// Result of a generalized cross-correlation between a reference (played)
/// signal and a captured (recorded) signal.
struct CorrelationResult {
    /// Raw index of the peak in the circular correlation buffer [0, fftSize).
    let peakIndex: Int
    /// Resolved lag in samples: how far the captured signal lags the reference.
    /// Indices above fftSize/2 are interpreted as negative (wrapped) lags.
    let lagSamples: Int
    /// Correlation value at the peak.
    let peakValue: Float
    /// Peak magnitude vs RMS of the rest of the correlation, in dB.
    /// A confident detection is typically well above ~12 dB.
    let peakToNoiseDB: Float
    let fftSize: Int
}

/// Generalized cross-correlation of `captured` against `reference`
/// (ARTA "System Delay Estimation" style, manual section 4.5):
/// FFT both, cross-spectrum S = CAP * conj(REF), optionally PHAT-normalize
/// each bin to unit magnitude, inverse FFT. The peak position is the delay
/// of `captured` relative to `reference`, to sample accuracy.
func generalizedCrossCorrelation(
    reference: [Float],
    captured: [Float],
    phat: Bool = true
) -> CorrelationResult? {
    guard !reference.isEmpty, !captured.isEmpty else { return nil }

    // Zero-pad to a power of two >= ref + cap so circular correlation is
    // effectively linear (no wrap-around ambiguity within the signal span).
    let needed = reference.count + captured.count
    var log2n: vDSP_Length = 1
    while (1 << log2n) < needed { log2n += 1 }
    let n = 1 << Int(log2n)

    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
    defer { vDSP_destroy_fftsetup(setup) }

    func makeBuffer(_ source: [Float]) -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
        p.initialize(repeating: 0, count: n)
        source.withUnsafeBufferPointer { src in
            p.update(from: src.baseAddress!, count: src.count)
        }
        return p
    }
    func makeZeroBuffer() -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
        p.initialize(repeating: 0, count: n)
        return p
    }

    let refRe = makeBuffer(reference), refIm = makeZeroBuffer()
    let capRe = makeBuffer(captured), capIm = makeZeroBuffer()
    let outRe = makeZeroBuffer(), outIm = makeZeroBuffer()
    defer {
        refRe.deallocate(); refIm.deallocate()
        capRe.deallocate(); capIm.deallocate()
        outRe.deallocate(); outIm.deallocate()
    }

    var refSplit = DSPSplitComplex(realp: refRe, imagp: refIm)
    var capSplit = DSPSplitComplex(realp: capRe, imagp: capIm)
    var outSplit = DSPSplitComplex(realp: outRe, imagp: outIm)

    // Forward FFTs.
    vDSP_fft_zip(setup, &refSplit, 1, log2n, FFTDirection(FFT_FORWARD))
    vDSP_fft_zip(setup, &capSplit, 1, log2n, FFTDirection(FFT_FORWARD))

    // Cross-spectrum: out = conj(REF) * CAP  (conjugate flag -1 conjugates A).
    vDSP_zvmul(&refSplit, 1, &capSplit, 1, &outSplit, 1, vDSP_Length(n), -1)

    if phat {
        // PHAT weighting: normalize every bin to unit magnitude, so the
        // inverse transform peak depends on phase alignment only. This is
        // the "normalized cross-spectrum" of the GCC and gives a sharp,
        // sample-accurate peak that is robust to the sweep's non-flat
        // spectrum and to frequency-dependent gain in the loop.
        let eps: Float = 1e-12
        for i in 0..<n {
            let re = outRe[i], im = outIm[i]
            let mag = (re * re + im * im).squareRoot()
            if mag > eps {
                outRe[i] = re / mag
                outIm[i] = im / mag
            } else {
                outRe[i] = 0
                outIm[i] = 0
            }
        }
    }

    // Inverse FFT and 1/n scaling -> circular cross-correlation.
    vDSP_fft_zip(setup, &outSplit, 1, log2n, FFTDirection(FFT_INVERSE))
    var scale = Float(1.0) / Float(n)
    vDSP_vsmul(outRe, 1, &scale, outRe, 1, vDSP_Length(n))
    vDSP_vsmul(outIm, 1, &scale, outIm, 1, vDSP_Length(n))

    // Peak by magnitude of the real part (imag should be ~0 for real inputs).
    var peakMag: Float = 0
    var peakIdx: vDSP_Length = 0
    vDSP_maxmgvi(outRe, 1, &peakMag, &peakIdx, vDSP_Length(n))
    let peakIndex = Int(peakIdx)
    let peakValue = outRe[peakIndex]

    // Peak-to-noise: RMS of the correlation excluding +/- window around peak.
    var sumSq: Float = 0
    vDSP_svesq(outRe, 1, &sumSq, vDSP_Length(n))
    let window = 64
    var excluded: Float = 0
    var excludedCount = 0
    for i in max(0, peakIndex - window)...min(n - 1, peakIndex + window) {
        excluded += outRe[i] * outRe[i]
        excludedCount += 1
    }
    let remaining = max(1, n - excludedCount)
    let noiseRMS = max(1e-20, ((sumSq - excluded) / Float(remaining)).squareRoot())
    let peakToNoiseDB = 20 * log10(peakMag / noiseRMS)

    let lag = peakIndex <= n / 2 ? peakIndex : peakIndex - n

    return CorrelationResult(
        peakIndex: peakIndex,
        lagSamples: lag,
        peakValue: peakValue,
        peakToNoiseDB: peakToNoiseDB,
        fftSize: n
    )
}
