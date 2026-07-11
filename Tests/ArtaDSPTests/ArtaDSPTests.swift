import XCTest
@testable import ArtaDSP

final class ArtaDSPTests: XCTestCase {

    // MARK: FFT

    func testFFTRoundTrip() throws {
        let n = 1024
        let fft = try XCTUnwrap(FFT(length: n))
        var rng = SeededRNG(seed: 42)
        let original = (0..<n).map { _ in Float(rng.nextUniform()) * 2 - 1 }
        var re = original
        var im = [Float](repeating: 0, count: n)
        fft.forward(&re, &im)
        fft.inverse(&re, &im)
        for i in 0..<n {
            XCTAssertEqual(re[i], original[i], accuracy: 1e-4)
            XCTAssertEqual(im[i], 0, accuracy: 1e-4)
        }
    }

    func testFFTSineBin() throws {
        // A full-scale sine exactly on bin 32 must show up there.
        let n = 1024
        let fft = try XCTUnwrap(FFT(length: n))
        var re = (0..<n).map { Float(sin(2.0 * Double.pi * 32.0 * Double($0) / Double(n))) }
        var im = [Float](repeating: 0, count: n)
        fft.forward(&re, &im)
        let mags = (0..<n / 2).map { sqrt(re[$0] * re[$0] + im[$0] * im[$0]) }
        let peakBin = mags.enumerated().max(by: { $0.element < $1.element })!.offset
        XCTAssertEqual(peakBin, 32)
    }

    // MARK: Sweep & deconvolution

    func testLogSweepStartsAndEndsNearZero() {
        let sweep = SignalGenerator.logSweep(f1: 20, f2: 20000, duration: 1.0, sampleRate: 48000)
        XCTAssertEqual(sweep.count, 48000)
        XCTAssertEqual(sweep[0], 0, accuracy: 1e-3)
        XCTAssertEqual(sweep[sweep.count - 1], 0, accuracy: 1e-2)
        let peak = sweep.map(abs).max()!
        XCTAssertEqual(peak, 0.5, accuracy: 0.02)
    }

    func testDelayEstimation() {
        let fs = 48000.0
        let sweep = SignalGenerator.logSweep(f1: 100, f2: 10000, duration: 0.5, sampleRate: fs)
        let delaySamples = 137
        let delayed = [Float](repeating: 0, count: delaySamples) + sweep
        let (lag, corr) = Deconvolution.estimateDelay(reference: sweep, measured: delayed)
        XCTAssertEqual(lag, delaySamples)
        XCTAssertGreaterThan(corr, 0.9)
    }

    func testNegativeDelayEstimation() {
        let fs = 48000.0
        let sweep = SignalGenerator.logSweep(f1: 100, f2: 10000, duration: 0.5, sampleRate: fs)
        let advanceSamples = 64
        let advanced = Array(sweep[advanceSamples...])
        let (lag, _) = Deconvolution.estimateDelay(reference: sweep, measured: advanced)
        XCTAssertEqual(lag, -advanceSamples)
    }

    func testImpulseResponseRecoversDelayedScaledDelta() {
        let fs = 48000.0
        let sweep = SignalGenerator.logSweep(f1: 20, f2: 20000, duration: 1.0, sampleRate: fs)
        let delaySamples = 300
        let gain: Float = 0.5
        var response = [Float](repeating: 0, count: delaySamples) + sweep.map { $0 * gain }
        response += [Float](repeating: 0, count: 1000)

        let ir = Deconvolution.impulseResponse(excitation: sweep, response: response)
        XCTAssertFalse(ir.isEmpty)

        var peakIdx = 0
        var peakVal: Float = 0
        for (i, v) in ir.enumerated() where abs(v) > peakVal {
            peakVal = abs(v)
            peakIdx = i
        }
        XCTAssertEqual(peakIdx, delaySamples)
        XCTAssertEqual(peakVal, gain, accuracy: 0.1)
    }

    // MARK: H1 estimator

    func testH1FlatSystemUnityGainAndCoherence() throws {
        // y = x  ->  |H| = 1 (0 dB), coherence = 1 across the band.
        let fs = 48000.0
        let x = SignalGenerator.pinkNoise(count: 65536, seed: 7)
        let fr = try XCTUnwrap(TransferFunctionEstimator.h1(x: x, y: x, fftSize: 4096, sampleRate: fs))
        let mags = fr.magnitudeDB()
        let freqs = fr.frequencies()
        for (i, f) in freqs.enumerated() where f > 100 && f < 20000 {
            XCTAssertEqual(mags[i], 0, accuracy: 0.1, "at \(f) Hz")
            XCTAssertEqual(fr.coherence[i], 1.0, accuracy: 0.01)
        }
    }

