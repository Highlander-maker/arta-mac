import XCTest
@testable import ArtaDSP

/// The trial-delay maths, tested against results that are known in closed form.
/// This is the layer a crossover alignment gets dialled from, so "it looked right
/// on the plot" is not evidence — each property is checked independently.
final class SummationTests: XCTestCase {

    /// Flat unity spectrum on a 1 Hz grid, 0...200 Hz.
    private func flatSpectrum(bins: Int = 201)
        -> (re: [Float], im: [Float], freqs: [Double]) {
        ([Float](repeating: 1, count: bins),
         [Float](repeating: 0, count: bins),
         (0..<bins).map(Double.init))
    }

    // MARK: Delay

    func testDelayLeavesMagnitudeUntouched() {
        let (re, im, freqs) = flatSpectrum()
        let before = Summation.magnitudeDB(re: re, im: im)
        let d = Summation.delayed(hRe: re, hIm: im, frequencies: freqs, seconds: 0.0037)
        let after = Summation.magnitudeDB(re: d.re, im: d.im)
        for i in 0..<before.count {
            XCTAssertEqual(after[i], before[i], accuracy: 1e-4,
                           "a pure delay must not change magnitude (bin \(i))")
        }
    }

    func testDelayProducesLinearPhase() {
        let (re, im, freqs) = flatSpectrum()
        let tau = 0.002 // 2 ms
        let d = Summation.delayed(hRe: re, hIm: im, frequencies: freqs, seconds: tau)
        let phase = Summation.phaseDegrees(re: d.re, im: d.im, frequencies: freqs)
        // φ(f) = −360·f·τ, wrapped to ±180.
        for f in [10.0, 37.0, 90.0, 175.0] {
            let i = Int(f)
            var expected = -360.0 * f * tau
            expected = atan2(sin(expected * .pi / 180), cos(expected * .pi / 180)) * 180 / .pi
            XCTAssertEqual(Double(phase[i]), expected, accuracy: 0.01,
                           "phase at \(f) Hz should be −360·f·τ")
        }
    }

    func testRemovingTheSameDelayRestoresOriginalPhase() {
        let (re, im, freqs) = flatSpectrum()
        let tau = 0.0041
        let d = Summation.delayed(hRe: re, hIm: im, frequencies: freqs, seconds: tau)
        let restored = Summation.phaseDegrees(
            re: d.re, im: d.im, frequencies: freqs, removingDelay: tau)
        for i in 0..<restored.count {
            XCTAssertEqual(restored[i], 0, accuracy: 0.01,
                           "delay then remove-delay must round-trip to flat phase")
        }
    }

    func testNegativeDelayIsTheInverseOfPositive() {
        let (re, im, freqs) = flatSpectrum()
        let fwd = Summation.delayed(hRe: re, hIm: im, frequencies: freqs, seconds: 0.003)
        let back = Summation.delayed(hRe: fwd.re, hIm: fwd.im, frequencies: freqs, seconds: -0.003)
        for i in 0..<re.count {
            XCTAssertEqual(back.re[i], re[i], accuracy: 1e-4)
            XCTAssertEqual(back.im[i], im[i], accuracy: 1e-4)
        }
    }

    // MARK: Summation

    func testSummingIdenticalSpectraGivesSixDB() {
        let (re, im, freqs) = flatSpectrum()
        guard let s = Summation.sum(aRe: re, aIm: im, bRe: re, bIm: im) else {
            return XCTFail("sum of two matching grids should not be nil")
        }
        let db = Summation.magnitudeDB(re: s.re, im: s.im)
        for i in 0..<db.count {
            XCTAssertEqual(db[i], 6.0206, accuracy: 0.001,
                           "coherent summation of equal sources is +6 dB")
        }
        XCTAssertEqual(freqs.count, db.count)
    }

    func testHalfPeriodDelayCancelsAtThatFrequency() {
        let (re, im, freqs) = flatSpectrum()
        let f0 = 100.0
        let tau = 1.0 / (2.0 * f0) // half a period at 100 Hz → 180° out
        let d = Summation.delayed(hRe: re, hIm: im, frequencies: freqs, seconds: tau)
        guard let s = Summation.sum(aRe: re, aIm: im, bRe: d.re, bIm: d.im) else {
            return XCTFail("sum returned nil")
        }
        let db = Summation.magnitudeDB(re: s.re, im: s.im)
        XCTAssertLessThan(db[Int(f0)], -60,
                          "a half-period offset must cancel at the crossover frequency")
        // A full period out at the same delay comes back in phase.
        XCTAssertEqual(db[Int(2 * f0)], 6.0206, accuracy: 0.01,
                       "one whole period later the same delay sums coherently again")
    }

