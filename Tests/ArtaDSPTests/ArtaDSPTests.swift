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

    /// Dual-channel loop reference: the excitation is a *captured* signal that is
    /// NOT a clean generated sweep (here pink noise, standing in for the real
    /// electrical loop off an interface output). Deconvolving the mic-side
    /// measurement against that captured reference must still recover the true
    /// system delay and gain — this is the whole point of the SMAART-style loop:
    /// whatever actually came out of the converters is the reference, so the
    /// converter path divides out and only the acoustic time-of-flight remains.
    func testLoopReferenceRecoversDelayFromNonSweepExcitation() {
        let captured = SignalGenerator.pinkNoise(count: 48000, seed: 21)
        let delaySamples = 512
        let gain: Float = 0.35
        // Measurement = the same captured drive, delayed (speed of sound) + scaled.
        var measured = [Float](repeating: 0, count: delaySamples) + captured.map { $0 * gain }
        measured += [Float](repeating: 0, count: 2000)

        let (lag, corr) = Deconvolution.estimateDelay(reference: captured, measured: measured)
        XCTAssertEqual(lag, delaySamples, "loop delay estimate")
        XCTAssertGreaterThan(corr, 0.9, "loop reference correlation")

        let ir = Deconvolution.impulseResponse(excitation: captured, response: measured)
        var peakIdx = 0
        var peakVal: Float = 0
        for (i, v) in ir.enumerated() where abs(v) > peakVal {
            peakVal = abs(v)
            peakIdx = i
        }
        XCTAssertEqual(peakIdx, delaySamples, "loop IR peak position")
        XCTAssertEqual(peakVal, gain, accuracy: 0.05, "loop IR peak amplitude")
    }

    /// Regression: a log sweep in a reverberant room. The direct sound is a sharp,
    /// high-amplitude spike; the room's late energy is diffuse and low-frequency but
    /// carries far more total energy. Raw cross-correlation inherits the log sweep's
    /// pink weighting and can be dragged onto that late bass; the whitened
    /// deconvolution must still put its peak on the direct arrival.
    ///
    /// Field case (21 Jul 2026): d&b E8 at 7.7 m, correlation −18 dB. The delay chip
    /// read 38.19 ms; the IR peak read 22.27 ms = 7.64 m, matching a tape to 6 cm.
    func testDelayFromIRPeakSurvivesLateLowFrequencyRoomEnergy() {
        let fs = 48000.0
        let sweep = SignalGenerator.logSweep(
            f1: 20, f2: 20000, duration: 0.5, sampleRate: fs, amplitude: 0.9)
        let direct = 1200                       // direct sound arrival, samples
        let lateStart = direct + 700            // diffuse room energy behind it
        let blob = 400                          // ~240 Hz and below at 48 kHz

        // h = sharp direct delta + a long, low-frequency, lower-amplitude tail that
        // nonetheless dominates the total energy.
        var h = [Float](repeating: 0, count: lateStart + blob + 200)
        h[direct] = 1.0
        for i in 0..<blob {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(blob - 1))
            h[lateStart + i] = Float(0.5 * hann)
        }

        var response = [Float](repeating: 0, count: sweep.count + h.count)
        for (j, hv) in h.enumerated() where hv != 0 {
            for (i, sv) in sweep.enumerated() { response[i + j] += sv * hv }
        }

        let directEnergy: Float = 1.0
        let lateEnergy = h[lateStart..<(lateStart + blob)].reduce(0) { $0 + $1 * $1 }
        XCTAssertGreaterThan(lateEnergy, directEnergy * 10,
                             "test case must have room energy dominating the direct sound")

        let ir = Deconvolution.impulseResponse(excitation: sweep, response: response)
        XCTAssertEqual(Deconvolution.peakIndex(of: ir), direct, accuracy: 2,
                       "IR peak must sit on the direct arrival, not the late room energy")
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

    // MARK: Shaped tone burst

    func testShapedToneBurstLengthAndTaper() {
        let fs = 48000.0
        let f0 = 1000.0
        let cycles = 5
        let burst = SignalGenerator.shapedToneBurst(frequency: f0, cycles: cycles, sampleRate: fs, amplitude: 0.5)
        // Length is cycles / f0 seconds.
        XCTAssertEqual(burst.count, Int((Double(cycles) / f0 * fs).rounded()))
        // Raised-cosine envelope tapers to (near) zero at both ends...
        XCTAssertEqual(burst.first!, 0, accuracy: 1e-3)
        XCTAssertEqual(burst.last!, 0, accuracy: 1e-2)
        // ...and reaches full amplitude near the centre.
        let peak = burst.map(abs).max()!
        XCTAssertEqual(peak, 0.5, accuracy: 0.03)
    }

    func testShapedToneBurstEnvelopeIsRaisedCosine() {
        let fs = 48000.0
        let burst = SignalGenerator.shapedToneBurst(frequency: 1000, cycles: 8, sampleRate: fs, amplitude: 1.0)
        let env = Analysis.analyticEnvelope(burst)
        // The envelope peaks in the middle and is symmetric (raised cosine).
        let mid = env.count / 2
        let peakIdx = env.enumerated().max(by: { $0.element < $1.element })!.offset
        XCTAssertEqual(Double(peakIdx), Double(mid), accuracy: Double(env.count) * 0.1)
        XCTAssertEqual(env[mid], 1.0, accuracy: 0.05)
        XCTAssertLessThan(env[env.count / 8], env[mid])
    }

    func testAnalyticEnvelopeLocatesBurstCentre() {
        // The burst-measurement arrival detector relies on this: the analytic
        // envelope of a delayed shaped burst peaks at the burst's centre, even at
        // low frequency and with noise — unlike a cross-correlation, which smears.
        let fs = 48000.0
        let f0 = 50.0, cycles = 5
        let burst = SignalGenerator.shapedToneBurst(frequency: f0, cycles: cycles, sampleRate: fs, amplitude: 0.8)
        let delay = 4321
        var signal = [Float](repeating: 0, count: delay) + burst + [Float](repeating: 0, count: 4000)
        var rng = SeededRNG(seed: 7)
        for i in 0..<signal.count { signal[i] += Float(rng.nextUniform() * 2 - 1) * 0.02 }
        let env = Analysis.analyticEnvelope(signal)
        let peakIdx = env.enumerated().max(by: { $0.element < $1.element })!.offset
        // Envelope peaks at delay + burstLength/2, within ~3 ms.
        XCTAssertEqual(Double(peakIdx), Double(delay + burst.count / 2), accuracy: fs * 0.003)
    }

    func testAnalyticEnvelopeOfSineIsFlat() {
        let fs = 48000.0
        // A steady sine's envelope is its amplitude; sample the stable middle
        // (the FFT-based Hilbert has edge transients at the very ends).
        let sine = SignalGenerator.sine(frequency: 1000, duration: 0.1, sampleRate: fs, amplitude: 0.7)
        let env = Analysis.analyticEnvelope(sine)
        for i in stride(from: env.count / 4, to: env.count * 3 / 4, by: 50) {
            XCTAssertEqual(env[i], 0.7, accuracy: 0.03, "envelope at \(i)")
        }
    }

    func testGaussianBurstTapersToZeroAndPeaksAtCentre() {
        let fs = 48000.0
        let burst = SignalGenerator.shapedToneBurst(
            frequency: 1000, cycles: 5, sampleRate: fs, amplitude: 0.5, envelope: .gaussian)
        // Truncating a Gaussian leaves a step unless the pedestal is subtracted;
        // that step would splatter the spectrum the taper exists to contain. The
        // samples span t = 0 ..< T rather than 0...T, so the last one sits just
        // inside the window and is small rather than exactly zero — same reason
        // testShapedToneBurstLengthAndTaper uses a loose bound on its own last sample.
        XCTAssertEqual(burst.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(burst.last!, 0, accuracy: 1e-3)
        // Still reaches full amplitude at the centre, so the peak-level meaning of
        // the readout is unchanged between envelopes.
        XCTAssertEqual(burst.map(abs).max()!, 0.5, accuracy: 0.03)
        // Carrier phase makes single end samples a weak check (the sine is near a
        // zero crossing at both ends for integer cycles). Compare mean level in the
        // outer tenth against the middle tenth instead: that fails for any envelope
        // that does not actually taper, whatever the carrier is doing.
        func meanLevel(_ range: Range<Int>) -> Double {
            burst[range].reduce(0.0) { $0 + Double(abs($1)) } / Double(range.count)
        }
        let edge = meanLevel(0..<(burst.count / 10))
        let middle = meanLevel((burst.count * 45 / 100)..<(burst.count * 55 / 100))
        XCTAssertLessThan(edge * 10, middle)
    }

    func testGaussianBurstIsMoreConcentratedThanRaisedCosine() {
        // The reason to offer Gaussian at all: minimum time-bandwidth product means
        // energy packs more tightly around the centre, giving a sharper thing to
        // align to. Compare the fraction of total energy inside the middle third.
        let fs = 48000.0
        func centreEnergyFraction(_ envelope: SignalGenerator.BurstEnvelope) -> Double {
            let b = SignalGenerator.shapedToneBurst(
                frequency: 1000, cycles: 5, sampleRate: fs, amplitude: 0.5, envelope: envelope)
            let total = b.reduce(0.0) { $0 + Double($1 * $1) }
            let lo = b.count / 3, hi = b.count * 2 / 3
            let centre = b[lo..<hi].reduce(0.0) { $0 + Double($1 * $1) }
            return centre / total
        }
        XCTAssertGreaterThan(centreEnergyFraction(.gaussian),
                             centreEnergyFraction(.raisedCosine))
    }

    // MARK: Burst arrival location

    /// Build a synthetic capture: silence, a shaped burst starting at
    /// `arrivalSample`, then silence — plus low-level noise throughout.
    private func syntheticBurstCapture(
        arrivalSample: Int, frequency: Double, cycles: Int, sampleRate: Double,
        totalSamples: Int, noise: Float = 0.02, seed: UInt64 = 7,
        envelope: SignalGenerator.BurstEnvelope = .raisedCosine
    ) -> (capture: [Float], burstLength: Int) {
        let burst = SignalGenerator.shapedToneBurst(
            frequency: frequency, cycles: cycles, sampleRate: sampleRate, amplitude: 0.8,
            envelope: envelope)
        var capture = [Float](repeating: 0, count: totalSamples)
        for (i, v) in burst.enumerated() where arrivalSample + i < totalSamples {
            capture[arrivalSample + i] = v
        }
        var rng = SeededRNG(seed: seed)
        for i in 0..<capture.count { capture[i] += Float(rng.nextUniform() * 2 - 1) * noise }
        return (capture, burst.count)
    }

    func testBurstArrivalIndexFindsOnsetNotEnvelopePeak() {
        // The detector must report the burst's ONSET, not the envelope peak that
        // locates it — the peak sits half a burst-length later (raised cosine
        // peaks at T/2), and reporting it would put every arrival late by that
        // much: 31 ms at 80 Hz / 5 cycles, which would be a large delay error.
        let fs = 48000.0, f0 = 80.0, cycles = 5
        let scheduled = 10_000
        let trueArrival = scheduled + 480          // 10 ms of acoustic flight
        let (capture, burstLen) = syntheticBurstCapture(
            arrivalSample: trueArrival, frequency: f0, cycles: cycles,
            sampleRate: fs, totalSamples: 40_000)
        let found = Analysis.burstArrivalIndex(
            in: capture, scheduledOnsetSample: scheduled,
            burstLengthSamples: burstLen, sampleRate: fs, frequency: f0)
        XCTAssertNotNil(found)
        XCTAssertEqual(Double(found!), Double(trueArrival), accuracy: fs * 0.003)
        // Guard the specific failure above: the envelope peak is a full
        // burstLen/2 (1500 samples) later, well outside the tolerance.
        XCTAssertLessThan(Double(found!), Double(trueArrival + burstLen / 2) - fs * 0.003)
    }

    func testBurstArrivalIndexWorksWithGaussianEnvelope() {
        // The onset correction subtracts half a burst-length, which assumes the
        // envelope peaks at T/2. True for the Gaussian as well as the raised
        // cosine — both are symmetric — so alignment must work with either.
        let fs = 48000.0, f0 = 80.0, cycles = 5
        let scheduled = 10_000
        let trueArrival = scheduled + 480
        let (capture, burstLen) = syntheticBurstCapture(
            arrivalSample: trueArrival, frequency: f0, cycles: cycles,
            sampleRate: fs, totalSamples: 40_000, envelope: .gaussian)
        let found = Analysis.burstArrivalIndex(
            in: capture, scheduledOnsetSample: scheduled,
            burstLengthSamples: burstLen, sampleRate: fs, frequency: f0)
        XCTAssertNotNil(found)
        XCTAssertEqual(Double(found!), Double(trueArrival), accuracy: fs * 0.003)
    }

    func testBurstDeltaCancelsDifferentSchedulingAnchors() {
        // The whole basis of the Freeze/Δ feature: two captures taken minutes
        // apart have completely different scheduling anchors (mach_absolute_time
        // differs every run), but the fixed converter/buffer latency is identical,
        // so arrival-relative-to-schedule differences out to pure acoustic flight.
        // Main at 10 ms, sub at 13 ms, from anchors 15 000 samples apart → Δ 3 ms.
        let fs = 48000.0, f0 = 80.0, cycles = 5
        let mainScheduled = 10_000, subScheduled = 25_000
        let mainFlight = Int(0.010 * fs), subFlight = Int(0.013 * fs)

        let (mainCapture, burstLen) = syntheticBurstCapture(
            arrivalSample: mainScheduled + mainFlight, frequency: f0, cycles: cycles,
            sampleRate: fs, totalSamples: 60_000, seed: 7)
        let (subCapture, _) = syntheticBurstCapture(
            arrivalSample: subScheduled + subFlight, frequency: f0, cycles: cycles,
            sampleRate: fs, totalSamples: 60_000, seed: 11)

        guard let mainArrival = Analysis.burstArrivalIndex(
                in: mainCapture, scheduledOnsetSample: mainScheduled,
                burstLengthSamples: burstLen, sampleRate: fs, frequency: f0),
              let subArrival = Analysis.burstArrivalIndex(
                in: subCapture, scheduledOnsetSample: subScheduled,
                burstLengthSamples: burstLen, sampleRate: fs, frequency: f0)
        else { return XCTFail("burst arrival not located") }

        let deltaMs = Analysis.burstArrivalDeltaSeconds(
            referenceOffsetSamples: mainArrival - mainScheduled, referenceSampleRate: fs,
            currentOffsetSamples: subArrival - subScheduled, currentSampleRate: fs) * 1000
        XCTAssertEqual(deltaMs, 3.0, accuracy: 0.5)
        // Sign convention: the later-arriving source reads positive.
        XCTAssertGreaterThan(deltaMs, 0)
    }

    func testBurstArrivalIndexRefusesShortCapture() {
        // A stalled input device can exit the capture wait on its deadline with
        // less audio than the search window needs. The old inline version indexed
        // past the end of the buffer here (a crash); it must refuse instead.
        let fs = 48000.0
        let short = [Float](repeating: 0.1, count: 1000)
        XCTAssertNil(Analysis.burstArrivalIndex(
            in: short, scheduledOnsetSample: 34_000,
            burstLengthSamples: 3000, sampleRate: fs, frequency: 80))
    }

    func testBurstArrivalIndexRefusesSilentCapture() {
        // Nothing arrived — no output routed, muted amp, dead cable. Reporting an
        // arrival here would hand back a confident delay figure from a capture
        // that contains no burst at all.
        let fs = 48000.0
        let silence = [Float](repeating: 0, count: 40_000)
        XCTAssertNil(Analysis.burstArrivalIndex(
            in: silence, scheduledOnsetSample: 10_000,
            burstLengthSamples: 3000, sampleRate: fs, frequency: 80))
    }

    // MARK: Burst arrival delta

    func testBurstArrivalDeltaMatchesKnownOffset() {
        // Reference ("main") burst captured at 48 kHz, its envelope peak landed
        // 500 samples after the deterministic schedule instant. A "sub" burst on
        // the same device/routing (same fixed I/O latency) but with a 3 ms longer
        // acoustic path lands 0.003 * 48000 = 144 samples later, at offset 644.
        let deltaSeconds = Analysis.burstArrivalDeltaSeconds(
            referenceOffsetSamples: 500, referenceSampleRate: 48000,
            currentOffsetSamples: 644, currentSampleRate: 48000)
        XCTAssertEqual(deltaSeconds * 1000, 3.0, accuracy: 0.01)
    }

    func testBurstArrivalDeltaHandlesDifferentSampleRates() {
        // Same underlying physical offsets (10 ms reference, 13 ms current) but
        // expressed as sample counts at two DIFFERENT capture rates. The function
        // must convert each side to seconds independently before subtracting —
        // diffing raw sample counts here would silently give the wrong answer.
        let refOffset = Int(0.010 * 44_100)   // 10 ms @ 44.1 kHz
        let curOffset = Int(0.013 * 48_000)   // 13 ms @ 48 kHz
        let deltaSeconds = Analysis.burstArrivalDeltaSeconds(
            referenceOffsetSamples: refOffset, referenceSampleRate: 44_100,
            currentOffsetSamples: curOffset, currentSampleRate: 48_000)
        XCTAssertEqual(deltaSeconds * 1000, 3.0, accuracy: 0.05)
    }

    func testDistanceMetersMatchesSpeedOfSound() {
        // Newly testable now that the ms→m conversion is extracted — previously
        // this logic only existed duplicated inline inside two SwiftUI views.
        XCTAssertEqual(Acoustics.distanceMeters(forDeltaMs: 1.0), 0.343, accuracy: 0.001)
        XCTAssertEqual(Acoustics.distanceMeters(forDeltaMs: -2.0), -0.686, accuracy: 0.001)
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
