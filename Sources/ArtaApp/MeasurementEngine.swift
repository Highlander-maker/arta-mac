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
    var systemDelaySamples: Double      // direct-sound arrival, from the IR peak
    var capturedPeakDBFS: Float
    var correlationQualityDB: Float
    var usedLoopReference: Bool = false
    /// Peak of the captured loop/reference channel (dBFS), nil when sweep ref.
    /// The live meters are stopped during a measurement, so this is the only
    /// visible proof that the loop channel actually carried signal.
    var referencePeakDBFS: Float? = nil
}

/// One shaped-tone-burst measurement (Linkwitz, JAES 1980): fires N cycles of a
/// windowed sine at a single frequency, captures the acoustic result, and reads
/// the envelope. The envelope's PEAK is the frequency-response magnitude at f0;
/// its SHAPE (build-up + ring-out) exposes localized resonances. Reuses the same
/// proven full-duplex plumbing as the sweep path.
struct BurstSettings {
    var inputDeviceID: AudioDeviceID?
    var outputDeviceID: AudioDeviceID?
    var inputChannel: Int = 0
    var outputChannel: Int = 0
    var frequency: Double = 1000
    var cycles: Int = 5
    var envelope: SignalGenerator.BurstEnvelope = .raisedCosine
    var amplitudeDB: Double = -12       // output level dBFS
    var preSilence: Double = 0.2
    var tailSeconds: Double = 0.08      // ring-out captured after the burst ends
    var referenceChannel: Int? = nil
}

/// What a burst's arrival time is measured relative to.
enum BurstTimingReference: String, Codable {
    /// The host-time instant playback was scheduled for. Includes the interface's
    /// converter latency and any error in the scheduling estimate itself.
    case playbackSchedule
    /// The burst as it arrives back on the loop-reference input — the electrical
    /// send, captured on the same clock as the mic. Subtracting this cancels record-
    /// start delay, DA/AD latency and driver jitter, leaving acoustic flight only.
    /// This is Digby's "set trigger to be reference input": the sweep path already
    /// deconvolves against the captured loop for exactly this reason.
    case loopReference

    var label: String {
        switch self {
        case .playbackSchedule: return "schedule"
        case .loopReference: return "loop ref"
        }
    }
}

struct BurstResult: Codable {
    var frequency: Double
    var cycles: Int
    var sampleRate: Double
    /// The shaped burst we sent (at the capture rate) — the ideal envelope.
    var stimulus: [Float]
    /// The captured acoustic response, windowed around the burst arrival.
    var response: [Float]
    var stimulusEnvelope: [Float]
    var responseEnvelope: [Float]
    var burstLengthSamples: Int         // stimulus burst length at capture rate
    var arrivalSample: Int              // index within `response` where the burst lands
    /// Arrival relative to the deterministic playback-schedule instant
    /// (`arrivalAbs - coarseOnset` in `measureBurst()`), in samples at this
    /// result's own `sampleRate`. Fixed I/O latency is baked into the schedule
    /// instant the same way on every capture from the same device/routing, so
    /// subtracting this value between two `BurstResult`s (each converted to
    /// seconds via its own `sampleRate` first) cancels that latency and leaves
    /// pure acoustic-path timing difference — see `Analysis.burstArrivalDeltaSeconds`.
    /// Optional so a `.tbr` saved before this field existed still decodes (as
    /// `nil` = "no arrival-delta capability", never a false zero).
    var arrivalOffsetSamples: Int?
    /// Which zero `arrivalOffsetSamples` is measured from. The two are NOT
    /// interchangeable — they differ by the interface's electrical round trip
    /// (DA→AD, typically several ms), so a Δ taken across one of each is wrong by
    /// that amount. `AppModel.burstDeltaMs` refuses to mix them.
    var timingReference: BurstTimingReference?
    var capturedPeakDBFS: Float         // peak of the raw captured signal
    var responseEnvelopePeak: Float     // peak of the response envelope (linear)
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

