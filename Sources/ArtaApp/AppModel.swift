import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ArtaDSP

/// A named magnitude curve for plotting (current measurement, overlays, targets),
/// optionally carrying its own phase.
///
/// Phase travels *with* the curve so a snapshotted overlay keeps the phase it was
/// measured with — that's what makes "measure tops, set as overlay, measure subs,
/// compare both phase traces through the crossover" possible. Empty = none captured.
struct FRCurve: Identifiable {
    let id = UUID()
    var name: String
    var frequencies: [Double]
    var magnitudesDB: [Float]
    var color: Color
    var isTarget: Bool = false
    var phaseDegrees: [Float] = []
    /// Drawn thinner than a measurement — a predicted curve shouldn't visually
    /// outweigh the two measured ones it was derived from.
    var isCombined: Bool = false

    // MARK: Complex spectrum (for trial delay and summation)
    //
    // Empty for curves with no complex data behind them — a `.frd` target loaded
    // from disk is magnitude and phase only, and cannot be summed.
    //
    // **Referenced to impulse-response sample 0, not to the gate start.** A gated
    // FFT's t=0 is wherever the operator put the gate, which moves between
    // measurements; two curves referenced that way would sum as though already
    // aligned, and report τ=0 as correct when it isn't. Sample 0 is a common
    // electrical instant across measurements on one routing, so the real arrival
    // difference survives into the sum.
    var hRe: [Float] = []
    var hIm: [Float] = []
    /// Direct-sound arrival relative to that same sample-0 origin. Removing it is
    /// what turns the absolute spectrum back into the displayed phase.
    var arrivalSeconds: Double = 0
    var sampleRate: Double = 0
    var fftSize: Int = 0

    var hasComplexSpectrum: Bool { !hRe.isEmpty && hRe.count == frequencies.count }
}

/// Band-focused sweep presets. Concentrating the sweep in the band under test
/// puts all the excitation energy where you're working — longer LF sweeps for
/// subs (better S/N below 100 Hz), shorter full/HF sweeps for speed.
enum SweepPreset: String, CaseIterable, Identifiable {
    case fullRange = "Full range"
    case sub = "Subwoofer"
    case crossover = "Sub/Top crossover"
    case midHigh = "Mid–High (1 kHz+)"
    case custom = "Custom"

    var id: String { rawValue }

    /// (f1, f2, sweepSeconds, decayWaitSeconds); nil = leave fields alone.
    var settings: (f1: Double, f2: Double, duration: Double, decay: Double)? {
        switch self {
        case .fullRange: return (20, 20_000, 1.0, 1.0)
        case .sub:       return (15, 250, 3.0, 2.0)
        case .crossover: return (30, 400, 2.0, 1.5)
        case .midHigh:   return (800, 20_000, 1.0, 0.5)
        case .custom:    return nil
        }
    }

    var subtitle: String {
        switch self {
        case .fullRange: return "20 Hz – 20 kHz · 1 s"
        case .sub:       return "15 – 250 Hz · 3 s"
        case .crossover: return "30 – 400 Hz · 2 s"
        case .midHigh:   return "800 Hz – 20 kHz · 1 s"
        case .custom:    return "manual range"
        }
    }
}

/// Generator signal choices for alignment tones.
enum GeneratorMode: String, CaseIterable, Identifiable {
    case sine = "Sine"
    case pink = "Pink noise"
    case pinkBand = "Pink band"
    var id: String { rawValue }
}

final class AppModel: ObservableObject {

    // MARK: Devices & measurement settings

    @Published var devices: [AudioDevice] = []
    @Published var inputDeviceID: AudioDeviceID?
    @Published var outputDeviceID: AudioDeviceID?
    @Published var inputChannel = 0
    @Published var outputChannel = 0
    // Dual-channel loop reference: an unused output patched back into a second
    // input channel, used as the deconvolution excitation instead of the
    // generated sweep — cancels the interface's own DA→AD path/jitter.
    @Published var useLoopReference = false
    @Published var referenceChannel = 1
    @Published var sweepDuration = 1.0
    @Published var f1 = 20.0
    @Published var f2 = 20_000.0
    @Published var outputLevelDB = -12.0
    @Published var postSilence = 1.0
    @Published var sweepPreset: SweepPreset = .fullRange

    // MARK: Generator (alignment tones)

    @Published var generatorMode: GeneratorMode = .sine
    @Published var generatorFrequency = 1000.0
    @Published var generatorFraction = 1          // pink band: 1/1 or 1/3 octave
    @Published var generatorLevelDB = -20.0
    @Published var generatorRunning = false
    private let generator = GeneratorEngine()

    // MARK: Shaped tone burst (Linkwitz single-frequency dynamic test)

    @Published var burstFrequency = 1000.0
    @Published var burstCycles = 5
    /// Gaussian is the minimum time–bandwidth envelope, so it gives the sharpest
    /// centre to align to — Digby's choice for wavelet alignment. Raised cosine is
    /// Linkwitz's original and stays the default so existing results are unchanged.
    @Published var burstEnvelope: SignalGenerator.BurstEnvelope = .raisedCosine
    @Published var isBursting = false
    @Published var burstResult: BurstResult?
    // Continuous tone at the burst frequency/level for gain-staging the mic before
    // firing — so the meter reading previews the burst's own peak.
    @Published var burstLevelChecking = false
    // Frozen reference burst for arrival-time delta (fire through main → freeze →
    // fire through sub → read Δ). A single BurstResult rather than a handful of
    // parallel scalars (cf. frozenIR/frozenIRPeak/frozenIRPeakIndex below) because
    // the mismatch check needs frequency alongside the arrival data.
    @Published var frozenBurst: BurstResult?

    // MARK: Alignment click (sub/top time alignment by ear)