    func testH1GainSystem() throws {
        // y = 2x -> +6.02 dB everywhere.
        let fs = 48000.0
        let x = SignalGenerator.pinkNoise(count: 65536, seed: 9)
        let y = x.map { $0 * 2 }
        let fr = try XCTUnwrap(TransferFunctionEstimator.h1(x: x, y: y, fftSize: 4096, sampleRate: fs))
        let mags = fr.magnitudeDB()
        let freqs = fr.frequencies()
        for (i, f) in freqs.enumerated() where f > 100 && f < 20000 {
            XCTAssertEqual(mags[i], 6.02, accuracy: 0.1, "at \(f) Hz")
        }
    }

    // MARK: Smoothing

    func testSmoothingPreservesFlatSpectrum() {
        let bins = 2049
        let flat = [Float](repeating: 1.0, count: bins)
        let smoothed = Smoothing.fractionalOctave(power: flat, sampleRate: 48000, fftSize: 4096, n: 3)
        for i in 1..<bins {
            XCTAssertEqual(smoothed[i], 1.0, accuracy: 1e-4)
        }
    }

    // MARK: Analysis

    func testStepResponseOfDelta() {
        var ir = [Float](repeating: 0, count: 100)
        ir[10] = 1.0
        let step = Analysis.stepResponse(ir: ir)
        XCTAssertEqual(step[5], 0, accuracy: 1e-6)
        XCTAssertEqual(step[10], 1.0, accuracy: 1e-6)
        XCTAssertEqual(step[99], 1.0, accuracy: 1e-6)
    }

    func testETCPeakAtImpulse() {
        var ir = [Float](repeating: 0, count: 4096)
        ir[100] = 1.0
        let etc = Analysis.energyTimeCurveDB(ir: ir)
        let peakIdx = etc.enumerated().max(by: { $0.element < $1.element })!.offset
        XCTAssertEqual(peakIdx, 100)
        XCTAssertEqual(etc[100], 0, accuracy: 0.1)
    }

    // MARK: Room acoustics

    func testSchroederRT60OnSyntheticDecay() {
        // Exponentially decaying noise with a known T60.
        let fs = 8000.0
        let t60Target = 0.6
        let n = Int(fs * 1.2)
        var rng = SeededRNG(seed: 123)
        var ir = [Float](repeating: 0, count: n)
        // 60 dB decay over t60 => amplitude envelope exp(-6.9078 * t / T60 / 2) on power
        // (power decays 10^(-6 t / T60); amplitude is the square root of that).
        for i in 0..<n {
            let t = Double(i) / fs
            let env = pow(10.0, -3.0 * t / t60Target)
            ir[i] = Float((rng.nextUniform() * 2 - 1) * env)
        }
        let params = RoomAcoustics.analyze(ir: ir, sampleRate: fs, truncate: false)
        let t30 = try! XCTUnwrap(params.t30)
        XCTAssertEqual(t30, t60Target, accuracy: t60Target * 0.1)
        if let r = params.rT30 {
            XCTAssertLessThan(r, -0.99, "decay should be near-perfectly linear")
        }
    }

    func testClarityAndDefinitionOnTwoSpikeIR() {
        // Equal energy before and after the 50 ms boundary: C50 = 0 dB, D50 = 50%.
        let fs = 1000.0
        var ir = [Float](repeating: 0, count: 200)
        ir[0] = 1.0    // direct sound at t=0 (also the alignment peak)
        ir[150] = 1.0  // late energy at 150 ms
        let params = RoomAcoustics.analyze(ir: ir, sampleRate: fs, truncate: false)
        XCTAssertEqual(params.c50, 0, accuracy: 0.1)
        XCTAssertEqual(params.d50, 50, accuracy: 1)
        XCTAssertEqual(params.ts, 75, accuracy: 2) // centroid midway between the spikes
    }

    // MARK: Gate windows

    func testGateWindowShape() {
        let w = GateWindow.gate(length: 100, tailFraction: 0.5)
        XCTAssertEqual(w[0], 1.0)
        XCTAssertEqual(w[49], 1.0)
        XCTAssertEqual(w[50], 1.0, accuracy: 0.01)
        XCTAssertEqual(w[99], 0.0, accuracy: 0.01)
    }
}