    // MARK: - Shared full-duplex plumbing
    //
    // Both the sweep and the tone-burst measurement play a signal on one output
    // (optionally mirrored onto a loop output) while capturing one input
    // (optionally plus a loop input) on a single AVAudioEngine. The device
    // settling, discrete-channel routing and host-time scheduling below are the
    // proven Phase-0 path — factored out so a fix reaches both measurements.

    /// The channel/device fields the duplex helpers need, independent of which
    /// measurement (sweep vs burst) owns the surrounding settings.
    private struct DuplexPlan {
        var inputDeviceID: AudioDeviceID?
        var outputDeviceID: AudioDeviceID?
        var inputChannel: Int
        var outputChannel: Int
        var referenceChannel: Int?
    }

    private struct DuplexConfig {
        let inputFormat: AVAudioFormat
        let outputFormat: AVAudioFormat
        let settledInputFormat: AVAudioFormat?
        var inRate: Double { inputFormat.sampleRate }
        var outRate: Double { outputFormat.sampleRate }
    }

    /// Settle the device, validate the split-device / channel constraints, and
    /// return the input/output formats.
    private func configureDuplex(_ engine: AVAudioEngine, plan: DuplexPlan) throws -> DuplexConfig {
        // macOS quirk: inputNode and outputNode share ONE AUHAL, which the
        // engine binds to a private aggregate of the system default devices.
        // Setting a device on it is only valid once, so the supported configs
        // are: (a) system defaults — touch nothing, the aggregate handles
        // full duplex; (b) one full-duplex interface for both directions —
        // a single set (the reference configuration: one clock).
        let defIn = AudioDevices.defaultDeviceID(input: true)
        let defOut = AudioDevices.defaultDeviceID(input: false)
        let wantIn = plan.inputDeviceID ?? defIn
        let wantOut = plan.outputDeviceID ?? defOut
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
        if let refCh = plan.referenceChannel {
            // The loop uses one channel number for both the output that drives it
            // and the input that captures it (out N → in N), matching how the
            // dual-channel loop is physically patched.
            guard refCh != plan.inputChannel else {
                throw AudioError.message("Loop channel must differ from the mic (measurement) channel.")
            }
            guard refCh != plan.outputChannel else {
                throw AudioError.message("Loop channel must differ from the speaker output channel.")
            }
            guard refCh < Int(inputFormat.channelCount) else {
                throw AudioError.message("Loop needs input channel \(refCh + 1), but the device has only \(inputFormat.channelCount) inputs.")
            }
            guard refCh < Int(outputFormat.channelCount) else {
                throw AudioError.message("Loop needs output channel \(refCh + 1), but the device has only \(outputFormat.channelCount) outputs.")
            }
        }
        return DuplexConfig(inputFormat: inputFormat, outputFormat: outputFormat, settledInputFormat: settledInputFormat)
    }

