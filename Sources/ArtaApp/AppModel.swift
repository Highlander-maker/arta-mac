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

    // MARK: Frequency response state

    @Published var currentFR: FRCurve?
    @Published var overlays: [FRCurve] = []
    @Published var smoothing = 6          // 1/n octave; 0 = unsmoothed
    @Published var gateMs = 200.0
    @Published var fftSize = 65536
    @Published var showPhase = false
    @Published var currentPhase: [Float] = []

    // MARK: Room acoustics

    @Published var roomParams: RoomAcousticParams?
    @Published var bandParams: [(center: Double, params: RoomAcousticParams)] = []
    @Published var stiResult: STIResult?

    private let engine = MeasurementEngine()
    private let overlayPalette = PlotStyle.overlayPalette

    init() {
        refreshDevices()
    }

    // MARK: Actions

    func refreshDevices() {
        devices = AudioDevices.all().filter { $0.inputChannels > 0 || $0.outputChannels > 0 }
        if inputDeviceID == nil { inputDeviceID = AudioDevices.defaultDeviceID(input: true) }
        if outputDeviceID == nil { outputDeviceID = AudioDevices.defaultDeviceID(input: false) }
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
        let kind: GeneratorEngine.Kind
        switch generatorMode {
        case .sine: kind = .sine(frequency: generatorFrequency)
        case .pink: kind = .pink
        case .pinkBand: kind = .pinkBand(center: generatorFrequency, fraction: generatorFraction)
        }
        do {
            try generator.start(
                kind: kind, levelDB: generatorLevelDB,
                outputDeviceID: outputDeviceID, outputChannel: outputChannel)
            generatorRunning = true
            switch generatorMode {
            case .sine:
                statusMessage = String(format: "Generator: %.0f Hz sine @ %.0f dBFS on out %d.",
                                       generatorFrequency, generatorLevelDB, outputChannel + 1)
            case .pink:
                statusMessage = String(format: "Generator: pink noise @ %.0f dBFS on out %d.",
                                       generatorLevelDB, outputChannel + 1)
            case .pinkBand:
                statusMessage = String(format: "Generator: 1/%d-oct pink @ %.0f Hz, %.0f dBFS on out %d.",
                                       generatorFraction, generatorFrequency, generatorLevelDB, outputChannel + 1)
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

    func runMeasurement() {
        guard !isMeasuring else { return }
        if generatorRunning {
            generator.stop()
            generatorRunning = false
        }
        isMeasuring = true
        statusMessage = "Measuring — playing sweep..."

        let settings = MeasurementSettings(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            inputChannel: inputChannel,
            outputChannel: outputChannel,
            f1: f1, f2: f2,
            sweepDuration: sweepDuration,
            amplitudeDB: outputLevelDB,
            postSilence: postSilence
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.engine.measure(settings: settings)
                DispatchQueue.main.async {
                    self.apply(result: result)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isMeasuring = false
                    self.statusMessage = "Measurement failed: \(error)"
                }
            }
        }
    }

    private func apply(result: MeasurementResult) {
        impulseResponse = result.impulseResponse
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

        statusMessage = String(
            format: "Done. Delay %.1f ms, input peak %.1f dBFS, correlation %.0f dB. IR: %d samples @ %.0f Hz.",
            result.systemDelaySamples / result.sampleRate * 1000,
            result.capturedPeakDBFS,
            result.correlationQualityDB,
            result.impulseResponse.count, result.sampleRate)

        if result.capturedPeakDBFS < -60 {
            statusMessage += " WARNING: input nearly silent — check mic/loopback path."
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

        guard let fr = TransferFunctionEstimator.gatedResponse(
            ir: impulseResponse, gateStart: gateStart, gateLength: gateLen,
            fftSize: fft, sampleRate: irSampleRate)
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
            irSampleRate = Double(pir.sampleRate)
            cursorSample = Int(pir.cursorPosition)
            markerSample = pir.markerPosition >= 0 ? Int(pir.markerPosition) : nil
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
