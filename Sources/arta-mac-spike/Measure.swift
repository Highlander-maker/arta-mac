import AVFoundation
import CoreAudio
import Foundation

struct MeasureOptions {
    var inputDeviceID: AudioDeviceID?
    var outputDeviceID: AudioDeviceID?
    var inputChannel: Int = 0    // 0-based
    var outputChannel: Int = 0   // 0-based
    var f1: Double = 20
    var f2: Double = 20_000
    var sweepDuration: Double = 1.5
    var amplitude: Double = 0.25
    var preSilence: Double = 0.2
    var postSilence: Double = 0.8
    var noPhat: Bool = false
    var dumpDir: String?
}

private final class CaptureState {
    let lock = NSLock()
    var samples: [Float] = []
    var firstBufferTime: AVAudioTime?

    func append(_ buffer: AVAudioPCMBuffer, channel: Int, when: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        if firstBufferTime == nil { firstBufferTime = when }
        guard let data = buffer.floatChannelData else { return }
        let ch = min(channel, Int(buffer.format.channelCount) - 1)
        samples.append(contentsOf: UnsafeBufferPointer(
            start: data[ch], count: Int(buffer.frameLength)))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func snapshot() -> ([Float], AVAudioTime?) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, firstBufferTime)
    }
}

enum LoopbackMeasurement {

    // MARK: - Entry point

    static func run(_ options: MeasureOptions) throws {
        try ensureMicrophonePermission()

        let engine = AVAudioEngine()

        // Select devices (before touching formats / starting the engine).
        if let outID = options.outputDeviceID {
            try setDevice(outID, on: engine.outputNode, what: "output")
        }
        if let inID = options.inputDeviceID {
            try setDevice(inID, on: engine.inputNode, what: "input")
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw SpikeError.message(
                "Selected input device has no input channels (or no input device available).")
        }
        guard outputFormat.channelCount > 0, outputFormat.sampleRate > 0 else {
            throw SpikeError.message("Selected output device has no output channels.")
        }
        guard options.inputChannel < Int(inputFormat.channelCount) else {
            throw SpikeError.message(
                "Input channel \(options.inputChannel + 1) out of range: device has \(inputFormat.channelCount) input channel(s).")
        }
        guard options.outputChannel < Int(outputFormat.channelCount) else {
            throw SpikeError.message(
                "Output channel \(options.outputChannel + 1) out of range: device has \(outputFormat.channelCount) output channel(s).")
        }

        let inRate = inputFormat.sampleRate
        let outRate = outputFormat.sampleRate

        print("Full-duplex loopback measurement")
        print("  output: \(deviceName(options.outputDeviceID)) @ \(Int(outRate)) Hz, \(outputFormat.channelCount) ch (sweep on ch \(options.outputChannel + 1))")
        print("  input:  \(deviceName(options.inputDeviceID)) @ \(Int(inRate)) Hz, \(inputFormat.channelCount) ch (capturing ch \(options.inputChannel + 1))")
        print("  sweep:  \(Int(options.f1))-\(Int(options.f2)) Hz, \(options.sweepDuration) s, amplitude \(options.amplitude)")
        if inRate != outRate {
            print("  note: input and output run at different sample rates; delay is computed at the input rate.")
        }
        print("")

        // ---- Playback signal at the output hardware rate ----
        let playbackSweep = SweepSignal.generate(
            f1: options.f1, f2: options.f2,
            duration: options.sweepDuration, sampleRate: outRate,
            amplitude: options.amplitude,
            preSilence: options.preSilence, postSilence: options.postSilence)

        guard let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: outRate,
            channels: outputFormat.channelCount, interleaved: false),
            let playBuffer = AVAudioPCMBuffer(
                pcmFormat: playerFormat,
                frameCapacity: AVAudioFrameCount(playbackSweep.samples.count))
        else {
            throw SpikeError.message("Could not create playback buffer.")
        }
        playBuffer.frameLength = AVAudioFrameCount(playbackSweep.samples.count)
        if let data = playBuffer.floatChannelData {
            for ch in 0..<Int(playerFormat.channelCount) {
                if ch == options.outputChannel {
                    playbackSweep.samples.withUnsafeBufferPointer { src in
                        data[ch].update(from: src.baseAddress!, count: src.count)
                    }
                } else {
                    data[ch].update(repeating: 0, count: playbackSweep.samples.count)
                }
            }
        }