    /// Build the multichannel playback buffer, placing `playSignal` on the speaker
    /// output and (if used) mirroring it onto the loop output, silence elsewhere.
    private func makePlaybackBuffer(
        playSignal: [Float], plan: DuplexPlan, playerFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let playBuffer = AVAudioPCMBuffer(
            pcmFormat: playerFormat, frameCapacity: AVAudioFrameCount(playSignal.count))
        else { throw AudioError.message("Could not create playback buffer.") }

        playBuffer.frameLength = AVAudioFrameCount(playSignal.count)
        if let data = playBuffer.floatChannelData {
            let outCh = min(plan.outputChannel, Int(playerFormat.channelCount) - 1)
            // Dual-channel loop: the same signal must leave on the speaker output
            // AND the loop output simultaneously, so the mic captures the acoustic
            // result while the loop input captures the electrical reference from
            // the identical drive signal.
            let loopOutCh = plan.referenceChannel.map { min($0, Int(playerFormat.channelCount) - 1) }
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
        return playBuffer
    }

    /// Schedule playback on a fresh player node and capture the input(s) until the
    /// signal has played out. Returns the raw captured channel, the raw loop
    /// reference channel (empty when unused), and the scheduling offset in seconds
    /// (where in the capture timeline t=0 of `playSignal` actually landed).
    private func captureDuplex(
        engine: AVAudioEngine,
        playBuffer: AVAudioPCMBuffer,
        playerFormat: AVAudioFormat,
        plan: DuplexPlan,
        tapFormat: AVAudioFormat,
        inRate: Double,
        totalDuration: Double
    ) throws -> (captured: [Float], reference: [Float], schedulingOffset: Double) {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // Connect the player DIRECTLY to the output node (not via mainMixerNode).
        // The mixer applies stereo/spatial rendering and does not preserve discrete
        // per-channel routing — buffer channel 0 reaches out 1, but channel 1 (the
        // loop drive on out 2) gets dropped, leaving the loop input silent. A direct
        // player→outputNode connection at the hardware channel count maps buffer
        // channel N → hardware output N one-to-one, so out 2 actually carries the
        // loop signal. (Output-side twin of the inputFormat tap fix in AudioDevices.)
        engine.connect(player, to: engine.outputNode, format: playerFormat)

        let capture = Capture()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, when in
            capture.append(buffer, channel: plan.inputChannel,
                            referenceChannel: plan.referenceChannel, when: when)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioError.message("Failed to start audio engine: \(error.localizedDescription)")
        }

        let leadSeconds = 0.5
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
        if plan.referenceChannel != nil, referenceCaptured.count < captured.count {
            throw AudioError.message(
                "Reference channel capture came up short — check the loop cable and that the reference channel has signal.")
        }

        let schedulingOffset = hostTimeDeltaSeconds(from: first.hostTime, to: startHostTime)
        return (captured, referenceCaptured, schedulingOffset)
    }

    // MARK: - Sweep measurement

    /// Runs the sweep measurement synchronously (call from a background queue).
    func measure(settings: MeasurementSettings) throws -> MeasurementResult {
        guard state == .idle else { throw AudioError.message("A measurement is already running.") }
        state = .running
        defer { state = .idle }

        try ensureMicrophonePermission()

        let engine = AVAudioEngine()
        let plan = DuplexPlan(
            inputDeviceID: settings.inputDeviceID, outputDeviceID: settings.outputDeviceID,
            inputChannel: settings.inputChannel, outputChannel: settings.outputChannel,
            referenceChannel: settings.referenceChannel)
        let config = try configureDuplex(engine, plan: plan)
        let inRate = config.inRate
        let outRate = config.outRate
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
            channels: config.outputFormat.channelCount, interleaved: false)
        else { throw AudioError.message("Could not create playback format.") }
        let playBuffer = try makePlaybackBuffer(playSignal: playSignal, plan: plan, playerFormat: playerFormat)

        let totalDuration = settings.preSilence + settings.sweepDuration + settings.postSilence
        let tapFormat = config.settledInputFormat ?? engine.inputNode.outputFormat(forBus: 0)
        let (captured, referenceCaptured, schedulingOffset) = try captureDuplex(
            engine: engine, playBuffer: playBuffer, playerFormat: playerFormat, plan: plan,
            tapFormat: tapFormat, inRate: inRate, totalDuration: totalDuration)

        let peak = captured.reduce(Float(0)) { max($0, abs($1)) }
        let peakDBFS = 20 * log10(max(peak, 1e-10))

        // Where in the capture timeline did the sweep itself start?
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

        // Cross-correlation is kept only for the correlation-quality figure. Its own
        // lag is NOT trusted for the delay readout: with a log sweep it inherits the
        // excitation's pink weighting and drifts toward late low-frequency room
        // energy — it read 16 ms long on a 7.7 m throw in a reverberant room while
        // the deconvolved IR peak matched a tape measure to 6 cm.
        let (_, corr) = Deconvolution.estimateDelay(reference: reference, measured: response)
        var ir = Deconvolution.impulseResponse(excitation: reference, response: response)