    @Published var clickChannelA = 0     // e.g. main hang
    @Published var clickChannelB = 1     // e.g. subs
    @Published var clickDelayMsB = 0.0   // + = sub later than main, - = sub earlier
    @Published var clickRateHz = 2.0
    @Published var clickLevelDB = -20.0
    @Published var clickRunning = false
    private let clickEngine = AlignmentClickEngine()

    // MARK: Measurement state

    @Published var isMeasuring = false
    @Published var statusMessage = "Ready. Select devices and press Measure."
    @Published var impulseResponse: [Float] = []
    /// Bumped every time the IR is replaced or dropped. Background analyses
    /// capture it before dispatching and compare on the way back, so a slow
    /// computation can't publish the previous measurement's numbers under the
    /// current one. Also drives the views that cache their own derived data
    /// (ETC/step/CSD) — watching `impulseResponse.count` missed the common case
    /// of two measurements with identical sweep settings, which produce IRs of
    /// exactly the same length.
    @Published private(set) var irGeneration = 0
    @Published var irSampleRate: Double = 48000
    @Published var systemDelaySamples: Double = 0
    @Published var lastPeakDBFS: Float? = nil
    @Published var lastCorrelationDB: Float? = nil

    // IR view state (sample indices)
    @Published var cursorSample: Int = 0
    @Published var markerSample: Int? = nil

    // IR zoom/pan: visible window in sample indices. length 0 == full view.
    @Published var irViewStart: Int = 0
    @Published var irViewLength: Int = 0
    // Vertical (amplitude) magnification — blows up the low-level room decay tail.
    @Published var irAmpZoom: Double = 1
    // Full-signal peak + direct-sound index, cached so the IR redraw doesn't
    // rescan 190k samples per scroll frame (that was the scroll lag).
    @Published var irPeak: Float = 1
    @Published var irPeakIndex: Int = 0
    private let irMinVisibleSamples = 32

    // Frozen reference IR for delay comparison (freeze → move mic → measure).
    @Published var frozenIR: [Float] = []
    @Published var frozenIRPeak: Float = 1
    @Published var frozenIRPeakIndex: Int = 0

    // MARK: Frequency response state

    @Published var currentFR: FRCurve?
    @Published var overlays: [FRCurve] = []
    @Published var smoothing = 6          // 1/n octave; 0 = unsmoothed
    @Published var gateMs = 200.0
    @Published var gateTailFraction = 0.5 // gate window taper: 0 = uniform, up to Hann50%
    @Published var fftSize = 65536
    /// FFT size actually used by the last recompute. May exceed `fftSize` when the
    /// gate is longer than the picked size (see the clamp in recomputeFrequencyResponse).
    @Published var effectiveFFTSize = 65536
    @Published var showPhase = false
    /// Unwrap phase across the *visible* frequency span instead of wrapping to ±180°.
    /// Wrapped phase turns into an unreadable sawtooth once there's any real offset
    /// between sources; unwrapping over just the zoomed band (rather than the whole
    /// sweep) keeps the degree range small and avoids dragging in out-of-band noise.
    @Published var phaseUnwrap = false
    @Published var currentPhase: [Float] = []

    // MARK: FR frequency-axis zoom (right-drag a band on the plot, Esc to reset)
    //
    // The visible span is measurement state, not a view detail: phase unwraps
    // across whatever is on screen (see FRPlotView.phaseTraces), so zooming into
    // the crossover band is what makes phase readable enough to align on.
    @Published var frLow: Double = FRPlotView.fullLow
    @Published var frHigh: Double = FRPlotView.fullHigh

    var frIsZoomed: Bool { frLow > FRPlotView.fullLow || frHigh < FRPlotView.fullHigh }

    // MARK: Trial delay & summation
    //
    // Slide a delay onto the live curve and watch its phase rotate against a
    // frozen overlay's — the laptop half of a crossover alignment. With Combine
    // on, the predicted sum is drawn too, which answers the question phase-match
    // alone can't: how deep is the notch you're left with.

    /// Delay applied to the live curve, milliseconds. Signed — negative advances
    /// it, which is how you delay the *other* source without re-measuring.
    @Published var trialDelayMs: Double = 0
    @Published var showCombined = false
    /// Which overlay the live curve is summed against. nil = the most recent one
    /// that carries a complex spectrum.
    @Published var combineWithID: UUID? = nil

    /// Overlays that can take part in a summation. A `.frd` target loaded from
    /// disk is magnitude and phase only, so it never appears here.
    var combinableOverlays: [FRCurve] {
        overlays.filter { $0.hasComplexSpectrum && !$0.isTarget }
    }

    var trialDelayAvailable: Bool { currentFR?.hasComplexSpectrum ?? false }

    /// The overlay currently paired with the live curve for summation.
    var combinePartner: FRCurve? {
        if let id = combineWithID, let match = combinableOverlays.first(where: { $0.id == id }) {
            return match
        }
        return combinableOverlays.last
    }

    /// Why summation is unavailable, or nil when it's fine. Stated rather than
    /// silently drawing nothing.
    var combineBlockedReason: String? {
        guard let cur = currentFR, cur.hasComplexSpectrum else {
            return "Measure a response first."
        }
        guard let other = combinePartner else {
            return "Set a measurement as overlay to sum against."
        }
        guard other.frequencies.count == cur.frequencies.count,
              other.sampleRate == cur.sampleRate, other.fftSize == cur.fftSize
        else {
            return "Overlay was measured at a different FFT size or sample rate — not comparable."
        }
        return nil
    }

