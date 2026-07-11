import AVFoundation
import CoreAudio
import Foundation
import ArtaDSP

/// One sweep measurement: plays a Farina log sweep on the selected output while
/// capturing the selected input on the same AVAudioEngine (same clock for a
/// single device), then deconvolves the impulse response. This is the proven
/// full-duplex path from the Phase 0 spike, feeding ArtaDSP.
struct MeasurementSettings {
    var inputDeviceID: AudioDeviceID?
    var outputDeviceID: AudioDeviceID?
    var inputChannel: Int = 0
    var outputChannel: Int = 0
    var f1: Double = 20
    var f2: Double = 20_000
    var sweepDuration: Double = 1.0
    var amplitudeDB: Double = -12       // output level dBFS
    var preSilence: Double = 0.3
    var postSilence: Double = 1.0       // must exceed room decay + system latency
}

struct MeasurementResult {
    var impulseResponse: [Float]
    var sampleRate: Double
    var systemDelaySamples: Double      // correlation-estimated round trip
    var capturedPeakDBFS: Float
    var correlationQualityDB: Float
}

final class MeasurementEngine {

    enum State { case idle, running }
    private(set) var state: State = .idle

    private final class Capture {
        let lock = NSLock()
        var samples: [Float] = []
        var firstBufferTime: AVAudioTime?

        func append(_ buffer: AVAudioPCMBuffer, channel: Int, when: AVAudioTime) {
            lock.lock()
            defer { lock.unlock() }
            if firstBufferTime == nil { firstBufferTime = when }
            guard let data = buffer.floatChannelData else { return }
            let ch = min(channel, Int(buffer.format.channelCount) - 1)
            samples.append(contentsOf: UnsafeBufferPointer(start: data[ch], count: Int(buffer.frameLength)))
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return samples.count
        }

        func snapshot() -> ([Float], AVAudioTime?) {
            lock.lock(); defer { lock.unlock() }
            return (samples, firstBufferTime)
        }
    }

    /// Runs the measurement synchronously (call from a background queue).
    func measure(settings: MeasurementSettings) throws -> MeasurementResult {
        guard state == .idle else { throw AudioError.message("A measurement is already running.") }
        state = .running
        defer { state = .idle }

        try ensureMicrophonePermission()

        let engine = AVAudioEngine()

        // macOS quirk: inputNode and outputNode share ONE AUHAL, which the
        // engine binds to a private aggregate of the system default devices.
        // Setting a device on it is only valid once, so the supported configs
        // are: (a) system defaults — touch nothing, the aggregate handles
        // full duplex; (b) one full-duplex interface for both directions —
        // a single set (the reference configuration: one clock).
        let defIn = AudioDevices.defaultDeviceID(input: true)
        let defOut = AudioDevices.defaultDeviceID(input: false)
        let wantIn = settings.inputDeviceID ?? defIn
        let wantOut = settings.outputDeviceID ?? defOut
        if let dev = wantIn, wantIn == wantOut {
            try AudioDevices.ensureDevice(dev, on: engine.inputNode, what: "measurement I/O")
        } else if wantIn != defIn || wantOut != defOut {
            throw AudioError.message(
                "Split input/output devices aren't supported by the macOS audio engine. "
                + "Pick the same interface for input and output (best: one clock), "
                + "or set both to the system default devices.")
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioError.message("Selected input device has no input channels.")
        }
        guard outputFormat.channelCount > 0, outputFormat.sampleRate > 0 else {
            throw AudioError.message("Selected output device has no output channels.")
        }
        let inRate = inputFormat.sampleRate
        let outRate = outputFormat.sampleRate
        let amplitude = pow(10.0, settings.amplitudeDB / 20.0)

        // Keep the sweep inside both converters' Nyquist with margin.
        let fMax = min(inRate, outRate) * 0.475
        let f1 = min(max(settings.f1, 1.0), fMax - 1.0)
        let f2 = min(max(settings.f2, f1 + 1.0), fMax)

        // Sweep at the output rate for playback.
        let playSweep = SignalGenerator.logSweep(
            f1: f1, f2: f2,
            duration: settings.sweepDuration, sampleRate: outRate, amplitude: amplitude)
        let preFrames = Int(settings.preSilence * outRate)
        let postFrames = Int(settings.postSilence * outRate)
        let playSignal = [Float](repeating: 0, count: preFrames) + playSweep
            + [Float](repeating: 0, count: postFrames)

        guard let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: outRate,
            channels: outputFormat.channelCount, interleaved: false),
            let playBuffer = AVAudioPCMBuffer(
                pcmFormat: playerFormat, frameCapacity: AVAudioFrameCount(playSignal.count))
        else { throw AudioError.message("Could not create playback buffer.") }

