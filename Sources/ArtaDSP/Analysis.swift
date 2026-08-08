import Foundation

/// Time-domain analyses derived from the impulse response: ETC (impulse response
/// envelope via Hilbert transform), step response, and minimum phase support.
public enum Analysis {

    /// Envelope of a signal via the analytic-signal magnitude (Hilbert): FFT → zero
    /// negative frequencies (double positive) → IFFT → |·|. Returns LINEAR values in
    /// the input's own units, one per input sample. This is the raised-cosine
    /// envelope reading for a shaped tone burst (Linkwitz) and the shared core of
    /// the ETC. A pure sine returns a flat line at its amplitude.
    public static func analyticEnvelope(_ signal: [Float]) -> [Float] {
        guard !signal.isEmpty else { return [] }
        let l = FFT.nextPowerOfTwo(signal.count)
        guard let fft = FFT(length: l) else { return [] }

        var re = signal + [Float](repeating: 0, count: l - signal.count)
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

        var envelope = [Float](repeating: 0, count: signal.count)
        for i in 0..<signal.count {
            envelope[i] = sqrt(re[i] * re[i] + im[i] * im[i])
        }
        return envelope
    }

    /// Impulse response envelope (Energy-Time Curve) in dB, normalized to 0 dB peak.
    public static func energyTimeCurveDB(ir: [Float]) -> [Float] {
        let envelope = analyticEnvelope(ir)
        guard let peak = envelope.max(), peak > 0 else { return envelope }
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

    /// Locate a shaped tone burst's ONSET in a capture, by the analytic-envelope
    /// peak rather than cross-correlation: the envelope of a shaped burst peaks at
    /// its centre and is phase-insensitive, so it stays a stable time marker at low
    /// frequencies where a correlation smears across a full period and drifts onto
    /// late room energy. The onset is half a burst-length before that peak (the
    /// raised-cosine peaks at T/2).
    ///
    /// `scheduledOnsetSample` is where the digital send begins in this same buffer.
    /// The search runs from slightly before it to well after, since the acoustic
    /// arrival is a bounded converter/propagation latency later.
    ///
    /// Returns `nil` rather than a plausible-looking guess when the capture cannot
    /// answer: too short to contain the search window, or silent within it.
    public static func burstArrivalIndex(
        in captured: [Float],
        scheduledOnsetSample: Int,
        burstLengthSamples: Int,
        sampleRate: Double,
        frequency: Double
    ) -> Int? {
        let searchStart = max(0, scheduledOnsetSample - Int(0.005 * sampleRate))
        let searchEnd = min(captured.count,
                            scheduledOnsetSample + burstLengthSamples + Int(0.2 * sampleRate))
        // A short capture (stalled input device hitting the wait deadline) leaves the
        // search window past the end of the data. Refuse — don't index out of range.
        guard searchStart < searchEnd else { return nil }
        let region = Array(captured[searchStart..<searchEnd])
        // Light smoothing (quarter-period) so noise ripple can't steal the peak.
        let regionEnv = smoothed(analyticEnvelope(region),
                                 window: max(1, Int(sampleRate / max(frequency, 1) / 4)))
        var centreIdx = 0
        var centrePeak: Float = 0
        for (i, v) in regionEnv.enumerated() where v > centrePeak { centrePeak = v; centreIdx = i }
        // A silent region has no burst to locate. Without this the loop never runs,
        // centreIdx stays 0, and the search-window start gets reported as a real
        // arrival — a confident number from a capture that contains nothing.
        guard centrePeak > 0 else { return nil }
        return max(0, searchStart + centreIdx - burstLengthSamples / 2)
    }

    /// Centred boxcar moving average, edges left as the original — enough to keep
    /// noise ripple from stealing the envelope-peak search without shifting it.
    private static func smoothed(_ x: [Float], window: Int) -> [Float] {
        guard window > 1, x.count >= window else { return x }
        let half = window / 2
        var out = x
        var acc: Double = 0
        for i in 0..<x.count {
            acc += Double(x[i])
            if i >= window { acc -= Double(x[i - window]) }
            if i >= window - 1 { out[i - half] = Float(acc / Double(window)) }
        }
        return out
    }

    /// Arrival-time delta, in seconds, between two tone-burst captures. Each side's
    /// raw arrival-offset sample count is converted to seconds using its OWN sample
    /// rate BEFORE subtracting — diffing raw sample counts across two captures at
    /// different device sample rates would silently give a wrong answer. Positive
    /// means `current` arrived later than `reference`.
    public static func burstArrivalDeltaSeconds(
        referenceOffsetSamples: Int, referenceSampleRate: Double,
        currentOffsetSamples: Int, currentSampleRate: Double
    ) -> Double {
        (Double(currentOffsetSamples) / currentSampleRate)
            - (Double(referenceOffsetSamples) / referenceSampleRate)
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