    /// The live curve as drawn: same magnitude, phase rotated by the trial delay.
    /// A delay doesn't touch magnitude, so only the phase trace moves — which is
    /// the point. Slide until it lies on the overlay's through the crossover.
    var currentDisplayCurve: FRCurve? {
        guard let fr = currentFR else { return nil }
        guard trialDelayMs != 0, fr.hasComplexSpectrum else { return fr }
        let shifted = Summation.delayed(
            hRe: fr.hRe, hIm: fr.hIm, frequencies: fr.frequencies,
            seconds: trialDelayMs / 1000.0)
        var out = fr
        out.name = String(format: "Current %+.2f ms", trialDelayMs)
        out.hRe = shifted.re
        out.hIm = shifted.im
        out.phaseDegrees = Summation.phaseDegrees(
            re: shifted.re, im: shifted.im, frequencies: fr.frequencies,
            removingDelay: fr.arrivalSeconds)
        return out
    }

    /// Predicted sum of the overlay and the delayed live curve.
    ///
    /// Smoothed the same way the source curves are, so the three traces are
    /// visually comparable — an unsmoothed sum drawn over two smoothed sources
    /// reads as though the summation itself were ragged.
    var combinedCurve: FRCurve? {
        guard showCombined, combineBlockedReason == nil,
              let cur = currentFR, let other = combinePartner
        else { return nil }

        let shifted = Summation.delayed(
            hRe: cur.hRe, hIm: cur.hIm, frequencies: cur.frequencies,
            seconds: trialDelayMs / 1000.0)
        guard let summed = Summation.sum(
            aRe: other.hRe, aIm: other.hIm, bRe: shifted.re, bIm: shifted.im)
        else { return nil }

        let mags: [Float]
        if smoothing > 0 {
            let smoothed = Smoothing.fractionalOctave(
                power: Summation.power(re: summed.re, im: summed.im),
                sampleRate: cur.sampleRate, fftSize: cur.fftSize, n: smoothing)
            mags = Smoothing.powerToDB(smoothed)
        } else {
            mags = Summation.magnitudeDB(re: summed.re, im: summed.im)
        }

        // Referenced to the overlay's arrival so that, with a matching pair and no
        // trial delay, the combined phase lands on the sources' own phase rather
        // than an arbitrary offset from it.
        let phase = Summation.phaseDegrees(
            re: summed.re, im: summed.im, frequencies: cur.frequencies,
            removingDelay: other.arrivalSeconds)

        return FRCurve(name: "Combined", frequencies: cur.frequencies,
                       magnitudesDB: mags, color: PlotStyle.combined,
                       phaseDegrees: phase, isCombined: true)
    }

    func nudgeTrialDelay(_ ms: Double) {
        trialDelayMs = min(max(((trialDelayMs + ms) * 100).rounded() / 100, -100), 100)
    }

    func zeroTrialDelay() { trialDelayMs = 0 }

    // MARK: Room acoustics

    @Published var roomParams: RoomAcousticParams?
    @Published var bandParams: [(center: Double, params: RoomAcousticParams)] = []
    @Published var stiResult: STIResult?

    // MARK: Input meter (live gain-staging, independent of Measure)
    //
    // Its own ObservableObject so the ~23 Hz level updates only re-render the
    // small meter view, not the whole sidebar Form (that was the drag lag).
    let meter = InputMeter()

    // MARK: RTA (live spectrum)
    //
    // Shares the one input device with the meter and with measurement, so only one
    // of them may hold a tap at a time — see startRTA/resumeIdleAudio.

    let rta = RTA()
    @Published var rtaFFTSize = 8192
    @Published var rtaSmoothing = 6
    /// Temporal weighting. Fast/Slow are the IEC 61672 SPL-meter time constants
    /// (125 ms / 1 s) — the main lever for a steady, readable display.
    @Published var rtaAveraging: RTASpectrum.Averaging = .fast
    @Published var rtaPeakHold = false
    /// Whether the RTA *should* be running (i.e. its tab is showing). Kept separate
    /// from `rta.running` so the input can be lent to a sweep and handed back after.
    @Published var rtaWanted = false

    private let engine = MeasurementEngine()
    private let overlayPalette = PlotStyle.overlayPalette

    init() {
        refreshDevices()
        startMeter()
    }

    // MARK: Actions

    func refreshDevices() {
        devices = AudioDevices.all().filter { $0.inputChannels > 0 || $0.outputChannels > 0 }
        if inputDeviceID == nil { inputDeviceID = AudioDevices.defaultDeviceID(input: true) }
        if outputDeviceID == nil { outputDeviceID = AudioDevices.defaultDeviceID(input: false) }
    }

    // MARK: Input meter

    func startMeter() {
        meter.start(inputDeviceID: inputDeviceID)
    }

    func stopMeter() {
        meter.stop()
    }

    /// Device pickers call this so the live view follows whichever interface is selected.
    func restartMeterForDeviceChange() {
        guard !isMeasuring, !isBursting else { return }
        resumeIdleAudio()
    }

    // MARK: RTA

    func startRTA() {
        rtaWanted = true
        // A sweep owns the input while it runs; resumeIdleAudio hands it back after.
        guard !isMeasuring, !isBursting else { return }
        rta.stop()
        stopMeter()
        rta.peakHoldEnabled = rtaPeakHold
        rta.start(inputDeviceID: inputDeviceID, channel: inputChannel,
                  fftSize: rtaFFTSize, smoothing: rtaSmoothing, averaging: rtaAveraging)
    }

    func stopRTA() {
        rtaWanted = false
        rta.stop()
        startMeter()
    }

    /// FFT size, smoothing and averaging are baked in when the engine starts, so a
    /// settings change needs a restart to take effect.
    func restartRTAIfRunning() {
        guard rtaWanted else { return }
        startRTA()
    }

    /// Give the input back to whichever live view wants it once a sweep or burst
    /// has finished with it.
    func resumeIdleAudio() {
        if rtaWanted { startRTA() } else { startMeter() }
    }

