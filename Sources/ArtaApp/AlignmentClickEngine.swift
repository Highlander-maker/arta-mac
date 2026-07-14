import AVFoundation
import Foundation
import ArtaDSP

/// Plays a repeating click simultaneously on two output channels (e.g. main
/// hang + subs), with an adjustable relative delay between them, so sub/top
/// timing can be nudged into alignment by ear. Both channels are written into
/// one multichannel buffer on a single device so the relative offset is
/// sample-accurate — the same reasoning as MeasurementEngine's full-duplex
/// clock requirement, just for output-only playback.
final class AlignmentClickEngine {

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private(set) var isRunning = false

    /// - Parameter delayMsB: relative delay of channel B versus channel A, in
    ///   milliseconds. Positive = B (sub) plays later than A (main); negative
    ///   = B plays earlier. Wraps within the click period, so magnitude should
    ///   stay well under 1000/rateHz.
    func start(
        channelA: Int, channelB: Int, delayMsB: Double, rateHz: Double,
        levelDB: Double, outputDeviceID: AudioDeviceID?
    ) throws {
        stop()

        let engine = AVAudioEngine()
        if let id = outputDeviceID {
            try AudioDevices.ensureDevice(id, on: engine.outputNode, what: "alignment click output")
        }
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let rate = outFormat.sampleRate
        let channels = Int(outFormat.channelCount)
        guard rate > 0, channels > 0 else {
            throw AudioError.message("Selected output device has no output channels.")
        }

        let rate_ = min(max(rateHz, 0.2), 20.0)
        let periodFrames = max(8, Int((rate / rate_).rounded()))
        let burst = SignalGenerator.clickBurst(sampleRate: rate)

        var chA = [Float](repeating: 0, count: periodFrames)
        var chB = [Float](repeating: 0, count: periodFrames)
        place(burst, into: &chA, at: 0)
        let delaySamples = Int((delayMsB / 1000.0 * rate).rounded())
        let startB = ((delaySamples % periodFrames) + periodFrames) % periodFrames
        place(burst, into: &chB, at: startB)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: outFormat.channelCount, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(periodFrames))
        else { throw AudioError.message("Could not create alignment click buffer.") }

        buffer.frameLength = AVAudioFrameCount(periodFrames)
        if let data = buffer.floatChannelData {
            let outA = min(channelA, channels - 1)
            let outB = min(channelB, channels - 1)
            for ch in 0..<channels {
                if ch == outA && ch == outB {
                    // Same channel picked for both — sum so it's still audible.
                    var summed = [Float](repeating: 0, count: periodFrames)
                    for i in 0..<periodFrames { summed[i] = max(-1, min(1, chA[i] + chB[i])) }
                    summed.withUnsafeBufferPointer { src in data[ch].update(from: src.baseAddress!, count: src.count) }
                } else if ch == outA {
                    chA.withUnsafeBufferPointer { src in data[ch].update(from: src.baseAddress!, count: src.count) }
                } else if ch == outB {
                    chB.withUnsafeBufferPointer { src in data[ch].update(from: src.baseAddress!, count: src.count) }
                } else {
                    data[ch].update(repeating: 0, count: periodFrames)
                }
            }
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioError.message("Failed to start alignment click engine: \(error.localizedDescription)")
        }

        player.volume = Float(pow(10.0, levelDB / 20.0))
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()

        self.engine = engine
        self.player = player
        isRunning = true
    }

    func setLevel(dB: Double) {
        player?.volume = Float(pow(10.0, dB / 20.0))
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        isRunning = false
    }

    private func place(_ burst: [Float], into buf: inout [Float], at start: Int) {
        let n = buf.count
        for i in 0..<burst.count {
            buf[(start + i) % n] += burst[i]
        }
    }
}
