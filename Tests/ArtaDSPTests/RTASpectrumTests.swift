import XCTest
@testable import ArtaDSP

final class RTASpectrumTests: XCTestCase {

    private let fs = 48000.0

    /// A frame of a sine placed exactly on an FFT bin, so there's no scalloping
    /// loss to muddy the amplitude check.
    private func onBinSine(fftSize: Int, bin: Int, amplitude: Float) -> [Float] {
        let f = Double(bin) * fs / Double(fftSize)
        return (0..<fftSize).map { i in
            amplitude * Float(sin(2 * .pi * f * Double(i) / fs))
        }
    }

    private func makeSpectrum(fftSize: Int = 8192,
                              smoothing: Int = 0,
                              averaging: RTASpectrum.Averaging = .off,
                              hopSeconds: Double = 2048.0 / 48000.0) -> RTASpectrum {
        guard let s = RTASpectrum(fftSize: fftSize, sampleRate: fs, hopSeconds: hopSeconds,
                                  smoothing: smoothing, averaging: averaging) else {
            fatalError("RTASpectrum init failed")
        }
        return s
    }

    // MARK: Calibration

    func testFullScaleSineReadsZeroDBFS() {
        for fftSize in [2048, 8192, 32768] {
            let spectrum = makeSpectrum(fftSize: fftSize)
            let db = spectrum.process(frame: onBinSine(fftSize: fftSize, bin: 100, amplitude: 1.0))
            let peak = db.max() ?? -999
            XCTAssertEqual(peak, 0, accuracy: 0.05,
                           "full-scale sine should read 0 dBFS at fftSize \(fftSize)")
        }
    }

    func testHalfScaleSineReadsMinusSixDB() {
        let spectrum = makeSpectrum()
        let db = spectrum.process(frame: onBinSine(fftSize: 8192, bin: 100, amplitude: 0.5))
        XCTAssertEqual(db.max() ?? -999, -6.02, accuracy: 0.05)
    }

    func testPeakLandsOnTheCorrectFrequency() {
        let fftSize = 8192
        let bin = 256
        let spectrum = makeSpectrum(fftSize: fftSize)
        let db = spectrum.process(frame: onBinSine(fftSize: fftSize, bin: bin, amplitude: 1.0))
        let peakIndex = db.indices.max(by: { db[$0] < db[$1] })!
        XCTAssertEqual(peakIndex, bin, "peak bin should match the excitation bin")
        XCTAssertEqual(spectrum.frequencies[peakIndex],
                       Double(bin) * fs / Double(fftSize), accuracy: 0.001)
    }

    func testWrongLengthFrameIsRejected() {
        let spectrum = makeSpectrum(fftSize: 8192)
        XCTAssertTrue(spectrum.process(frame: [Float](repeating: 0, count: 4096)).isEmpty)
    }

    // MARK: Temporal averaging

    /// The whole point of deriving alpha from `hopSeconds`: one time constant's
    /// worth of frames must land ~63% of the way to the target *regardless* of FFT
    /// size or hop rate. Checked in the power domain, which is where it averages.
    func testFastAveragingReachesOneTimeConstantIndependentOfHop() {
        for (fftSize, hop) in [(2048, 1024), (8192, 2048), (32768, 2048)] {
            let hopSeconds = Double(hop) / fs
            let spectrum = makeSpectrum(fftSize: fftSize, averaging: .fast, hopSeconds: hopSeconds)
            let tau = RTASpectrum.Averaging.fast.timeConstant!

            // Seed the average at silence, then drive it with a steady tone.
            _ = spectrum.process(frame: [Float](repeating: 0, count: fftSize))
            let tone = onBinSine(fftSize: fftSize, bin: 100, amplitude: 1.0)

            let framesPerTau = Int((tau / hopSeconds).rounded())
            var db: [Float] = []
            for _ in 0..<framesPerTau { db = spectrum.process(frame: tone) }

            // Target is 0 dBFS => power 1.0. After one tau: 1 - e^-1 = 0.632.
            let power = pow(10, Double(db.max() ?? -999) / 10)
            XCTAssertEqual(power, 0.632, accuracy: 0.03,
                           "fftSize \(fftSize)/hop \(hop) should hit ~63% of target after one time constant")
        }
    }

