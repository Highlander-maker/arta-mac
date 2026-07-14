import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ArtaDSP

/// A named magnitude curve for plotting (current measurement, overlays, targets).
struct FRCurve: Identifiable {
    let id = UUID()
    var name: String
    var frequencies: [Double]
    var magnitudesDB: [Float]
    var color: Color
    var isTarget: Bool = false
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
    @Published var currentPhase: [Float] = []

    // MARK: Room acoustics

    @Published var roomParams: RoomAcousticParams?
    @Published var bandParams: [(center: Double, params: RoomAcousticParams)] = []
    @Published var stiResult: STIResult?

    // MARK: Input meter (live gain-staging, independent of Measure)
    //
    // Its own ObservableObject so the ~23 Hz level updates only re-render the
    // small meter view, not the whole sidebar Form (that was the drag lag).
    let meter = InputMeter()

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

    /// Device pickers call this so the meter follows whichever interface is selected.
    func restartMeterForDeviceChange() {
        guard !isMeasuring else { return }
        startMeter()
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

    func runMeasurement() {
        guard !isMeasuring else { return }
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
                    self.startMeter()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isMeasuring = false
                    self.statusMessage = "Measurement failed: \(error)"
                    self.startMeter()
                }
            }
        }
    }

    private func apply(result: MeasurementResult) {
        impulseResponse = result.impulseResponse
        updateIRPeak()
        irSampleRate = result.sampleRate
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

    func recomputeFrequencyResponse() {
        guard !impulseResponse.isEmpty else { return }
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
        else { return }

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
        currentFR = FRCurve(name: "Current", frequencies: freqs, magnitudesDB: mags, color: PlotStyle.trace)
    }

    func recomputeRoomAcoustics() {
        guard !impulseResponse.isEmpty else { return }
        let ir = impulseResponse
        let fs = irSampleRate
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let wide = RoomAcoustics.analyze(ir: ir, sampleRate: fs)
            let bands = RoomAcoustics.analyzeOctaveBands(ir: ir, sampleRate: fs)
            DispatchQueue.main.async {
                self?.roomParams = wide
                self?.bandParams = bands
            }
        }
    }

    func computeSTI() {
        guard !impulseResponse.isEmpty else { return }
        statusMessage = "Computing STI..."
        let ir = impulseResponse
        let fs = irSampleRate
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = STI.compute(ir: ir, sampleRate: fs)
            DispatchQueue.main.async {
                self?.stiResult = result
                self?.statusMessage = String(
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
        guard var fr = currentFR else { return }
        fr = FRCurve(
            name: "Overlay \(overlays.count + 1)",
            frequencies: fr.frequencies, magnitudesDB: fr.magnitudesDB,
            color: overlayPalette[overlays.count % overlayPalette.count])
        overlays.append(fr)
    }

    func clearOverlays() {
        overlays.removeAll()
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
        overlays.append(FRCurve(
            name: url.deletingPathExtension().lastPathComponent,
            frequencies: parsed.frequencies, magnitudesDB: parsed.magnitudesDB,
            color: PlotStyle.target, isTarget: true))
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
            impulseResponse = pir.samples
            updateIRPeak()
            irSampleRate = Double(pir.sampleRate)
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
