import CoreAudio
import Foundation

// arta-mac Phase 0 spike: prove full-duplex Core Audio I/O + round-trip delay
// measurement (ARTA manual section 4.5, "System Delay Estimation") before any
// of the real DSP/UI work begins.

let usage = """
arta-mac-spike — Phase 0 audio I/O de-risking spike for arta-mac

USAGE:
  arta-mac-spike devices
      List Core Audio devices (ID, name, channel counts, sample rates).

  arta-mac-spike sweep [--f1 Hz] [--f2 Hz] [--duration s] [--sample-rate Hz]
                       [--write path.wav]
      Generate the exponential (log) sweep offline, print its stats, and
      optionally write it to a WAV file for inspection. No audio hardware used.

  arta-mac-spike selftest [--delay-samples N] [--noise 0..1]
      Hardware-free check of the delay-estimation DSP: delays a synthetic
      "captured" copy of the sweep by a known amount, adds noise, and checks
      that the generalized cross-correlation recovers the exact delay.

  arta-mac-spike measure [options]
      Play the sweep and record the input simultaneously on one AVAudioEngine,
      then report the round-trip delay from the generalized cross-correlation
      peak between the played and recorded signals.

      --input-device <ID>    input device (default: system default input)
      --output-device <ID>   output device (default: system default output)
      --input-channel <N>    1-based input channel to analyze (default 1)
      --output-channel <N>   1-based output channel carrying the sweep (default 1)
      --f1 <Hz>              sweep start frequency (default 20)
      --f2 <Hz>              sweep end frequency (default 20000)
      --duration <s>         sweep length in seconds (default 1.5)
      --amplitude <0..1>     playback amplitude (default 0.25)
      --no-phat              plain cross-correlation instead of GCC-PHAT
      --dump-dir <path>      write reference.wav + captured.wav for debugging

HOW TO GET A REAL ROUND-TRIP LATENCY NUMBER:
  1. Connect a physical loopback: a cable from one of your interface's outputs
     straight back into one of its inputs (e.g. output 1 -> input 1), or enable
     the interface's internal loopback / direct-monitor routing path.
  2. Turn monitor speakers DOWN (the sweep goes to the selected output).
  3. Run:  arta-mac-spike devices        (find your interface's device ID)
  4. Run:  arta-mac-spike measure --input-device <ID> --output-device <ID>
     Using the SAME device for input and output keeps everything on one device
     clock — that is the configuration that matters for ARTA-style measurement.
  Without a loopback path the tool still runs (mic picks up speaker leakage or
  just noise) but the reported delay is not meaningful; the tool warns when the
  correlation peak is too weak to trust.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

struct ArgReader {
    var args: [String]
    var index = 0
    init(_ args: [String]) { self.args = args }

    mutating func next() -> String? {
        guard index < args.count else { return nil }
        defer { index += 1 }
        return args[index]
    }

    mutating func value(for flag: String) -> String {
        guard let v = next() else { fail("\(flag) requires a value") }
        return v
    }

    mutating func doubleValue(for flag: String) -> Double {
        let raw = value(for: flag)
        guard let v = Double(raw) else { fail("\(flag): '\(raw)' is not a number") }
        return v
    }

    mutating func intValue(for flag: String) -> Int {
        let raw = value(for: flag)
        guard let v = Int(raw) else { fail("\(flag): '\(raw)' is not an integer") }
        return v
    }
}

func runSweepCommand(_ arguments: [String]) {
    var f1 = 20.0, f2 = 20_000.0, duration = 1.5, rate = 48_000.0
    var writePath: String?
    var reader = ArgReader(arguments)
    while let arg = reader.next() {
        switch arg {
        case "--f1": f1 = reader.doubleValue(for: arg)
        case "--f2": f2 = reader.doubleValue(for: arg)
        case "--duration": duration = reader.doubleValue(for: arg)
        case "--sample-rate": rate = reader.doubleValue(for: arg)
        case "--write": writePath = reader.value(for: arg)
        default: fail("unknown option for 'sweep': \(arg)")
        }
    }
    guard f1 > 0, f2 > f1 else { fail("need 0 < f1 < f2") }

    let sweep = SweepSignal.generate(
        f1: f1, f2: f2, duration: duration, sampleRate: rate,
        amplitude: 0.5, preSilence: 0.2, postSilence: 0.8)
    let peak = sweep.samples.reduce(Float(0)) { max($0, abs($1)) }
    print("Exponential sweep: \(Int(f1)) -> \(Int(f2)) Hz over \(duration) s @ \(Int(rate)) Hz")
    print("  phase(t) = 2*pi * (f1*T/ln(f2/f1)) * (e^(t/T*ln(f2/f1)) - 1)")
    print("  total signal: \(sweep.samples.count) samples (\(String(format: "%.2f", sweep.totalDuration)) s incl. 0.2 s pre / 0.8 s post silence)")
    print("  sweep occupies samples \(sweep.sweepStart)..<\(sweep.sweepStart + sweep.sweepLength), peak \(String(format: "%.3f", peak))")

    // Self-check: instantaneous frequency at a few points via zero-phase math.
    let k = duration / log(f2 / f1)
    for frac in [0.0, 0.5, 1.0] {
        let t = frac * duration
        let f = f1 * exp(t / k)
        print("  instantaneous frequency at t=\(String(format: "%.2f", t)) s: \(String(format: "%.1f", f)) Hz")
    }

    if let writePath {
        do {
            try SweepWavWriter.write(sweep, to: writePath)
            print("  wrote \(writePath)")
        } catch {
            fail("could not write WAV: \(error)")
        }
    }
}

func runSelfTestCommand(_ arguments: [String]) {
    var delaySamples = 4321
    var noise = 0.05
    var reader = ArgReader(arguments)
    while let arg = reader.next() {
        switch arg {
        case "--delay-samples": delaySamples = reader.intValue(for: arg)
        case "--noise": noise = reader.doubleValue(for: arg)
        default: fail("unknown option for 'selftest': \(arg)")
        }
    }
    guard delaySamples >= 0 else { fail("--delay-samples must be >= 0") }

    let rate = 48_000.0
    let sweep = SweepSignal.generate(
        f1: 20, f2: 20_000, duration: 1.5, sampleRate: rate,
        amplitude: 0.5, preSilence: 0.2, postSilence: 0.8)

    // Simulate a loopback: attenuated, delayed copy of the sweep plus noise.
    var captured = [Float](repeating: 0, count: delaySamples + sweep.samples.count)
    for (i, s) in sweep.samples.enumerated() {
        captured[delaySamples + i] = s * 0.3
    }
    if noise > 0 {
        var seed: UInt64 = 0x5EEDCAFE
        for i in 0..<captured.count {
            // xorshift64* — deterministic noise so the self-test is repeatable
            seed ^= seed >> 12
            seed ^= seed << 25
            seed ^= seed >> 27
            let mixed = (seed &* 0x2545F4914F6CDD1D) >> 33  // top 31 bits
            let r = Double(mixed) / Double(1 << 30) - 1.0   // [-1, 1)
            captured[i] += Float(r * noise)
        }
    }

    print("Self-test: known delay \(delaySamples) samples, noise amplitude \(noise)")
    guard let result = generalizedCrossCorrelation(
        reference: sweep.samples, captured: captured, phat: true)
    else {
        fail("correlation returned nil")
    }
    print("  GCC-PHAT peak at lag \(result.lagSamples) samples "
          + String(format: "(peak-to-noise %.1f dB, FFT size %d)", result.peakToNoiseDB, result.fftSize))
    if result.lagSamples == delaySamples {
        print("  PASS: recovered the exact sample delay.")
    } else {
        print("  FAIL: expected \(delaySamples), got \(result.lagSamples).")
        exit(1)
    }
}

func runMeasureCommand(_ arguments: [String]) {
    var options = MeasureOptions()
    var reader = ArgReader(arguments)
    while let arg = reader.next() {
        switch arg {
        case "--input-device":
            options.inputDeviceID = AudioDeviceID(reader.intValue(for: arg))
        case "--output-device":
            options.outputDeviceID = AudioDeviceID(reader.intValue(for: arg))
        case "--input-channel":
            let ch = reader.intValue(for: arg)
            guard ch >= 1 else { fail("--input-channel is 1-based") }
            options.inputChannel = ch - 1
        case "--output-channel":
            let ch = reader.intValue(for: arg)
            guard ch >= 1 else { fail("--output-channel is 1-based") }
            options.outputChannel = ch - 1
        case "--f1": options.f1 = reader.doubleValue(for: arg)
        case "--f2": options.f2 = reader.doubleValue(for: arg)
        case "--duration": options.sweepDuration = reader.doubleValue(for: arg)
        case "--amplitude": options.amplitude = reader.doubleValue(for: arg)
        case "--no-phat": options.noPhat = true
        case "--dump-dir": options.dumpDir = reader.value(for: arg)
        default: fail("unknown option for 'measure': \(arg)")
        }
    }
    guard options.f1 > 0, options.f2 > options.f1 else { fail("need 0 < f1 < f2") }
    guard options.amplitude > 0, options.amplitude <= 1 else { fail("--amplitude must be in (0, 1]") }

    print("NOTE: for a meaningful number, connect output \(options.outputChannel + 1) to input \(options.inputChannel + 1)")
    print("      with a loopback cable (or your interface's internal loopback path).")
    print("")
    do {
        try LoopbackMeasurement.run(options)
    } catch {
        fail("\(error)")
    }
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "devices":
    do {
        try DeviceCatalog.printDeviceTable()
    } catch {
        fail("\(error)")
    }
case "sweep":
    runSweepCommand(Array(arguments.dropFirst()))
case "selftest":
    runSelfTestCommand(Array(arguments.dropFirst()))
case "measure":
    runMeasureCommand(Array(arguments.dropFirst()))
case nil, "help", "--help", "-h":
    print(usage)
default:
    print(usage)
    fail("unknown command: \(arguments[0])")
}