    /// Preset selection writes the sweep fields; manual edits flip back to Custom.
    func applyPreset(_ preset: SweepPreset) {
        guard let s = preset.settings else { return }
        f1 = s.f1
        f2 = s.f2
        sweepDuration = s.duration
        postSilence = s.decay
    }

    /// Field onChange fires on the next view cycle, so a transient "applying"
    /// flag can't work — instead flip to Custom only when the fields genuinely
    /// no longer match the selected preset.
    func sweepFieldEdited() {
        guard let s = sweepPreset.settings else { return }
        if f1 != s.f1 || f2 != s.f2 || sweepDuration != s.duration || postSilence != s.decay {
            sweepPreset = .custom
        }
    }

    // MARK: Generator

    func toggleGenerator() {
        if generatorRunning {
            generator.stop()
            generatorRunning = false
            statusMessage = "Generator stopped."
            return
        }
        if clickRunning {
            clickEngine.stop()
            clickRunning = false
        }
        if burstLevelChecking {
            generator.stop()
            burstLevelChecking = false
        }
        let kind: GeneratorEngine.Kind
        switch generatorMode {
        case .sine: kind = .sine(frequency: generatorFrequency)
        case .pink: kind = .pink
        case .pinkBand: kind = .pinkBand(center: generatorFrequency, fraction: generatorFraction)
        }
        do {
            // With loop reference on, the generator also drives the loop output,
            // so In <loop> can be gain-staged against the live meters before a
            // measurement (avoid a clipped 0 dBFS reference).
            let loopCh = useLoopReference ? referenceChannel : nil
            try generator.start(
                kind: kind, levelDB: generatorLevelDB,
                outputDeviceID: outputDeviceID, outputChannel: outputChannel,
                loopChannel: loopCh)
            generatorRunning = true
            let outLabel = loopCh.map { "out \(outputChannel + 1) + loop out \($0 + 1)" }
                ?? "out \(outputChannel + 1)"
            switch generatorMode {
            case .sine:
                statusMessage = String(format: "Generator: %.0f Hz sine @ %.0f dBFS on %@.",
                                       generatorFrequency, generatorLevelDB, outLabel)
            case .pink:
                statusMessage = String(format: "Generator: pink noise @ %.0f dBFS on %@.",
                                       generatorLevelDB, outLabel)
            case .pinkBand:
                statusMessage = String(format: "Generator: 1/%d-oct pink @ %.0f Hz, %.0f dBFS on %@.",
                                       generatorFraction, generatorFrequency, generatorLevelDB, outLabel)
            }
            if loopCh != nil {
                statusMessage += String(format: " Aim In %d for −12…−6 dBFS on the meter.", referenceChannel + 1)
            }
        } catch {
            statusMessage = "Generator failed: \(error)"
        }
    }

    /// Restart with current settings if running (frequency/mode changed).
    func restartGeneratorIfRunning() {
        guard generatorRunning else { return }
        generator.stop()
        generatorRunning = false
        toggleGenerator()
    }

    func generatorLevelChanged() {
        if generatorRunning { generator.setLevel(dB: generatorLevelDB) }
    }

    // MARK: Alignment click

    func toggleAlignmentClick() {
        if clickRunning {
            clickEngine.stop()
            clickRunning = false
            statusMessage = "Alignment click stopped."
            return
        }
        if generatorRunning {
            generator.stop()
            generatorRunning = false
        }
        if burstLevelChecking {
            generator.stop()
            burstLevelChecking = false
        }
        do {
            try clickEngine.start(
                channelA: clickChannelA, channelB: clickChannelB, delayMsB: clickDelayMsB,
                rateHz: clickRateHz, levelDB: clickLevelDB, outputDeviceID: outputDeviceID)
            clickRunning = true
            statusMessage = String(
                format: "Alignment click: ch %d + ch %d, sub offset %.1f ms, %.1f Hz.",
                clickChannelA + 1, clickChannelB + 1, clickDelayMsB, clickRateHz)
        } catch {
            statusMessage = "Alignment click failed: \(error)"
        }
    }

    /// Delay/rate/channel changes need a re-render (the buffer bakes them in).
    func restartAlignmentClickIfRunning() {
        guard clickRunning else { return }
        clickEngine.stop()
        clickRunning = false
        toggleAlignmentClick()
    }

    func clickLevelChanged() {
        if clickRunning { clickEngine.setLevel(dB: clickLevelDB) }
    }

    // MARK: Shaped tone burst

    /// Fire a repeating shaped burst at the burst frequency and drive level so the
    /// live Input meter previews the *real burst's* mic peak — a short transient,
    /// not a continuous tone that a room mode would pump up (which over-reads at low
    /// frequencies). Aim the peak-hold at −12…−6 dBFS: high enough that the ring-out
    /// tail clears the room noise floor (a quiet capture reads the floor, not the
    /// sub), clear of clipping.
    func toggleBurstLevelCheck() {
        if burstLevelChecking {
            generator.stop()
            burstLevelChecking = false
            statusMessage = "Level check stopped."
            return
        }
        if generatorRunning { generator.stop(); generatorRunning = false }
        if clickRunning { clickEngine.stop(); clickRunning = false }
        do {
            let loopCh = useLoopReference ? referenceChannel : nil
            try generator.start(
                kind: .burstTrain(frequency: burstFrequency, cycles: burstCycles,
                                  envelope: burstEnvelope),
                levelDB: outputLevelDB,
                outputDeviceID: outputDeviceID, outputChannel: outputChannel,
                loopChannel: loopCh)
            burstLevelChecking = true
            statusMessage = String(
                format: "Level check: repeating %d-cyc burst @ %.0f Hz — drive the meter peak-hold to −12…−6 dBFS, then Burst.",
                burstCycles, burstFrequency)
        } catch {
            statusMessage = "Level check failed: \(error)"
        }
    }

