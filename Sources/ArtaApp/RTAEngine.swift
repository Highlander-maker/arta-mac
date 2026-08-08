import AVFoundation
import Foundation
import ArtaDSP

/// Observable live-spectrum state. Its own ObservableObject for the same reason as
/// InputMeter: a ~20 Hz spectrum stream must not invalidate the settings sidebar on
/// every frame.
final class RTA: ObservableObject {
    @Published private(set) var magnitudesDB: [Float] = []
    @Published private(set) var peakHoldDB: [Float] = []
    @Published private(set) var frequencies: [Double] = []
    @Published private(set) var running = false
    @Published private(set) var error: String?
    @Published var peakHoldEnabled = false

    private let engine = RTAEngine()
    /// dB the peak-hold line falls per published frame once the signal drops.
    private let peakDecayPerFrame: Float = 0.4

    func start(inputDeviceID: AudioDeviceID?, channel: Int, fftSize: Int,
               smoothing: Int, averaging: RTASpectrum.Averaging) {
        engine.stop()
        do {
            try engine.start(inputDeviceID: inputDeviceID, channel: channel, fftSize: fftSize,
                             smoothing: smoothing, averaging: averaging) { [weak self] db, freqs in
                self?.apply(db: db, freqs: freqs)
            }
            running = true
            error = nil
        } catch {
            running = false
            self.error = "\(error)"
        }
    }

    func stop() {
        engine.stop()
        running = false
    }

    func resetPeakHold() { peakHoldDB = [] }

    /// Runs on the main queue (the engine dispatches there).
    private func apply(db: [Float], freqs: [Double]) {
        magnitudesDB = db
        if frequencies.count != freqs.count { frequencies = freqs }

        guard peakHoldEnabled else {
            if !peakHoldDB.isEmpty { peakHoldDB = [] }
            return
        }
        if peakHoldDB.count != db.count {
            peakHoldDB = db
            return
        }
        for i in db.indices {
            peakHoldDB[i] = db[i] >= peakHoldDB[i]
                ? db[i]
                : max(db[i], peakHoldDB[i] - peakDecayPerFrame)
        }
    }
}

/// Capture side of the live RTA — sibling to `InputMeterEngine`. Owns the tap and
/// the overlapped framing; all spectrum maths lives in `ArtaDSP.RTASpectrum`.
///
/// It complements the swept measurement rather than replacing it: a sweep yields a
/// precise, gated transfer function of one source, while the RTA shows whatever is
/// in the room live and updates as you move or make changes. No reference channel
/// is involved, so this is a plain spectrum, not a transfer function.
final class RTAEngine {

    private var engine: AVAudioEngine?
    /// All analysis state below is touched only on this queue.
    private let analysisQueue = DispatchQueue(label: "com.highlander.arta.rta", qos: .userInitiated)

    private var spectrum: RTASpectrum?
    private var fftSize = 8192
    private var hop = 2048
    private var pending: [Float] = []
    private var lastPublish: CFAbsoluteTime = 0

    private(set) var isRunning = false

    func start(inputDeviceID: AudioDeviceID?, channel: Int, fftSize: Int, smoothing: Int,
               averaging: RTASpectrum.Averaging,
               onSpectrum: @escaping ([Float], [Double]) -> Void) throws {
        stop()
        try ensureMicrophonePermission()

        let engine = AVAudioEngine()
        let format: AVAudioFormat
        if let id = inputDeviceID {
            // Same async device-switch caveat as the meter — wait for the real
            // channel count before installing the tap.
            format = try AudioDevices.ensureInputDeviceSettled(id, on: engine.inputNode, what: "RTA input")
        } else {
            format = engine.inputNode.inputFormat(forBus: 0)
        }
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0 else {
            throw AudioError.message("Selected input device has no input channels.")
        }

        // Cap the hop so the refresh rate stays responsive (~23 Hz at 48 kHz) even
        // at large FFT sizes, where a 50% hop would mean a new frame only every few
        // hundred ms and the display would feel dead.
        let hop = max(min(fftSize / 2, 2048), 1)
        guard let spectrum = RTASpectrum(
            fftSize: fftSize, sampleRate: format.sampleRate,
            hopSeconds: Double(hop) / format.sampleRate,
            smoothing: smoothing, averaging: averaging)
        else {
            throw AudioError.message("RTA FFT size must be a power of two (got \(fftSize)).")
        }
        let tapChannel = min(max(channel, 0), channels - 1)

        // Prime analysis state before any audio can arrive.
        analysisQueue.sync {
            self.spectrum = spectrum
            self.fftSize = fftSize
            self.hop = hop
            self.pending = []
            self.lastPublish = 0
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let ch = min(tapChannel, Int(buffer.format.channelCount) - 1)
            guard ch >= 0 else { return }
            // Copy off the audio thread's buffer, then do all real work on the
            // analysis queue — never run an FFT in the render callback.
            let chunk = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            self.analysisQueue.async { self.ingest(chunk, onSpectrum: onSpectrum) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioError.message("Failed to start RTA engine: \(error.localizedDescription)")
        }

        self.engine = engine
        isRunning = true
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        analysisQueue.async {
            self.pending = []
            self.spectrum?.reset()
        }
    }

    private func ingest(_ chunk: [Float], onSpectrum: @escaping ([Float], [Double]) -> Void) {
        guard let spectrum else { return }
        pending.append(contentsOf: chunk)
        // If analysis fell behind, throw the backlog away rather than grinding
        // through stale audio — an RTA that lags the room is worse than useless.
        let maxBacklog = fftSize + hop * 4
        if pending.count > maxBacklog { pending.removeFirst(pending.count - maxBacklog) }

        while pending.count >= fftSize {
            let db = spectrum.process(frame: Array(pending.prefix(fftSize)))
            pending.removeFirst(hop)
            guard !db.isEmpty else { continue }

            // The hop rate can outrun what's worth drawing; cap UI updates at 20 Hz.
            // The average still integrates every frame — only the display is dropped.
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastPublish >= 1.0 / 20.0 else { continue }
            lastPublish = now
            let freqs = spectrum.frequencies
            DispatchQueue.main.async { onSpectrum(db, freqs) }
        }
    }
}