        // ---- Graph: player -> main mixer -> output, tap on input ----
        // One engine hosts both directions so both I/O units are driven by
        // the same engine (and, for a single device, the same device clock).
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let capture = CaptureState()
        let tapFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) {
            buffer, when in
            capture.append(buffer, channel: options.inputChannel, when: when)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw SpikeError.message("Failed to start AVAudioEngine: \(error.localizedDescription)")
        }

        // ---- Schedule playback at a known host time ----
        let leadSeconds = 0.5
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadSeconds)
        player.scheduleBuffer(playBuffer, at: nil, options: [], completionHandler: nil)
        player.play(at: AVAudioTime(hostTime: startHostTime))
        print("Playing sweep and recording (\(String(format: "%.1f", leadSeconds + playbackSweep.totalDuration + 0.5)) s)...")

        // ---- Wait for enough captured audio ----
        let neededFrames = Int((leadSeconds + playbackSweep.totalDuration + 0.5) * inRate)
        let deadline = Date().addingTimeInterval(leadSeconds + playbackSweep.totalDuration + 6.0)
        while capture.count < neededFrames {
            if Date() > deadline {
                break
            }
            usleep(50_000)
        }

        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let (captured, firstBufferTime) = capture.snapshot()
        guard captured.count >= Int(inRate * 0.5), let firstTime = firstBufferTime else {
            throw SpikeError.message(
                "Capture failed: got \(captured.count) frames from the input device. "
                + "Check microphone permission and that the input device is working.")
        }
        guard firstTime.isHostTimeValid else {
            throw SpikeError.message("Input tap did not provide a valid host time; cannot align timelines.")
        }

        // ---- Analysis ----
        analyze(
            captured: captured,
            captureStartHostTime: firstTime.hostTime,
            playbackStartHostTime: startHostTime,
            inRate: inRate,
            options: options)
    }

    // MARK: - Analysis / reporting

    private static func analyze(
        captured: [Float],
        captureStartHostTime: UInt64,
        playbackStartHostTime: UInt64,
        inRate: Double,
        options: MeasureOptions
    ) {
        // Reference sweep re-synthesized at the *input* rate. Its t=0 is the
        // playback start instant, so after removing the known scheduling
        // offset the correlation lag is pure round-trip latency.
        let reference = SweepSignal.generate(
            f1: options.f1, f2: options.f2,
            duration: options.sweepDuration, sampleRate: inRate,
            amplitude: options.amplitude,
            preSilence: options.preSilence, postSilence: options.postSilence)

        // Capture level sanity check.
        let peak = captured.reduce(Float(0)) { max($0, abs($1)) }
        let rms = (captured.reduce(Float(0)) { $0 + $1 * $1 } / Float(captured.count)).squareRoot()
        let peakDB = 20 * log10(max(peak, 1e-10))
        let rmsDB = 20 * log10(max(rms, 1e-10))
        print("")
        print("Captured \(captured.count) frames @ \(Int(inRate)) Hz")
        print(String(format: "  input level: peak %.1f dBFS, RMS %.1f dBFS", peakDB, rmsDB))
        if peakDB < -60 {
            print("  WARNING: input is essentially silent. Is the loopback cable connected")
            print("           and the input gain up? The result below is almost certainly noise.")
        }

        guard let result = generalizedCrossCorrelation(
            reference: reference.samples, captured: captured, phat: !options.noPhat)
        else {
            print("Cross-correlation failed (empty buffers?).")
            return
        }

        // Known offset between the reference timeline (t=0 = scheduled playback
        // start) and the capture timeline (t=0 = first captured frame).
        let schedulingOffsetSeconds = hostTimeDeltaSeconds(
            from: captureStartHostTime, to: playbackStartHostTime)
        let schedulingOffsetSamples = schedulingOffsetSeconds * inRate

        let roundTripSamples = Double(result.lagSamples) - schedulingOffsetSamples
        let roundTripMs = roundTripSamples / inRate * 1000.0

        print("")
        print("Generalized cross-correlation (\(options.noPhat ? "unweighted" : "PHAT"), FFT size \(result.fftSize)):")
        print("  peak at raw index \(result.peakIndex) -> lag \(result.lagSamples) samples")
        print(String(format: "  peak-to-noise: %.1f dB", result.peakToNoiseDB))
        print(String(format: "  playback started %.2f samples (%.2f ms) after capture started (scheduled offset)",
                     schedulingOffsetSamples, schedulingOffsetSeconds * 1000))
        print("")
        print(String(format: "  >>> round-trip delay: %.1f samples = %.3f ms @ %d Hz <<<",
                     roundTripSamples, roundTripMs, Int(inRate)))
        print("")

        if result.peakToNoiseDB < 12 {
            print("  WARNING: correlation peak is weak (< 12 dB above the floor).")
            print("           Treat this delay value as unreliable — most likely the played")
            print("           signal never reached the input (no loopback path).")
        }
        if roundTripSamples < 0 {
            print("  WARNING: negative round-trip delay is not physical. This usually means")
            print("           the correlation locked onto noise or acoustic leakage.")
        }

        // Device-reported latency components for comparison with the measurement.
        printReportedLatencies(options: options, inRate: inRate)

        if let dumpDir = options.dumpDir {
            dumpWavs(reference: reference, captured: captured, inRate: inRate, dir: dumpDir)
        }
    }

    private static func printReportedLatencies(options: MeasureOptions, inRate: Double) {
        let inID = options.inputDeviceID ?? DeviceCatalog.defaultDeviceID(input: true)
        let outID = options.outputDeviceID ?? DeviceCatalog.defaultDeviceID(input: false)
        guard let inID, let outID else { return }
        let inLat = DeviceCatalog.reportedLatency(inID, input: true)
        let outLat = DeviceCatalog.reportedLatency(outID, input: false)
        let totalFrames = Double(inLat.totalFrames + outLat.totalFrames)
        print("")
        print("Device-reported latency components (for comparison):")
        print("  output: latency \(outLat.deviceLatency) + safety \(outLat.safetyOffset) + buffer \(outLat.bufferFrameSize) frames")
        print("  input:  latency \(inLat.deviceLatency) + safety \(inLat.safetyOffset) + buffer \(inLat.bufferFrameSize) frames")
        print(String(format: "  sum: %.0f frames = %.3f ms (measured value above is ground truth; this is what the driver claims)",
                     totalFrames, totalFrames / inRate * 1000))
    }

    // MARK: - Helpers

    private static func ensureMicrophonePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            print("Requesting microphone (audio input) permission...")
            let sema = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                sema.signal()
            }
            sema.wait()
            guard granted else {
                throw SpikeError.message("Microphone permission was denied.")
            }
        default:
            throw SpikeError.message(
                "Microphone access is denied for this terminal. Enable it in "
                + "System Settings > Privacy & Security > Microphone, then re-run.")
        }
    }

    private static func setDevice(
        _ deviceID: AudioDeviceID, on node: AVAudioIONode, what: String
    ) throws {
        guard let unit = node.audioUnit else {
            throw SpikeError.message("No audio unit available on \(what) node.")
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw SpikeError.coreAudio(status, "setting \(what) device to ID \(deviceID)")
        }
    }

    private static func deviceName(_ id: AudioDeviceID?) -> String {
        if let id {
            return "\(DeviceCatalog.info(for: id).name) (ID \(id))"
        }
        let defaultID = DeviceCatalog.defaultDeviceID(input: false)
        _ = defaultID
        return "system default"
    }

    /// Signed (to - from) host-time difference in seconds.
    private static func hostTimeDeltaSeconds(from: UInt64, to: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let scale = Double(info.numer) / Double(info.denom) / 1e9
        if to >= from {
            return Double(to - from) * scale
        } else {
            return -Double(from - to) * scale
        }
    }

    private static func dumpWavs(
        reference: SweepSignal, captured: [Float], inRate: Double, dir: String
    ) {
        let dirURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath,
                         isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dirURL, withIntermediateDirectories: true)
            try SweepWavWriter.writeMono(
                reference.samples, rate: inRate,
                to: dirURL.appendingPathComponent("reference.wav"))
            try SweepWavWriter.writeMono(
                captured, rate: inRate,
                to: dirURL.appendingPathComponent("captured.wav"))
            print("")
            print("Dumped reference.wav and captured.wav to \(dirURL.path)")
        } catch {
            print("WAV dump failed: \(error.localizedDescription)")
        }
    }
}
