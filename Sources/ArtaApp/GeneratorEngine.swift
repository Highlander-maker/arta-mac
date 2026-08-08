import AVFoundation
import Foundation
import ArtaDSP

/// Continuous test-signal generator for alignment work: steady sine (sub/top
/// delay alignment by ear or meter), full-range pink noise, and band-limited
/// pink noise (crossover-region checks). Signals are rendered into a loop
/// buffer — sines use a whole number of cycles and noise gets a short
/// end-to-start crossfade, so the loop seam is inaudible.
final class GeneratorEngine {

    enum Kind: Equatable {
        case sine(frequency: Double)
        case pink
        case pinkBand(center: Double, fraction: Int)
        /// A shaped tone burst repeated with a settling gap — used to gain-stage a
        /// burst measurement. Unlike a steady sine, it previews the *transient*
        /// peak the real burst produces, so low-frequency room-mode buildup can't
        /// make the meter over-read what the burst will actually deliver.
        case burstTrain(frequency: Double, cycles: Int,
                        envelope: SignalGenerator.BurstEnvelope = .raisedCosine)
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private(set) var isRunning = false

    /// `loopChannel` (optional) mirrors the signal onto a second output — the
    /// dual-channel loop drive — so the loop input can be gain-staged live
    /// against the meters before a measurement.
    func start(kind: Kind, levelDB: Double, outputDeviceID: AudioDeviceID?, outputChannel: Int,
               loopChannel: Int? = nil) throws {
        stop()

        let engine = AVAudioEngine()
        if let id = outputDeviceID {
            // Output-only engine: a single device set is fine; skip when it's
            // already the bound device (re-setting the AUHAL corrupts it).
            try AudioDevices.ensureDevice(id, on: engine.outputNode, what: "generator output")
        }
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let rate = outFormat.sampleRate
        let channels = Int(outFormat.channelCount)
        guard rate > 0, channels > 0 else {
            throw AudioError.message("Selected output device has no output channels.")
        }

        let mono = renderLoop(kind: kind, sampleRate: rate)
        guard !mono.isEmpty else { throw AudioError.message("Could not render generator signal.") }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: outFormat.channelCount, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count))
        else { throw AudioError.message("Could not create generator buffer.") }

        buffer.frameLength = AVAudioFrameCount(mono.count)
        if let data = buffer.floatChannelData {
            let outCh = min(outputChannel, channels - 1)
            let loopCh = loopChannel.map { min($0, channels - 1) }
            for ch in 0..<channels {
                if ch == outCh || ch == loopCh {
                    mono.withUnsafeBufferPointer { src in
                        data[ch].update(from: src.baseAddress!, count: src.count)
                    }
                } else {
                    data[ch].update(repeating: 0, count: mono.count)
                }
            }
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        // Direct player→outputNode: the mixer's stereo rendering drops discrete
        // channels past 0, so a generator aimed at out 2+ would go silent (same
        // fix as MeasurementEngine's loop drive).
        engine.connect(player, to: engine.outputNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioError.message("Failed to start generator engine: \(error.localizedDescription)")
        }

        player.volume = Float(pow(10.0, levelDB / 20.0))
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()

        self.engine = engine
        self.player = player
        isRunning = true
    }

    /// Level changes don't need a re-render — just scale the player.
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

    // MARK: Signal rendering

    /// Renders one seamless loop of the signal at unity peak (~0.95).
    private func renderLoop(kind: Kind, sampleRate: Double) -> [Float] {
        switch kind {
        case .sine(let frequency):
            let f = min(max(frequency, 1.0), sampleRate * 0.45)
            // Whole number of cycles over ~1 s so the loop wraps phase-exactly.
            let cycles = max(1.0, (f * 1.0).rounded())
            let frames = Int((cycles * sampleRate / f).rounded())
            return (0..<frames).map {
                Float(0.95 * sin(2.0 * .pi * f * Double($0) / sampleRate))
            }

        case .pink:
            return seamlessNoiseLoop(
                SignalGenerator.pinkNoise(count: Int(sampleRate * 4), amplitude: 1.0),
                sampleRate: sampleRate)

        case .pinkBand(let center, let fraction):
            let f0 = min(max(center, 10.0), sampleRate * 0.45)
            // Extra headroom before filtering: the band filter removes most energy.
            let raw = SignalGenerator.pinkNoise(count: Int(sampleRate * 4), amplitude: 1.0)
            let banded = BandFilters.bandpass(
                signal: raw, center: f0, fraction: max(1, fraction), sampleRate: sampleRate)
            return seamlessNoiseLoop(banded, sampleRate: sampleRate)

        case .burstTrain(let frequency, let cycles, let envelope):
            let f = min(max(frequency, 10.0), sampleRate * 0.45)
            let c = max(1, cycles)
            // The same shaped burst the measurement fires — including its envelope,
            // so the level preview stays a preview of the real thing — at ~unity
            // peak. It tapers to zero at both ends, so appending a silent gap loops
            // seamlessly.
            let burst = SignalGenerator.shapedToneBurst(
                frequency: f, cycles: c, sampleRate: sampleRate, amplitude: 0.95,
                envelope: envelope)
            // Gap ≥ three burst-lengths (min 400 ms) so low-frequency room modes
            // decay between hits — otherwise successive bursts build the room up and
            // the peak-hold over-reads what a single measurement burst delivers.
            let burstSeconds = Double(burst.count) / sampleRate
            let gapSeconds = max(0.4, burstSeconds * 3.0)
            return burst + [Float](repeating: 0, count: Int(gapSeconds * sampleRate))
        }
    }

    /// Peak-normalize and crossfade the tail into the head (20 ms) so a looped
    /// noise buffer has no seam click.
    private func seamlessNoiseLoop(_ signal: [Float], sampleRate: Double) -> [Float] {
        var out = signal
        let peak = out.map(abs).max() ?? 1
        if peak > 0 {
            let g = 0.95 / peak
            for i in 0..<out.count { out[i] *= g }
        }
        let fade = min(Int(sampleRate * 0.02), out.count / 4)
        guard fade > 1 else { return out }
        let n = out.count
        for i in 0..<fade {
            let w = Float(i) / Float(fade - 1) // 0 -> 1 across the head
            out[i] = out[i] * w + out[n - fade + i] * (1 - w)
        }
        return Array(out[0..<(n - fade)])
    }
}
