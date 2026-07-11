import XCTest
@testable import ArtaDSP

final class Layer2Tests: XCTestCase {

    // MARK: Band filters

    func testOctaveBandpassPassesCenterRejectsNeighbors() {
        let fs = 48000.0
        let n = 16384
        let at1k = SignalGenerator.sine(frequency: 1000, duration: Double(n) / fs, sampleRate: fs, amplitude: 1.0)
        let at4k = SignalGenerator.sine(frequency: 4000, duration: Double(n) / fs, sampleRate: fs, amplitude: 1.0)

        func rms(_ x: [Float]) -> Float {
            sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
        }

        let passRMS = rms(BandFilters.bandpass(signal: at1k, center: 1000, fraction: 1, sampleRate: fs))
        let rejectRMS = rms(BandFilters.bandpass(signal: at4k, center: 1000, fraction: 1, sampleRate: fs))

        XCTAssertEqual(passRMS, rms(at1k), accuracy: rms(at1k) * 0.05, "on-center tone should pass at ~unity")
        let attenuationDB = 20 * log10(rejectRMS / passRMS)
        XCTAssertLessThan(attenuationDB, -25, "tone two octaves out should be strongly attenuated")
    }

    // MARK: Weighting curves

    func testAWeightingReferencePoints() {
        // IEC 61672 table values.
        XCTAssertEqual(BandFilters.weightingGainDB(frequency: 1000, .a), 0, accuracy: 0.05)
        XCTAssertEqual(BandFilters.weightingGainDB(frequency: 100, .a), -19.1, accuracy: 0.3)
        XCTAssertEqual(BandFilters.weightingGainDB(frequency: 10000, .a), -2.5, accuracy: 0.3)
        XCTAssertEqual(BandFilters.weightingGainDB(frequency: 1000, .c), 0, accuracy: 0.05)
        XCTAssertEqual(BandFilters.weightingGainDB(frequency: 31.5, .c), -3.0, accuracy: 0.3)
        XCTAssertEqual(BandFilters.weightingGainDB(frequency: 5000, .z), 0)
    }

    // MARK: STI

    func testSTIPerfectChannelIsExcellent() {
        let fs = 16000.0
        var ir = [Float](repeating: 0, count: Int(fs)) // 1 s
        ir[100] = 1.0
        let result = STI.compute(ir: ir, sampleRate: fs)
        XCTAssertGreaterThan(result.sti, 0.95, "a delta IR is a perfect speech channel")
        XCTAssertEqual(result.rating, "EXCELLENT")
        XCTAssertLessThan(result.alcons, 1.0)
    }

    func testSTIDegradesWithReverb() {
        let fs = 16000.0
        let t60 = 2.0
        let n = Int(fs * 2.5)
        var rng = SeededRNG(seed: 77)
        var ir = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            ir[i] = Float((rng.nextUniform() * 2 - 1) * pow(10.0, -3.0 * t / t60))
        }
        let reverberant = STI.compute(ir: ir, sampleRate: fs)
        XCTAssertLessThan(reverberant.sti, 0.75, "2 s of reverb must pull STI well below excellent")
        XCTAssertGreaterThan(reverberant.sti, 0.2)
    }

    // MARK: PIR round-trip

    func testPIRRoundTrip() throws {
        var pir = PIRFile(sampleRate: 48000, samples: (0..<1000).map { Float($0) / 1000 })
        pir.infoText = "ArtaDSP round-trip test"
        pir.cursorPosition = 300
        pir.markerPosition = 512
        pir.inputDevice = 1
        pir.deviceSensitivity = 0.011

        let decoded = try PIRFile.decode(pir.encode())
        XCTAssertEqual(decoded.sampleRate, 48000)
        XCTAssertEqual(decoded.samples.count, 1000)
        XCTAssertEqual(decoded.samples[500], pir.samples[500])
        XCTAssertEqual(decoded.infoText, "ArtaDSP round-trip test")
        XCTAssertEqual(decoded.cursorPosition, 300)
        XCTAssertEqual(decoded.markerPosition, 512)
        XCTAssertEqual(decoded.inputDevice, 1)
        XCTAssertEqual(decoded.deviceSensitivity, 0.011, accuracy: 1e-6)
    }

    func testPIRRejectsGarbage() {
        XCTAssertThrowsError(try PIRFile.decode(Data([0x00, 0x01, 0x02])))
    }

    // MARK: FRD round-trip

    func testFRDRoundTrip() {
        let freqs = [20.0, 100.0, 1000.0, 20000.0]
        let mags: [Float] = [-3.0, 0.0, 0.5, -6.0]
        let phases: [Float] = [45, 0, -10, -170]
        let text = FRDFile.export(frequencies: freqs, magnitudesDB: mags, phasesDegrees: phases)
        let parsed = FRDFile.parse(text)
        XCTAssertEqual(parsed.frequencies.count, 4)
        XCTAssertEqual(parsed.frequencies[2], 1000.0, accuracy: 0.01)
        XCTAssertEqual(parsed.magnitudesDB[3], -6.0, accuracy: 0.01)
        XCTAssertEqual(parsed.phasesDegrees[0], 45, accuracy: 0.01)
    }

    // MARK: Per-band room acoustics

    func testPerBandRT60OnSyntheticDecay() {
        // Broadband decaying noise: every octave band should report roughly the same T60.
        let fs = 16000.0
        let t60 = 0.5
        let n = Int(fs * 1.0)
        var rng = SeededRNG(seed: 55)
        var ir = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            ir[i] = Float((rng.nextUniform() * 2 - 1) * pow(10.0, -3.0 * t / t60))
        }
        let bands = RoomAcoustics.analyzeOctaveBands(
            ir: ir, sampleRate: fs, centers: [250, 500, 1000, 2000], truncate: false
        )
        XCTAssertEqual(bands.count, 4)
        for (center, params) in bands {
            let t30 = params.t30
            XCTAssertNotNil(t30, "band \(center) should yield a T30")
            if let t = t30 {
                XCTAssertEqual(t, t60, accuracy: t60 * 0.25, "band \(center)")
            }
        }
    }
}