    func testSlowAveragesMoreSlowlyThanFast() {
        let fftSize = 8192
        let tone = onBinSine(fftSize: fftSize, bin: 100, amplitude: 1.0)
        var results: [RTASpectrum.Averaging: Double] = [:]
        for mode in [RTASpectrum.Averaging.fast, .slow] {
            let spectrum = makeSpectrum(fftSize: fftSize, averaging: mode)
            _ = spectrum.process(frame: [Float](repeating: 0, count: fftSize))
            var db: [Float] = []
            for _ in 0..<3 { db = spectrum.process(frame: tone) }
            results[mode] = Double(db.max() ?? -999)
        }
        XCTAssertLessThan(results[.slow]!, results[.fast]!,
                          "after the same few frames Slow should still be further from the target")
    }

    func testAveragingOffTracksInstantly() {
        let fftSize = 8192
        let spectrum = makeSpectrum(fftSize: fftSize, averaging: .off)
        _ = spectrum.process(frame: [Float](repeating: 0, count: fftSize))
        let db = spectrum.process(frame: onBinSine(fftSize: fftSize, bin: 100, amplitude: 1.0))
        XCTAssertEqual(db.max() ?? -999, 0, accuracy: 0.05,
                       "with averaging off a single frame should read the true level")
    }

    func testResetClearsTheRunningAverage() {
        let fftSize = 8192
        let spectrum = makeSpectrum(fftSize: fftSize, averaging: .slow)
        let tone = onBinSine(fftSize: fftSize, bin: 100, amplitude: 1.0)
        _ = spectrum.process(frame: [Float](repeating: 0, count: fftSize))
        for _ in 0..<5 { _ = spectrum.process(frame: tone) }
        spectrum.reset()
        // After a reset the next frame seeds the average outright.
        let db = spectrum.process(frame: tone)
        XCTAssertEqual(db.max() ?? -999, 0, accuracy: 0.05)
    }

    // MARK: Smoothing interaction

    func testSmoothingKeepsBroadbandLevelAndTamesASingleTone() {
        let fftSize = 8192
        let tone = onBinSine(fftSize: fftSize, bin: 100, amplitude: 1.0)
        let sharp = makeSpectrum(fftSize: fftSize, smoothing: 0).process(frame: tone)
        let smoothed = makeSpectrum(fftSize: fftSize, smoothing: 6).process(frame: tone)
        // 1/6-octave banding spreads one bin's energy over its band, so the peak
        // must come down — but stay finite and sane, not collapse to the floor.
        XCTAssertLessThan(smoothed.max() ?? 0, sharp.max() ?? 0)
        XCTAssertGreaterThan(smoothed.max() ?? -999, -40)
    }

    // MARK: Phase unwrap

    func testUnwrapProducesAContinuousRamp() {
        // A pure delay ramps phase linearly and wraps repeatedly; unwrapping must
        // recover the straight line.
        let slopePerBin = -37.0
        let wrapped: [Float] = (0..<200).map { i in
            var p = slopePerBin * Double(i)
            p = p.truncatingRemainder(dividingBy: 360)
            if p > 180 { p -= 360 } else if p < -180 { p += 360 }
            return Float(p)
        }
        let unwrapped = PhaseUnwrap.degrees(wrapped)
        for i in 0..<200 {
            XCTAssertEqual(unwrapped[i], slopePerBin * Double(i), accuracy: 0.01,
                           "unwrapped phase should recover the original ramp at index \(i)")
        }
    }

    func testUnwrapLeavesAlreadyContinuousDataAlone() {
        let gentle: [Float] = (0..<50).map { Float(-2.0 * Double($0)) }  // never wraps
        let unwrapped = PhaseUnwrap.degrees(gentle)
        for i in gentle.indices {
            XCTAssertEqual(unwrapped[i], Double(gentle[i]), accuracy: 0.001)
        }
    }

    func testUnwrapHandlesEmptyAndSingleSample() {
        XCTAssertTrue(PhaseUnwrap.degrees([]).isEmpty)
        XCTAssertEqual(PhaseUnwrap.degrees([42]), [42.0])
    }
}