    /// Frequency/cycles changed mid-check → re-render the preview burst to match.
    func restartBurstLevelCheckIfRunning() {
        guard burstLevelChecking else { return }
        generator.stop()
        burstLevelChecking = false
        toggleBurstLevelCheck()
    }

    /// Verdict on a mic peak-hold reading for burst gain-staging.
    static func levelVerdict(dBFS: Float) -> (text: String, ok: Bool, hot: Bool) {
        if dBFS > -3 { return ("CLIP RISK — back off", false, true) }
        if dBFS >= -12 { return ("GOOD", true, false) }
        if dBFS >= -24 { return ("OK — a touch more is better", true, false) }
        if dBFS <= -60 { return ("SILENT — check signal path", false, false) }
        return ("TOO LOW — tail will read noise", false, false)
    }

    func runBurst() {
        guard !isMeasuring, !isBursting else { return }
        if burstLevelChecking {
            generator.stop()
            burstLevelChecking = false
        }
        if generatorRunning {
            generator.stop()
            generatorRunning = false
        }
        if clickRunning {
            clickEngine.stop()
            clickRunning = false
        }
        isBursting = true
        statusMessage = String(format: "Bursting — %d cycles @ %.0f Hz...", burstCycles, burstFrequency)
        rta.stop()
        stopMeter()

        let settings = BurstSettings(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            inputChannel: inputChannel,
            outputChannel: outputChannel,
            frequency: burstFrequency,
            cycles: burstCycles,
            envelope: burstEnvelope,
            amplitudeDB: outputLevelDB,
            referenceChannel: useLoopReference ? referenceChannel : nil
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.engine.measureBurst(settings: settings)
                DispatchQueue.main.async {
                    self.apply(burst: result)
                    self.resumeIdleAudio()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBursting = false
                    // Drop the previous result rather than leaving it on screen as
                    // though it were this shot's. It matters most for the Δ readout:
                    // a failed shot at the sub would otherwise leave the frozen
                    // main's own Δ of 0.00 ms showing, which reads as "aligned"
                    // when nothing was measured at all. The frozen reference is
                    // held separately and survives, so re-firing is all that's lost.
                    self.burstResult = nil
                    self.statusMessage = "Burst failed: \(error)"
                    self.resumeIdleAudio()
                }
            }
        }
    }

    private func apply(burst: BurstResult) {
        burstResult = burst
        isBursting = false
        lastPeakDBFS = burst.capturedPeakDBFS

        // Ring-out: how far the envelope has decayed one burst-length after the
        // burst ends. A clean driver drops fast; a resonance holds energy and reads
        // only a few dB down — the number that makes "it's ringing" quantitative.
        let env = burst.responseEnvelope
        let peak = max(burst.responseEnvelopePeak, 1e-9)
        let burstEndIdx = burst.arrivalSample + burst.burstLengthSamples
        var ringSuffix = ""
        let ringIdx = burstEndIdx + burst.burstLengthSamples
        if ringIdx < env.count {
            let ringDB = 20 * log10(max(env[ringIdx], 1e-9) / peak)
            ringSuffix = String(format: " Ring-out %.0f dB one burst later.", ringDB)
        }

        statusMessage = String(
            format: "Burst done: %d cyc @ %.0f Hz, peak %.1f dBFS.%@",
            burst.cycles, burst.frequency, burst.capturedPeakDBFS, ringSuffix)
        if burst.capturedPeakDBFS < -60 {
            statusMessage += " WARNING: input nearly silent — check mic/signal path."
        }
    }

    func runMeasurement() {
        guard !isMeasuring else { return }
        if burstLevelChecking {
            generator.stop()
            burstLevelChecking = false
        }
        if generatorRunning {
            generator.stop()
            generatorRunning = false
        }
        if clickRunning {
            clickEngine.stop()
            clickRunning = false
        }
        isMeasuring = true
        statusMessage = "Measuring — playing sweep..."
        rta.stop()
        stopMeter()

        let settings = MeasurementSettings(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            inputChannel: inputChannel,
            outputChannel: outputChannel,
            f1: f1, f2: f2,
            sweepDuration: sweepDuration,
            amplitudeDB: outputLevelDB,
            postSilence: postSilence,
            referenceChannel: useLoopReference ? referenceChannel : nil
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.engine.measure(settings: settings)
                DispatchQueue.main.async {
                    self.apply(result: result)
                    self.resumeIdleAudio()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isMeasuring = false
                    // Nothing was measured, so nothing derived from the last
                    // measurement may stay on screen — see clearMeasurement().
                    self.clearMeasurement()
                    self.statusMessage = "Measurement failed: \(error)"
                    self.resumeIdleAudio()
                }
            }
        }
    }

    private func apply(result: MeasurementResult) {
        setImpulseResponse(result.impulseResponse, sampleRate: result.sampleRate)
        systemDelaySamples = result.systemDelaySamples
        lastPeakDBFS = result.capturedPeakDBFS
        lastCorrelationDB = result.correlationQualityDB
        isMeasuring = false

        // Default cursor: just before the IR peak; marker: gate later.
        let peakIdx = peakIndex(of: result.impulseResponse)
        cursorSample = max(0, peakIdx - 20)
        markerSample = min(result.impulseResponse.count - 1,
                           cursorSample + Int(gateMs / 1000.0 * result.sampleRate))
        irFit()

        let refLabel = result.usedLoopReference ? "loop ref" : "sweep ref"
        statusMessage = String(
            format: "Done (%@). Delay %.1f ms, mic peak %.1f dBFS, correlation %.0f dB. IR: %d samples @ %.0f Hz.",
            refLabel,
            result.systemDelaySamples / result.sampleRate * 1000,
            result.capturedPeakDBFS,
            result.correlationQualityDB,
            result.impulseResponse.count, result.sampleRate)
        if let refPeak = result.referencePeakDBFS {
            statusMessage += String(format: " Loop peak %.1f dBFS.", refPeak)
        }

        if result.capturedPeakDBFS < -60 {
            statusMessage += " WARNING: input nearly silent — check mic/loopback path."
        }
        if let refPeak = result.referencePeakDBFS, refPeak < -60 {
            statusMessage += " WARNING: loop channel nearly silent — the reference is unreliable; check the out→in loop cable."
        }

        recomputeFrequencyResponse()
        recomputeRoomAcoustics()
    }

    // MARK: IR lifecycle

    /// The single point where the impulse response changes hands. State that
    /// belongs to *an* IR rather than to the app is invalidated here rather
    /// than at each call site, so a new — or dropped — measurement can never
    /// leave a readout behind from the last one.
    private func setImpulseResponse(_ ir: [Float], sampleRate: Double) {
        impulseResponse = ir
        irSampleRate = sampleRate
        updateIRPeak()
        irGeneration &+= 1
        // STI is computed on demand and never recomputed automatically, so
        // without this it simply outlives the measurement it was derived from.
        stiResult = nil
    }

    /// Drop the current measurement and every readout derived from it.
    ///
    /// A failed sweep used to leave the previous IR in place, still feeding the
    /// FR curve, the gate markers, the delay chip, the room-acoustics table and
    /// the Δ readout. The Δ is the dangerous one: freeze a reference, move the
    /// mic, fire again, sweep fails — and Δ keeps reporting the frozen IR's own
    /// 0.00 ms, which reads as "perfectly aligned" when nothing was measured at
    /// all. Same defect the burst path had (fixed 27 Jul); this side needed the
    /// derived state handled too, hence the delay.
    ///
    /// The frozen reference and any overlays are deliberately kept. They're
    /// separate snapshots, they're still valid, and re-freezing after every
    /// failed shot would be its own friction in the room.
    func clearMeasurement() {
        setImpulseResponse([], sampleRate: irSampleRate)
        systemDelaySamples = 0
        lastPeakDBFS = nil
        lastCorrelationDB = nil
        cursorSample = 0
        markerSample = nil
        irFit()
        recomputeFrequencyResponse()  // clears currentFR / currentPhase
        recomputeRoomAcoustics()      // clears roomParams / bandParams
    }

    func recomputeFrequencyResponse() {
        guard !impulseResponse.isEmpty else {
            // Returning early here would leave the previous measurement's trace
            // drawn as though it were live — the whole bug this guards against.
            currentFR = nil
            currentPhase = []
            return
        }
        let gateStart = min(cursorSample, impulseResponse.count - 1)
        let gateLen: Int
        if let marker = markerSample, marker > gateStart {
            gateLen = marker - gateStart
        } else {
            gateLen = min(Int(gateMs / 1000.0 * irSampleRate), impulseResponse.count - gateStart)
        }
        let fft = max(fftSize, FFT.nextPowerOfTwo(gateLen))
        effectiveFFTSize = fft

        guard let fr = TransferFunctionEstimator.gatedResponse(
            ir: impulseResponse, gateStart: gateStart, gateLength: gateLen,
            fftSize: fft, sampleRate: irSampleRate, gateTailFraction: gateTailFraction)
        else {
            // An IR the estimator can't gate has no current curve either.
            currentFR = nil
            currentPhase = []
            return
        }

        let freqs = fr.frequencies()
        var mags: [Float]
        if smoothing > 0 {
            let power = zip(fr.hRe, fr.hIm).map { $0 * $0 + $1 * $1 }
            let smoothed = Smoothing.fractionalOctave(
                power: power, sampleRate: irSampleRate, fftSize: fft, n: smoothing)
            mags = Smoothing.powerToDB(smoothed)
        } else {
            mags = fr.magnitudeDB()
        }
        // The gated FFT's t=0 is the gate start, so only the gate-start → direct
        // sound pre-delay remains as excess linear phase. Removing it leaves the
        // response's own phase — the number that matters for alignment.
        let peakIdx = peakIndex(of: impulseResponse)
        let preDelay = peakIdx > gateStart ? Double(peakIdx - gateStart) / irSampleRate : 0
        currentPhase = fr.phaseDegrees(removingDelay: preDelay)

        // Re-reference the complex spectrum from the gate start to IR sample 0, so
        // it can be summed against another measurement without the gate position
        // silently becoming the time origin. Removing `arrivalSeconds` from this
        // reproduces `currentPhase` exactly — the two representations agree.
        let absolute = Summation.delayed(
            hRe: fr.hRe, hIm: fr.hIm, frequencies: freqs,
            seconds: Double(gateStart) / irSampleRate)

        currentFR = FRCurve(name: "Current", frequencies: freqs, magnitudesDB: mags,
                            color: PlotStyle.trace, phaseDegrees: currentPhase,
                            hRe: absolute.re, hIm: absolute.im,
                            arrivalSeconds: Double(peakIdx) / irSampleRate,
                            sampleRate: irSampleRate, fftSize: fft)
    }

    func recomputeRoomAcoustics() {
        guard !impulseResponse.isEmpty else {
            roomParams = nil
            bandParams = []
            return
        }
        let ir = impulseResponse
        let fs = irSampleRate
        let generation = irGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let wide = RoomAcoustics.analyze(ir: ir, sampleRate: fs)
            let bands = RoomAcoustics.analyzeOctaveBands(ir: ir, sampleRate: fs)
            DispatchQueue.main.async {
                // The IR these came from may have been replaced or dropped while
                // the analysis ran; publishing now would file the old
                // measurement's numbers under the new one.
                guard let self, self.irGeneration == generation else { return }
                self.roomParams = wide
                self.bandParams = bands
            }
        }
    }

    func computeSTI() {
        guard !impulseResponse.isEmpty else { return }
        statusMessage = "Computing STI..."
        let ir = impulseResponse
        let fs = irSampleRate
        let generation = irGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = STI.compute(ir: ir, sampleRate: fs)
            DispatchQueue.main.async {
                guard let self, self.irGeneration == generation else { return }
                self.stiResult = result
                self.statusMessage = String(
                    format: "STI = %.2f (%@), %%ALcons = %.1f%%",
                    result.sti, result.rating, result.alcons)
            }
        }
    }

    // MARK: IR zoom / pan

    /// The clamped, resolved visible sample window for the IR plot.
    var irVisibleRange: Range<Int> {
        guard !impulseResponse.isEmpty else { return 0..<0 }
        let n = impulseResponse.count
        let len = irViewLength <= 0 ? n : min(max(irViewLength, irMinVisibleSamples), n)
        let start = min(max(irViewStart, 0), n - len)
        return start..<(start + len)
    }

    /// Zoom by a factor (<1 zooms in, >1 zooms out), keeping `center` (a sample
    /// index) pinned at the same relative screen position. Defaults to the
    /// current cursor so zoom homes in on the gate you're placing.
    func irZoom(factor: Double, center: Int? = nil) {
        guard !impulseResponse.isEmpty else { return }
        let n = impulseResponse.count
        let range = irVisibleRange
        let current = range.count
        var newLen = Int((Double(current) * factor).rounded())
        newLen = min(max(newLen, irMinVisibleSamples), n)
        let pivot = min(max(center ?? cursorSample, 0), n - 1)
        let rel = Double(pivot - range.lowerBound) / Double(max(current, 1))
        var newStart = pivot - Int(rel * Double(newLen))
        newStart = min(max(newStart, 0), n - newLen)
        irViewStart = newStart
        irViewLength = newLen >= n ? 0 : newLen
    }

    /// Frame the current gate (cursor→marker) with a little padding.
    func irZoomToGate() {
        guard !impulseResponse.isEmpty, let marker = markerSample else { return }
        let n = impulseResponse.count
        let lo = min(cursorSample, marker)
        let hi = max(cursorSample, marker)
        let pad = max(irMinVisibleSamples, (hi - lo) / 4)
        let start = max(0, lo - pad)
        let end = min(n, hi + pad)
        let len = max(end - start, irMinVisibleSamples)
        irViewStart = start
        irViewLength = len >= n ? 0 : len
    }

    /// Pan the visible window by a sample delta (horizontal scroll).
    func irPanBy(_ delta: Int) {
        guard !impulseResponse.isEmpty, irViewLength > 0 else { return }
        let n = impulseResponse.count
        let len = irVisibleRange.count
        irViewStart = min(max(irViewStart + delta, 0), n - len)
    }

    /// Magnify the amplitude axis (shift-scroll), to see the decay tail.
    func irAmpZoomBy(_ factor: Double) {
        irAmpZoom = min(max(irAmpZoom * factor, 1), 500)
    }

    func irFit() {
        irViewStart = 0
        irViewLength = 0
        irAmpZoom = 1
    }

    // MARK: Overlays & targets

    func setCurrentAsOverlay() {
        guard let fr = currentFR else { return }
        // Carry the phase across too — an overlay with no phase can't be compared
        // against the next measurement, which is the whole point of snapshotting it.
        // The complex spectrum travels with it as well, so this overlay can still be
        // one side of a trial-delay summation after the live curve has moved on.
        overlays.append(FRCurve(
            name: "Overlay \(overlays.count + 1)",
            frequencies: fr.frequencies, magnitudesDB: fr.magnitudesDB,
            color: overlayPalette[overlays.count % overlayPalette.count],
            phaseDegrees: fr.phaseDegrees,
            hRe: fr.hRe, hIm: fr.hIm, arrivalSeconds: fr.arrivalSeconds,
            sampleRate: fr.sampleRate, fftSize: fr.fftSize))
    }

    func clearOverlays() {
        overlays.removeAll()
    }

    // MARK: FR zoom

    /// Zoom the frequency axis to a band (either order — the drag can go
    /// right-to-left). Refuses a degenerate span: the axis maps position through
    /// `log10(fHigh) - log10(fLow)`, so a zero-width band would divide by zero
    /// and take every trace on the plot with it.
    func frZoom(to a: Double, _ b: Double) {
        let low = max(min(a, b), FRPlotView.fullLow)
        let high = min(max(a, b), FRPlotView.fullHigh)
        guard low > 0, high / low >= 1.05 else { return }
        frLow = low
        frHigh = high
    }

    /// Back to the full 20 Hz–20 kHz axis. Returns false when there was nothing
    /// to undo, so Esc stays available to the rest of the app.
    @discardableResult
    func frResetZoom() -> Bool {
        guard frIsZoomed else { return false }
        frLow = FRPlotView.fullLow
        frHigh = FRPlotView.fullHigh
        return true
    }

    func loadTargetCurve() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "frd") ?? .plainText, .plainText]
        panel.message = "Load target curve (.frd: freq dB [phase])"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed = FRDFile.parse(text)
        guard !parsed.frequencies.isEmpty else {
            statusMessage = "No parseable data in \(url.lastPathComponent)."
            return
        }
        // The parser pads a missing third column with zeros, so an all-zero phase
        // array means "this .frd had no phase" — attaching it would draw a flat,
        // fictitious 0° line. Only carry phase that's actually in the file.
        let phase = parsed.phasesDegrees.contains { $0 != 0 } ? parsed.phasesDegrees : []
        overlays.append(FRCurve(
            name: url.deletingPathExtension().lastPathComponent,
            frequencies: parsed.frequencies, magnitudesDB: parsed.magnitudesDB,
            color: PlotStyle.target, isTarget: true, phaseDegrees: phase))
    }

    // MARK: File I/O

    func savePIR() {
        guard !impulseResponse.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "measurement.pir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var pir = PIRFile(sampleRate: Int32(irSampleRate), samples: impulseResponse)
        pir.peakLeft = impulseResponse.map(abs).max() ?? 0
        pir.cursorPosition = Int32(cursorSample)
        pir.markerPosition = Int32(markerSample ?? -1)
        pir.infoText = "Measured with arta-mac"
        do {
            try pir.write(to: url)
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func loadPIR() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pir") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pir = try PIRFile.read(from: url)
            setImpulseResponse(pir.samples, sampleRate: Double(pir.sampleRate))
            cursorSample = Int(pir.cursorPosition)
            markerSample = pir.markerPosition >= 0 ? Int(pir.markerPosition) : nil
            irFit()
            statusMessage = "Loaded \(url.lastPathComponent): \(pir.samples.count) samples @ \(pir.sampleRate) Hz."
            recomputeFrequencyResponse()
            recomputeRoomAcoustics()
        } catch {
            statusMessage = "Load failed: \(error)"
        }
    }

    /// Burst results are arta-mac's own measurement type (no ARTA-interop format
    /// to match, unlike .pir/.frd), so a plain JSON encode of `BurstResult` is the
    /// whole format — no need to hand-roll a binary layout for it.
    func saveBurst() {
        guard let result = burstResult else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "burst.tbr"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: url)
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func loadBurst() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tbr") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            burstResult = try JSONDecoder().decode(BurstResult.self, from: data)
            statusMessage = "Loaded \(url.lastPathComponent)."
        } catch {
            statusMessage = "Load failed: \(error.localizedDescription)"
        }
    }

    func exportFRD() {
        guard let fr = currentFR else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "response.frd"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = FRDFile.export(
            frequencies: fr.frequencies, magnitudesDB: fr.magnitudesDB,
            phasesDegrees: currentPhase.isEmpty ? nil : currentPhase)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    /// Cache the full-signal peak magnitude + its index (call whenever the IR
    /// changes) so per-frame draw and the delta readout stay O(1).
    private func updateIRPeak() {
        var p: Float = 1e-9
        var idx = 0
        for (i, v) in impulseResponse.enumerated() {
            let a = abs(v)
            if a > p { p = a; idx = i }
        }
        irPeak = p
        irPeakIndex = idx
    }

    // MARK: IR delay comparison (freeze reference → measure again → read Δ)

    func freezeIR() {
        guard !impulseResponse.isEmpty else { return }
        frozenIR = impulseResponse
        frozenIRPeak = irPeak
        frozenIRPeakIndex = irPeakIndex
    }

    func clearFrozenIR() {
        frozenIR = []
    }

    /// Direct-sound arrival difference between the current IR and the frozen
    /// reference. Fixed converter/buffer latency is identical in both, so it
    /// cancels — this is pure acoustic travel-time difference.
    var irDeltaMs: Double? {
        guard !frozenIR.isEmpty, !impulseResponse.isEmpty else { return nil }
        return Double(irPeakIndex - frozenIRPeakIndex) / irSampleRate * 1000
    }

    // MARK: Burst delay comparison (freeze reference → fire through sub → read Δ)

    func freezeBurst() {
        // Refuse a result with no arrival data (e.g. a .tbr loaded from before
        // arrivalOffsetSamples existed) — freezing it would silently produce no
        // Δ later with no explanation of why.
        guard let result = burstResult, result.arrivalOffsetSamples != nil else { return }
        frozenBurst = result
    }

    func clearFrozenBurst() {
        frozenBurst = nil
    }

    /// Mirrors irDeltaMs: fixed converter/buffer latency is identical on both
    /// captures (same device/routing), so it cancels — this is pure acoustic
    /// travel-time difference. Each side is converted samples→seconds using its
    /// OWN sampleRate before subtracting, so this stays correct even if the
    /// device sample rate changed between the two bursts.
    var burstDeltaMs: Double? {
        guard let ref = frozenBurst, let cur = burstResult,
              let refOffset = ref.arrivalOffsetSamples,
              let curOffset = cur.arrivalOffsetSamples,
              !burstTimingReferenceMismatch
        else { return nil }
        return Analysis.burstArrivalDeltaSeconds(
            referenceOffsetSamples: refOffset, referenceSampleRate: ref.sampleRate,
            currentOffsetSamples: curOffset, currentSampleRate: cur.sampleRate
        ) * 1000
    }

    /// The two captures measured their arrivals from different zeros — one against
    /// the loop reference, one against the playback schedule. Those differ by the
    /// interface's electrical round trip, so a Δ across them is wrong by that
    /// amount (typically several ms — a large error at crossover frequencies).
    /// Unlike a frequency mismatch, which still yields a physically real number
    /// measured the wrong way, this one is arithmetically invalid, so `burstDeltaMs`
    /// withholds it rather than flagging it. Usually means the loop-reference cable
    /// came out, or was switched on or off between the two shots.
    var burstTimingReferenceMismatch: Bool {
        guard let ref = frozenBurst, let cur = burstResult,
              let refKind = ref.timingReference, let curKind = cur.timingReference
        else { return false }
        return refKind != curKind
    }

    /// Pat Brown's method only gives a meaningful Δ when both bursts are fired at
    /// the same (crossover) frequency. Flags a cross-frequency comparison rather
    /// than hiding the number — the app's own P1 principle is to not produce a
    /// confident-looking number from invalid input without saying so.
    var burstFrequencyMismatch: Bool {
        guard let ref = frozenBurst, let cur = burstResult else { return false }
        return abs(ref.frequency - cur.frequency) > 0.5
    }

    func peakIndex(of signal: [Float]) -> Int {
        var idx = 0
        var peak: Float = 0
        for (i, v) in signal.enumerated() where abs(v) > peak {
            peak = abs(v)
            idx = i
        }
        return idx
    }
}
