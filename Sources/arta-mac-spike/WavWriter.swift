import AVFoundation
import Foundation

enum SweepWavWriter {

    static func write(_ sweep: SweepSignal, to path: String) throws {
        try writeMono(sweep.samples, rate: sweep.sampleRate,
                      to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static func writeMono(_ samples: [Float], rate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw SpikeError.message("Could not allocate WAV buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let data = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                data[0].update(from: src.baseAddress!, count: src.count)
            }
        }
        try file.write(from: buffer)
    }
}