        // The deconvolution whitens the excitation spectrum, so the IR peak is a
        // sharp delta at the genuine direct-sound arrival. That is the delay figure.
        let lag = Deconvolution.peakIndex(of: ir)

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

    // MARK: - Shaped tone-burst measurement

    /// Runs one shaped-tone-burst measurement synchronously (call from a background
    /// queue). Plays N windowed cycles at a single frequency, captures the acoustic
    /// response, aligns it to the burst arrival, and returns the response together
    /// with its envelope and the ideal stimulus envelope for comparison.
    func measureBurst(settings: BurstSettings) throws -> BurstResult {
        guard state == .idle else { throw AudioError.message("A measurement is already running.") }
        state = .running
        defer { state = .idle }

        try ensureMicrophonePermission()

        let engine = AVAudioEngine()
        let plan = DuplexPlan(
            inputDeviceID: settings.inputDeviceID, outputDeviceID: settings.outputDeviceID,
            inputChannel: settings.inputChannel, outputChannel: settings.outputChannel,
            referenceChannel: settings.referenceChannel)
        let config = try configureDuplex(engine, plan: plan)
        let inRate = config.inRate
        let outRate = config.outRate
        let amplitude = pow(10.0, settings.amplitudeDB / 20.0)

        // Keep the burst carrier inside both converters' Nyquist with margin.
        let fMax = min(inRate, outRate) * 0.45
        let f0 = min(max(settings.frequency, 10.0), fMax)
        let cycles = max(1, settings.cycles)

        let playBurst = SignalGenerator.shapedToneBurst(
            frequency: f0, cycles: cycles, sampleRate: outRate, amplitude: amplitude,
            envelope: settings.envelope)
        let burstSeconds = Double(playBurst.count) / outRate
        // Capture at least a full burst-length of ring-out (plus margin) so the
        // "one burst-length after the burst ends" metric always lands inside the
        // window. A low-frequency burst is long — a 5-cycle burst at 50 Hz is
        // 100 ms — and would outrun a fixed 80 ms tail, blanking the ring-out
        // readout below ~62 Hz. Scaling the tail with the burst keeps it valid to
        // the bottom of the band.
        let effectiveTail = max(settings.tailSeconds, burstSeconds * 1.25)
        let preFrames = Int(settings.preSilence * outRate)
        let tailFrames = Int(effectiveTail * outRate)
        // Extra silence past the ring-out tail to absorb system latency before the
        // capture loop gives up.
        let postFrames = tailFrames + Int(0.3 * outRate)
        let playSignal = [Float](repeating: 0, count: preFrames) + playBurst
            + [Float](repeating: 0, count: postFrames)

        guard let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: outRate,
            channels: config.outputFormat.channelCount, interleaved: false)
        else { throw AudioError.message("Could not create playback format.") }
        let playBuffer = try makePlaybackBuffer(playSignal: playSignal, plan: plan, playerFormat: playerFormat)

        let totalDuration = settings.preSilence
            + Double(playBurst.count) / outRate + Double(postFrames) / outRate
        let tapFormat = config.settledInputFormat ?? engine.inputNode.outputFormat(forBus: 0)
        let (captured, referenceCaptured, schedulingOffset) = try captureDuplex(
            engine: engine, playBuffer: playBuffer, playerFormat: playerFormat, plan: plan,
            tapFormat: tapFormat, inRate: inRate, totalDuration: totalDuration)

        let peak = captured.reduce(Float(0)) { max($0, abs($1)) }
        let peakDBFS = 20 * log10(max(peak, 1e-10))

        // The ideal stimulus at the capture rate: used both as the envelope overlay
        // and as the matched filter to find the burst's arrival in the capture.
        let stimulus = outRate == inRate ? playBurst : SignalGenerator.shapedToneBurst(
            frequency: f0, cycles: cycles, sampleRate: inRate, amplitude: amplitude,
            envelope: settings.envelope)
        let burstLenIn = stimulus.count