    func testCombFrequenciesLandWhereTheoryPutsThem() {
        // With offset τ, nulls sit at f = (2k+1)/(2τ) — the spacing that decides
        // whether an alignment error sounds hollow or merely coloured.
        let (re, im, freqs) = flatSpectrum(bins: 2001)
        let tau = 0.005 // 5 ms → nulls every 200 Hz, first at 100 Hz
        let d = Summation.delayed(hRe: re, hIm: im, frequencies: freqs, seconds: tau)
        guard let s = Summation.sum(aRe: re, aIm: im, bRe: d.re, bIm: d.im) else {
            return XCTFail("sum returned nil")
        }
        let db = Summation.magnitudeDB(re: s.re, im: s.im)
        for k in 0..<5 {
            let null = Double(2 * k + 1) / (2 * tau)
            XCTAssertLessThan(db[Int(null)], -60, "expected a null at \(null) Hz")
            let peak = Double(k + 1) / tau
            XCTAssertEqual(db[Int(peak)], 6.0206, accuracy: 0.01,
                           "expected full summation at \(peak) Hz")
        }
    }

    func testMismatchedGridsRefuseRatherThanSumTheOverlap() {
        let a = flatSpectrum(bins: 201)
        let b = flatSpectrum(bins: 129)
        XCTAssertNil(Summation.sum(aRe: a.re, aIm: a.im, bRe: b.re, bIm: b.im),
                     "responses on different grids are not comparable")
    }

    func testEmptyInputIsHandled() {
        XCTAssertNil(Summation.sum(aRe: [], aIm: [], bRe: [], bIm: []))
        let d = Summation.delayed(hRe: [], hIm: [], frequencies: [], seconds: 0.01)
        XCTAssertTrue(d.re.isEmpty)
    }

    /// The re-referencing scheme `AppModel.recomputeFrequencyResponse` relies on.
    ///
    /// A gated response's t=0 is the gate start. To sum two of them the app shifts
    /// each to impulse-response sample 0 and stores the absolute arrival separately.
    /// That is only safe if removing the absolute arrival reproduces the phase the
    /// gated form displayed — i.e. shifting the time origin changed nothing the
    /// operator can see. If this identity ever breaks, every phase trace moves.
    func testReReferencingToSampleZeroPreservesDisplayedPhase() {
        let bins = 129
        let fftSize = 256
        let sampleRate = 48_000.0
        let freqs = (0..<bins).map { Double($0) * sampleRate / Double(fftSize) }

        // An arbitrary, non-trivial spectrum — not flat, so a bug can't hide.
        var re = [Float](repeating: 0, count: bins)
        var im = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            re[i] = Float(cos(Double(i) * 0.37) * (1.0 + Double(i) / 60.0))
            im[i] = Float(sin(Double(i) * 0.11) * 0.8 - 0.2)
        }

        let gateStartSamples = 613
        let peakSamples = 900
        let tGate = Double(gateStartSamples) / sampleRate
        let preDelay = Double(peakSamples - gateStartSamples) / sampleRate
        let arrival = Double(peakSamples) / sampleRate

        // What the gated form displays today.
        let gated = FrequencyResponse(
            fftSize: fftSize, sampleRate: sampleRate, hRe: re, hIm: im,
            coherence: [Float](repeating: 1, count: bins), averages: 1)
        let displayed = gated.phaseDegrees(removingDelay: preDelay)

        // What the stored absolute spectrum yields once its arrival is removed.
        let absolute = Summation.delayed(hRe: re, hIm: im, frequencies: freqs, seconds: tGate)
        let viaAbsolute = Summation.phaseDegrees(
            re: absolute.re, im: absolute.im, frequencies: freqs, removingDelay: arrival)

        for i in 0..<bins {
            // Compare on the circle: ±180 are the same angle, and either form may
            // land on a different side of the wrap.
            let a = Double(displayed[i]) * .pi / 180
            let b = Double(viaAbsolute[i]) * .pi / 180
            let separation = abs(atan2(sin(a - b), cos(a - b))) * 180 / .pi
            XCTAssertLessThan(separation, 0.02,
                              "bin \(i): re-referencing must not move the displayed phase")
        }
    }

    // MARK: The property the whole feature rests on

    func testDelayingOneSourceMovesTheNullNotTheLevel() {
        // Two sources 2 ms apart: sliding the trial delay to +2 ms must recover
        // flat +6 dB summation. This is the workflow in one assertion.
        let (re, im, freqs) = flatSpectrum(bins: 501)
        let offset = 0.002
        let late = Summation.delayed(hRe: re, hIm: im, frequencies: freqs, seconds: offset)

        guard let misaligned = Summation.sum(aRe: re, aIm: im, bRe: late.re, bIm: late.im) else {
            return XCTFail("sum returned nil")
        }
        let misDB = Summation.magnitudeDB(re: misaligned.re, im: misaligned.im)
        XCTAssertLessThan(misDB[250], -60, "250 Hz should be nulled by a 2 ms offset")

        let corrected = Summation.delayed(
            hRe: re, hIm: im, frequencies: freqs, seconds: offset)
        guard let aligned = Summation.sum(
            aRe: late.re, aIm: late.im, bRe: corrected.re, bIm: corrected.im) else {
            return XCTFail("sum returned nil")
        }
        let alignedDB = Summation.magnitudeDB(re: aligned.re, im: aligned.im)
        for i in 1..<alignedDB.count {
            XCTAssertEqual(alignedDB[i], 6.0206, accuracy: 0.01,
                           "matched delays sum flat at +6 dB (bin \(i))")
        }
    }
}
