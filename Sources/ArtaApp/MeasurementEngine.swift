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
    /// When set, deconvolve against this *captured* input channel (an electrical
    /// loop from an unused output back into the interface) instead of the
    /// generated sweep. Cancels the interface's own DA→AD path and any driver
    /// jitter, leaving only the true acoustic time-of-flight and transfer
    /// function — the standard dual-channel FFT-analyzer technique. Must be a
    /// different channel than `inputChannel` on the same device.
    var referenceChannel: Int? = nil
}

struct MeasurementResult {
    var impulseResponse: [Float]
    var sampleRate: Double
    var systemDelaySamples: Double      // correlation-estimated round trip
    var capturedPeakDBFS: Float
    var correlationQualityDB: Float
    var usedLoopReference: Bool = false
    /// Peak of the captured loop/reference channel (dBFS), nil when sweep ref.
    /// The live meters are stopped during a measurement, so this is the only
    /// visible proof that the loop channel actually carried signal.
    var referencePeakDBFS: Float? = nil
}

final class MeasurementEngine {

    enum State { case idle, running }
    private(set) var state: State = .idle

    private final class Capture {
        let lock = NSLock()
        var samples: [Float] = []
        var referenceSamples: [Float] = []
        var firstBufferTime: AVAudioTime?

        /// Captures `channel` into the primary buffer, and `referenceChannel`
        /// (if given) into a second buffer from the same tap callback — so the
        /// two stay sample-for-sample aligned on one capture clock.
        func append(_ buffer: AVAudioPCMBuffer, channel: Int, referenceChannel: Int?, when: AVAudioTime) {
            lock.lock()
            defer { lock.unlock() }
            if firstBufferTime == nil { firstBufferTime = when }
            guard let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let ch = min(channel, Int(buffer.format.channelCount) - 1)
            samples.append(contentsOf: UnsafeBufferPointer(start: data[ch], count: count))
            if let refChannel = referenceChannel {
                let refCh = min(refChannel, Int(buffer.format.channelCount) - 1)
                referenceSamples.append(contentsOf: UnsafeBufferPointer(start: data[refCh], count: count))
            }
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return samples.count
        }

        func snapshot() -> ([Float], [Float], AVAudioTime?) {
            lock.lock(); defer { lock.unlock() }
            return (samples, referenceSamples, firstBufferTime)
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
        var settledInputFormat: AVAudioFormat?
        if let dev = wantIn, wantIn == wantOut {
            // Wait for the async device switch to expose the interface's real
            // input channel count — the loop reference lives on input 2, which is
            // invisible until the node adopts the multichannel format.
            settledInputFormat = try AudioDevices.ensureInputDeviceSettled(dev, on: engine.inputNode, what: "measurement I/O")
        } else if wantIn != defIn || wantOut != defOut {
            throw AudioError.message(
                "Split input/output devices aren't supported by the macOS audio engine. "
                + "Pick the same interface for input and output (best: one clock), "
                + "or set both to the system default devices.")
        }

        let inputFormat = settledInputFormat ?? engine.inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioError.message("Selected input device has no input channels.")
        }
        guard outputFormat.channelCount > 0, outputFormat.sampleRate > 0 else {
            throw AudioError.message("Selected output device has no output channels.")
        }
        if let refCh = settings.referenceChannel {
            // The loop uses one channel number for both the output that drives it
            // and the input that captures it (out N → in N), matching how the
            // dual-channel loop is physically patched.
            guard refCh != settings.inputChannel else {
                throw AudioError.message("Loop channel must differ from the mic (measurement) channel.")
            }
            guard refCh != settings.outputChannel else {
                throw AudioError.message("Loop channel must differ from the speaker output channel.")
            }
            guard refCh < Int(inputFormat.channelCount) else {
                throw AudioError.message("Loop needs input channel \(refCh + 1), but the device has only \(inputFormat.channelCount) inputs.")
            }
            guard refCh < Int(outputFormat.channelCount) else {
                throw AudioError.message("Loop needs output channel \(refCh + 1), but the device has only \(outputFormat.channelCount) outputs.")
            }
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
            // Dual-channel loop: the same sweep must leave on the speaker output
            // AND the loop output simultaneously, so the mic captures the acoustic
            // result while the loop input captures the electrical reference from
            // the identical drive signal.
            let loopOutCh = settings.referenceChannel.map { min($0, Int(playerFormat.channelCount) - 1) }
            for ch in 0..<Int(playerFormat.channelCount) {
                if ch == outCh || ch == loopOutCh {
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
        // Connect the player DIRECTLY to the output node (not via mainMixerNode).
        // The mixer applies stereo/spatial rendering and does not preserve discrete
        // per-channel routing — buffer channel 0 reaches out 1, but channel 1 (the
        // loop drive on out 2) gets dropped, leaving the loop input silent. A direct
        // player→outputNode connection at the hardware channel count maps buffer
        // channel N → hardware output N one-to-one, so out 2 actually carries the
        // loop sweep. (Output-side twin of the inputFormat tap fix in AudioDevices.)
        engine.connect(player, to: engine.outputNode, format: playerFormat)

        let capture = Capture()
        let tapFormat = settledInputFormat ?? engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, when in
            capture.append(buffer, channel: settings.inputChannel,
                            referenceChannel: settings.referenceChannel, when: when)
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

        let (captured, referenceCaptured, firstTime) = capture.snapshot()
        guard captured.count >= Int(inRate * 0.5), let first = firstTime, first.isHostTimeValid else {
            throw AudioError.message(
                "Capture failed (\(captured.count) frames). Check microphone permission and input device.")
        }
        if settings.referenceChannel != nil, referenceCaptured.count < captured.count {
            throw AudioError.message(
                "Reference channel capture came up short — check the loop cable and that the reference channel has signal.")
        }

        let peak = captured.reduce(Float(0)) { max($0, abs($1)) }
        let peakDBFS = 20 * log10(max(peak, 1e-10))

        // Where in the capture timeline did the sweep itself start?
        let schedulingOffset = hostTimeDeltaSeconds(from: first.hostTime, to: startHostTime)
        let sweepStartSample = (schedulingOffset + settings.preSilence) * inRate
        let responseStart = max(0, Int(sweepStartSample))
        let response = Array(captured[responseStart...])

        let reference: [Float]
        let usedLoopReference = settings.referenceChannel != nil
        var referencePeakDBFS: Float? = nil
        if usedLoopReference {
            let refPeak = referenceCaptured.reduce(Float(0)) { max($0, abs($1)) }
            referencePeakDBFS = 20 * log10(max(refPeak, 1e-10))
            // Both channels came off the same tap callback, so they share one
            // capture clock — trimming both at the identical index keeps them
            // sample-aligned. Deconvolving against the real captured loop (not
            // the generated sweep) cancels the interface's own DA→AD path and
            // driver jitter, leaving only genuine acoustic time-of-flight.
            reference = Array(referenceCaptured[responseStart...])
        } else {
            reference = outRate == inRate ? playSweep : SignalGenerator.logSweep(
                f1: f1, f2: f2,
                duration: settings.sweepDuration, sampleRate: inRate, amplitude: amplitude)
        }

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
            correlationQualityDB: 20 * log10(max(corr, 1e-5)),
            usedLoopReference: usedLoopReference,
            referencePeakDBFS: referencePeakDBFS
        )
    }

    private func hostTimeDeltaSeconds(from: UInt64, to: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let scale = Double(info.numer) / Double(info.denom) / 1e9
        return to >= from ? Double(to - from) * scale : -Double(from - to) * scale
    }
}
