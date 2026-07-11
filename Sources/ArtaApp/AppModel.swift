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

    // MARK: Measurement state

    @Published var isMeasuring = false
    @Published var statusMessage = "Ready. Select devices and press Measure."
    @Published var impulseResponse: [Float] = []
    @Published var irSampleRate: Double = 48000
    @Published var systemDelaySamples: Double = 0

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
    private let overlayPalette: [Color] = [.teal, .purple, .brown, .green, .pink, .indigo]

    init() {
        refreshDevices()
    }

    // MARK: Actions

    func refreshDevices() {
        devices = AudioDevices.all().filter { $0.inputChannels > 0 || $0.outputChannels > 0 }
        if inputDeviceID == nil { inputDeviceID = AudioDevices.defaultDeviceID(input: true) }
        if outputDeviceID == nil { outputDeviceID = AudioDevices.defaultDeviceID(input: false) }
    }

    func runMeasurement() {
        guard !isMeasuring else { return }
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
        currentPhase = fr.phaseDegrees(removingDelay: Double(gateStart) / irSampleRate)
        currentFR = FRCurve(name: "Current", frequencies: freqs, magnitudesDB: mags, color: .primary)
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
            color: .red, isTarget: true))
    }

    // MARK: File I/O

    func savePIR() {
        guard !impulseResponse.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "measurement.pir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var pir = PIRFile(sampleRate: Int32(irSampleRate), samples: impulseResponse)
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