        // The scheduling offset is a deterministic host-time anchor for the digital
        // send, so this is where the burst leaves the converter in the captured
        // buffer; the acoustic arrival is a bounded latency after it. Locating that
        // arrival (envelope peak, not cross-correlation — see the method's doc) lives
        // in ArtaDSP so it can be unit-tested without live audio hardware.
        let coarseOnset = max(0, Int((schedulingOffset + settings.preSilence) * inRate))
        guard let arrivalAbs = Analysis.burstArrivalIndex(
            in: captured,
            scheduledOnsetSample: coarseOnset,
            burstLengthSamples: burstLenIn,
            sampleRate: inRate,
            frequency: f0
        ) else {
            throw AudioError.message(
                "Could not locate the burst in the capture — nothing audible arrived in the search window. "
                + "Check the input level and that the output is reaching the speaker.")
        }
        // Zero the arrival against the loop reference when there is one: the same
        // burst captured electrically on the same clock as the mic. Subtracting it
        // removes record-start delay, converter latency and driver jitter, so what
        // is left is acoustic flight alone. Without a loop, fall back to the
        // host-time schedule anchor — still comparable between two captures on the
        // same device, just carrying the converter latency in both.
        //
        // A loop that is enabled but silent (cable out, wrong channel) fails to
        // locate and falls back. That is recorded honestly in `timingReference`
        // rather than passing itself off as a reference-triggered measurement.
        let timingReference: BurstTimingReference
        let zeroSample: Int
        if settings.referenceChannel != nil,
           let refArrival = Analysis.burstArrivalIndex(
               in: referenceCaptured,
               scheduledOnsetSample: coarseOnset,
               burstLengthSamples: burstLenIn,
               sampleRate: inRate,
               frequency: f0) {
            zeroSample = refArrival
            timingReference = .loopReference
        } else {
            zeroSample = coarseOnset
            timingReference = .playbackSchedule
        }
        // Comparable across separate measureBurst() calls, unlike arrivalSample
        // below (which is just a local windowing clamp) — see the doc comment on
        // BurstResult.arrivalOffsetSamples. Can legitimately be negative; don't clamp.
        let arrivalOffsetSamples = arrivalAbs - zeroSample

        // Window the response: a short lead-in before arrival, then the burst plus
        // its ring-out tail. The lead-in shows the pre-arrival quiet so the build-up
        // reads clearly.
        let leadPad = min(arrivalAbs, Int(0.002 * inRate))
        let windowStart = arrivalAbs - leadPad
        let windowLen = leadPad + burstLenIn + Int(effectiveTail * inRate)
        let windowEnd = min(captured.count, windowStart + windowLen)
        let response = Array(captured[windowStart..<max(windowStart + 1, windowEnd)])

        let responseEnvelope = Analysis.analyticEnvelope(response)
        let stimulusEnvelope = Analysis.analyticEnvelope(stimulus)
        let responseEnvelopePeak = responseEnvelope.max() ?? 0

        return BurstResult(
            frequency: f0,
            cycles: cycles,
            sampleRate: inRate,
            stimulus: stimulus,
            response: response,
            stimulusEnvelope: stimulusEnvelope,
            responseEnvelope: responseEnvelope,
            burstLengthSamples: burstLenIn,
            arrivalSample: leadPad,
            arrivalOffsetSamples: arrivalOffsetSamples,
            timingReference: timingReference,
            capturedPeakDBFS: peakDBFS,
            responseEnvelopePeak: responseEnvelopePeak
        )
    }

    private func hostTimeDeltaSeconds(from: UInt64, to: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let scale = Double(info.numer) / Double(info.denom) / 1e9
        return to >= from ? Double(to - from) * scale : -Double(from - to) * scale
    }
}