        playBuffer.frameLength = AVAudioFrameCount(playSignal.count)
        if let data = playBuffer.floatChannelData {
            let outCh = min(settings.outputChannel, Int(playerFormat.channelCount) - 1)
            for ch in 0..<Int(playerFormat.channelCount) {
                if ch == outCh {
                    playSignal.withUnsafeBufferPointer { src in
                        data[ch].update(from: src.baseAddress!, count: src.count)
                    }
                } else {
                    data[ch].update(repeating: 0, count: playSignal.count)
                }
            }
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let capture = Capture()
        let tapFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, when in
            capture.append(buffer, channel: settings.inputChannel, when: when)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioError.message("Failed to start audio engine: \(error.localizedDescription)")
        }

        let leadSeconds = 0.5
        let totalDuration = settings.preSilence + settings.sweepDuration + settings.postSilence
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadSeconds)
        player.scheduleBuffer(playBuffer, at: nil, options: [], completionHandler: nil)
        player.play(at: AVAudioTime(hostTime: startHostTime))

        let neededFrames = Int((leadSeconds + totalDuration + 0.3) * inRate)
        let deadline = Date().addingTimeInterval(leadSeconds + totalDuration + 6.0)
        while capture.count < neededFrames && Date() < deadline {
            usleep(50_000)
        }

        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let (captured, firstTime) = capture.snapshot()
        guard captured.count >= Int(inRate * 0.5), let first = firstTime, first.isHostTimeValid else {
            throw AudioError.message(
                "Capture failed (\(captured.count) frames). Check microphone permission and input device.")
        }

        let peak = captured.reduce(Float(0)) { max($0, abs($1)) }
        let peakDBFS = 20 * log10(max(peak, 1e-10))

        // Where in the capture timeline did the sweep itself start?
        let schedulingOffset = hostTimeDeltaSeconds(from: first.hostTime, to: startHostTime)
        let sweepStartSample = (schedulingOffset + settings.preSilence) * inRate

        // Reference sweep at the input rate for analysis.
        let reference = outRate == inRate ? playSweep : SignalGenerator.logSweep(
            f1: f1, f2: f2,
            duration: settings.sweepDuration, sampleRate: inRate, amplitude: amplitude)

        let responseStart = max(0, Int(sweepStartSample))
        let response = Array(captured[responseStart...])

        let (lag, corr) = Deconvolution.estimateDelay(reference: reference, measured: response)
        var ir = Deconvolution.impulseResponse(excitation: reference, response: response)

        // Keep a workable window: everything up to 4 s after the direct sound.
        let keep = min(ir.count, max(0, lag) + Int(inRate * 4.0))
        if keep > 0 && keep < ir.count { ir = Array(ir[0..<keep]) }

        return MeasurementResult(
            impulseResponse: ir,
            sampleRate: inRate,
            systemDelaySamples: Double(lag),
            capturedPeakDBFS: peakDBFS,
            correlationQualityDB: 20 * log10(max(corr, 1e-5))
        )
    }

    private func ensureMicrophonePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let sema = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                sema.signal()
            }
            sema.wait()
            guard granted else { throw AudioError.message("Microphone permission was denied.") }
        default:
            throw AudioError.message(
                "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone.")
        }
    }

    private func hostTimeDeltaSeconds(from: UInt64, to: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let scale = Double(info.numer) / Double(info.denom) / 1e9
        return to >= from ? Double(to - from) * scale : -Double(from - to) * scale
    }
}
