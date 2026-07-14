import AVFoundation
import Foundation

/// Observable meter state. Kept as its OWN ObservableObject (not fields on
/// AppModel) so the ~23 Hz level stream only invalidates the little meter view —
/// not the whole settings sidebar. Publishing these on AppModel was what made
/// the volume sliders feel laggy: every tick redrew the entire Form.
final class InputMeter: ObservableObject {
    @Published private(set) var rmsDB: [Float] = []
    @Published private(set) var holdDB: [Float] = []
    @Published private(set) var running = false
    @Published private(set) var error: String?

    private let engine = InputMeterEngine()
    /// dB the peak-hold line falls per callback (~43 ms) once the signal drops.
    private let holdDecayPerTick: Float = 1.0

    func start(inputDeviceID: AudioDeviceID?) {
        engine.stop()
        do {
            try engine.start(inputDeviceID: inputDeviceID) { [weak self] rms, peak in
                self?.apply(rms: rms, peak: peak)
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

    /// Runs on the main queue (the engine dispatches there).
    private func apply(rms: [Float], peak: [Float]) {
        if rmsDB.count != rms.count {
            rmsDB = rms
            holdDB = peak
            return
        }
        rmsDB = rms
        for i in peak.indices {
            holdDB[i] = peak[i] >= holdDB[i]
                ? peak[i]
                : max(peak[i], holdDB[i] - holdDecayPerTick)
        }
    }
}

/// Continuous input level metering — the gain-staging check you'd do on a Smaart
/// input meter before trusting a sweep: watch RMS + peak-hold per channel while
/// turning up preamp gain, independent of running an actual measurement.
final class InputMeterEngine {

    private var engine: AVAudioEngine?
    private(set) var isRunning = false

    /// Starts a tap on the given input device (or system default if nil) and
    /// reports dBFS levels back on the main queue as they arrive.
    /// `onLevels` receives (rmsDB, peakDB) arrays, one entry per input channel.
    func start(inputDeviceID: AudioDeviceID?, onLevels: @escaping ([Float], [Float]) -> Void) throws {
        stop()
        try ensureMicrophonePermission()

        let engine = AVAudioEngine()
        let format: AVAudioFormat
        if let id = inputDeviceID {
            // Wait for the async device switch to actually expose the device's
            // real channel count before installing the tap (otherwise the tap
            // runs at the stale default's format and stalls — see helper docs).
            format = try AudioDevices.ensureInputDeviceSettled(id, on: engine.inputNode, what: "meter input")
        } else {
            // Hardware (input) format, not the graph-side output format which can
            // be a mono downmix — see ensureInputDeviceSettled docs.
            format = engine.inputNode.inputFormat(forBus: 0)
        }
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0 else {
            throw AudioError.message("Selected input device has no input channels.")
        }
        NSLog("METER start: device=%@ tapFormat ch=%d sr=%.0f nodeOut ch=%d",
              inputDeviceID.map(String.init(describing:)) ?? "default",
              channels, format.sampleRate,
              Int(engine.inputNode.outputFormat(forBus: 0).channelCount))

        var loggedFirst = false
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            if !loggedFirst {
                loggedFirst = true
                NSLog("METER first buffer: ch=%d frames=%d", Int(buffer.format.channelCount), Int(buffer.frameLength))
            }
            guard let data = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var rms = [Float](repeating: 0, count: channels)
            var peak = [Float](repeating: 0, count: channels)
            for ch in 0..<channels {
                let ptr = data[ch]
                var sum: Float = 0
                var chPeak: Float = 0
                for i in 0..<frameLength {
                    let v = ptr[i]
                    sum += v * v
                    chPeak = max(chPeak, abs(v))
                }
                rms[ch] = sqrt(sum / Float(frameLength))
                peak[ch] = chPeak
            }
            let rmsDB = rms.map { 20 * log10(max($0, 1e-7)) }
            let peakDB = peak.map { 20 * log10(max($0, 1e-7)) }
            DispatchQueue.main.async {
                onLevels(rmsDB, peakDB)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioError.message("Failed to start meter engine: \(error.localizedDescription)")
        }

        self.engine = engine
        isRunning = true
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
    }
}
