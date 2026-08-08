import Foundation

/// Single-channel real-time spectrum: windowed frame → FFT → power → temporal
/// average → fractional-octave smoothing → dB.
///
/// Pure state machine — no audio I/O and no UI, matching the ArtaDSP target
/// contract. The caller owns capture and hop timing and hands over one
/// `fftSize`-long frame per hop.
///
/// Architecture note: this is deliberately a *single* FFT plus fractional-octave
/// banding, not a multi-resolution/constant-Q engine. Smaart reserves its
/// multi-time-window approach for dual-channel transfer functions and states that
/// for RTA "the use of fractional octave banding effectively nullifies the excess
/// high-frequency resolution issue" — so one FFT plus `Smoothing` is the right
/// shape here, and much less machinery.
public final class RTASpectrum {

    /// First-order exponential time weighting. Fast and Slow are the IEC 61672
    /// sound-level-meter time constants (125 ms / 1 s) that Smaart's Fast/Slow
    /// also model — the main lever for the smooth look, far more than spectral
    /// smoothing is.
    public enum Averaging: Hashable {
        case off
        case fast
        case slow
        case custom(seconds: Double)

        /// Time constant in seconds; nil means no temporal averaging.
        public var timeConstant: Double? {
            switch self {
            case .off: return nil
            case .fast: return 0.125
            case .slow: return 1.0
            case .custom(let seconds): return max(seconds, 0.001)
            }
        }
    }

    public let fftSize: Int
    public let sampleRate: Double
    public let binCount: Int
    public let frequencies: [Double]

    public var smoothing: Int
    public var averaging: Averaging
    /// Seconds of *new* audio between successive frames. The averager derives its
    /// per-frame coefficient from this, so the time constant stays honest when the
    /// FFT size or overlap changes — without it, "Fast" would mean different things
    /// at 2048 and 32768.
    public var hopSeconds: Double

    private let fft: FFT
    private let windowSamples: [Float]
    private let windowGain: Float
    private var averagePower: [Float] = []

    public init?(fftSize: Int, sampleRate: Double, hopSeconds: Double,
                 smoothing: Int = 6, averaging: Averaging = .fast,
                 window: Window = .hann) {
        guard let fft = FFT(length: fftSize), sampleRate > 0, hopSeconds > 0 else { return nil }
        self.fft = fft
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.hopSeconds = hopSeconds
        self.smoothing = smoothing
        self.averaging = averaging
        self.binCount = fftSize / 2 + 1
        self.windowSamples = window.samples(count: fftSize)
        self.windowGain = max(window.coherentGain(count: fftSize), 1e-6)
        let df = sampleRate / Double(fftSize)
        self.frequencies = (0..<(fftSize / 2 + 1)).map { Double($0) * df }
    }

    /// Drop the running average (peak-hold style reset, or after a settings change).
    public func reset() { averagePower = [] }

    /// One frame in, one dB spectrum out (bins 0...N/2). Returns an empty array if
    /// the frame is the wrong length.
    ///
    /// Magnitude is corrected for the window's coherent gain so a full-scale sine
    /// reads 0 dBFS. Coherent gain is the correct correction for tones; broadband
    /// noise reads slightly low, but the *shape* — which is what you tune on — is
    /// unaffected.
    public func process(frame: [Float]) -> [Float] {
        guard frame.count == fftSize else { return [] }

        var re = [Float](repeating: 0, count: fftSize)
        var im = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize { re[i] = frame[i] * windowSamples[i] }
        fft.forward(&re, &im)

        let norm = Float(fftSize) * windowGain
        let nyquistBin = fftSize % 2 == 0 ? binCount - 1 : -1
        var power = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            // Fold the negative-frequency half into the positive bins — except DC
            // and Nyquist, which have no mirror twin.
            let sided: Float = (i == 0 || i == nyquistBin) ? 1 : 2
            let amp = sqrt(re[i] * re[i] + im[i] * im[i]) * sided / norm
            power[i] = amp * amp
        }

        // Average in the power domain: it matches SPL-meter behaviour and avoids
        // the bias toward quiet frames that averaging dB directly would introduce.
        if let tau = averaging.timeConstant {
            let alpha = Float(1 - exp(-hopSeconds / tau))
            if averagePower.count != binCount {
                averagePower = power
            } else {
                for i in 0..<binCount {
                    averagePower[i] += alpha * (power[i] - averagePower[i])
                }
            }
            power = averagePower
        } else {
            averagePower = []
        }

        if smoothing > 0 {
            power = Smoothing.fractionalOctave(
                power: power, sampleRate: sampleRate, fftSize: fftSize, n: smoothing)
        }
        return Smoothing.powerToDB(power)
    }
}

// MARK: - Phase unwrapping

public enum PhaseUnwrap {
    /// Turn a ±180°-wrapped phase response into one continuous line by
    /// accumulating a ±360° offset whenever consecutive values step more than half
    /// a turn.
    ///
    /// Unwrap only over the span you intend to *read*: outside a sweep's band the
    /// deconvolution returns noise, and unwrapping through noise accumulates a
    /// bogus offset that corrupts the slope of the in-band data.
    public static func degrees(_ wrapped: [Float]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(wrapped.count)
        var offset = 0.0
        var previousRaw: Double? = nil
        for value in wrapped {
            let raw = Double(value)
            if let previous = previousRaw {
                let step = raw - previous
                if step > 180 { offset -= 360 } else if step < -180 { offset += 360 }
            }
            out.append(raw + offset)
            previousRaw = raw
        }
        return out
    }
}
