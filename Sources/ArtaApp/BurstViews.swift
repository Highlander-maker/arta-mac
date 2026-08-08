import SwiftUI
import ArtaDSP

/// Shaped tone-burst panel (Linkwitz, JAES 1980). Fires N windowed cycles at one
/// frequency and shows the captured envelope against the ideal burst envelope —
/// the peak reads the response at f0, the shape reveals resonant ring-out.
struct BurstPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var dbScale = true

    /// The sub/top crossover region plus reference tones — the frequencies you
    /// most want to interrogate for driver/cabinet resonances.
    private let quickFrequencies: [Double] = [40, 63, 80, 100, 125, 250, 1000, 4000]

    var body: some View {
        VStack(spacing: 0) {
            controls
            if model.burstLevelChecking {
                BurstLevelStrip(meter: model.meter, inputChannel: model.inputChannel)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            BurstPlotView(result: model.burstResult, dbScale: dbScale)
                .padding([.leading, .trailing, .bottom], 8)
            readouts
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            LabeledContent("Freq") {
                HStack(spacing: 4) {
                    TextField("", value: $model.burstFrequency, format: .number.grouping(.never))
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            if model.burstLevelChecking { model.restartBurstLevelCheckIfRunning() }
                            else if !model.isBursting { model.runBurst() }
                        }
                    Text("Hz").foregroundColor(.secondary)
                }
            }
            .fixedSize()

            Stepper("Cycles: \(model.burstCycles)", value: $model.burstCycles, in: 2...20)
                .fixedSize()
                .onChange(of: model.burstCycles) { _ in model.restartBurstLevelCheckIfRunning() }
                .help("5 is Linkwitz's figure and Digby's choice — enough ramp to show the shape, short enough to keep the envelope peak sharp. Pat Brown's published library uses 6.5, which is what makes it ⅓-octave wide.")

            Picker("", selection: $model.burstEnvelope) {
                Text("Raised cos").tag(SignalGenerator.BurstEnvelope.raisedCosine)
                Text("Gaussian").tag(SignalGenerator.BurstEnvelope.gaussian)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: model.burstEnvelope) { _ in model.restartBurstLevelCheckIfRunning() }
            .help("Envelope shape. Gaussian minimises the time–bandwidth product, giving the sharpest centre to align to — the envelope Digby specifies for wavelet alignment.")

            // Quick-pick chips for the usual resonance-hunting frequencies.
            HStack(spacing: 3) {
                ForEach(quickFrequencies, id: \.self) { f in
                    Button {
                        model.burstFrequency = f
                        model.runBurst()
                    } label: {
                        Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .frame(width: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(model.burstFrequency == f ? .accentColor : nil)
                    .disabled(model.isBursting)
                }
            }

            Spacer()

            Toggle("dB envelope", isOn: $dbScale)
                .toggleStyle(.checkbox)

            Button {
                model.toggleBurstLevelCheck()
            } label: {
                Label(model.burstLevelChecking ? "Stop tone" : "Check level",
                      systemImage: model.burstLevelChecking ? "stop.fill" : "gauge.with.dots.needle.bottom.50percent")
            }
            .tint(model.burstLevelChecking ? .red : nil)
            .disabled(model.isBursting || model.isMeasuring)
            .help("Fire a repeating burst at the measurement frequency and level so the meter previews the real transient peak (no low-frequency room-mode over-read)")

            Button {
                model.runBurst()
            } label: {
                Label(model.isBursting ? "Bursting..." : "Burst",
                      systemImage: "waveform.path")
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(model.isBursting || model.isMeasuring)

            Divider().frame(height: 16)

            if model.frozenBurst == nil {
                Button("Freeze") { model.freezeBurst() }
                    .help("Snapshot this burst as an arrival-time reference — fire through the main, freeze, then fire through the sub and read Δ")
                    .disabled(model.burstResult == nil || model.isBursting)
            } else {
                Button("Clear ref") { model.clearFrozenBurst() }
                    .help("Remove the frozen reference burst")
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var readouts: some View {
        if let r = model.burstResult {
            let burstMs = Double(r.burstLengthSamples) / r.sampleRate * 1000
            HStack(spacing: 14) {
                readout("f0", r.frequency >= 1000
                        ? String(format: "%.2f kHz", r.frequency / 1000)
                        : String(format: "%.0f Hz", r.frequency))
                readout("cycles", "\(r.cycles)")
                readout("burst", String(format: "%.1f ms", burstMs))
                readout("peak", String(format: "%.1f dBFS", r.capturedPeakDBFS),
                        warn: r.capturedPeakDBFS < -60 || r.capturedPeakDBFS > -3)
                if let ring = ringOutDB(r) {
                    // The higher (closer to 0 dB) this is, the more the driver is
                    // still ringing a full burst-length after the drive stopped.
                    readout("ring-out", String(format: "%.0f dB", ring), warn: ring > -12)
                }
                if let ref = r.timingReference {
                    // Which zero the arrival was measured from. "loop ref" is the
                    // accurate one (cancels converter latency); "schedule" means
                    // no loop was available and the host-time anchor was used.
                    readout("zero", ref.label, warn: ref == .playbackSchedule)
                }
                if let d = model.burstDeltaMs {
                    // Signed ms carries the direction; metres unsigned, matching the
                    // IR tab's Δ readout (a negative distance reads oddly).
                    readout("Δ", String(format: "%.2f ms · %.2f m",
                                         d, abs(Acoustics.distanceMeters(forDeltaMs: d))),
                            warn: model.burstFrequencyMismatch)
                } else if model.burstTimingReferenceMismatch {
                    readout("Δ", "timing reference changed — re-freeze", warn: true)
                } else if model.frozenBurst != nil {
                    // freezeBurst() refuses a reference without arrival data, so the
                    // gap is always on this side — a burst loaded from a .tbr saved
                    // before arrivalOffsetSamples existed. Re-firing fixes it.
                    readout("Δ", "this burst has no arrival data — re-fire", warn: true)
                }
                Spacer()
                if model.burstTimingReferenceMismatch {
                    Text("Reference burst was zeroed on a different source — Δ would be out by the interface's round trip")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                } else if model.burstFrequencyMismatch, let ref = model.frozenBurst {
                    Text(String(format: "ref frozen at %.0f Hz, live at %.0f Hz — Δ not meaningful across frequencies",
                                ref.frequency, r.frequency))
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                } else {
                    Text("Amber = measured envelope · cyan dashed = ideal burst")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    /// Envelope level one burst-length after the burst ends, relative to its peak.
    private func ringOutDB(_ r: BurstResult) -> Double? {
        let env = r.responseEnvelope
        let peak = max(Double(r.responseEnvelopePeak), 1e-9)
        let idx = r.arrivalSample + 2 * r.burstLengthSamples
        guard idx < env.count else { return nil }
        return 20 * log10(max(Double(env[idx]), 1e-9) / peak)
    }

    private func readout(_ title: String, _ value: String, warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(warn ? .orange : .primary)
        }
    }
}

// MARK: - Live level-check strip

/// Live mic peak-hold for the measurement channel while a level-check tone plays,
/// with a burst-oriented verdict. Its own view (observing the meter directly) so
/// the ~23 Hz level updates don't re-render the burst plot.
struct BurstLevelStrip: View {
    @ObservedObject var meter: InputMeter
    let inputChannel: Int

    private let floorDB: Float = -60
    private let ceilingDB: Float = 0

    var body: some View {
        let hold = inputChannel < meter.holdDB.count ? meter.holdDB[inputChannel]
            : (meter.holdDB.first ?? floorDB)
        let verdict = AppModel.levelVerdict(dBFS: hold)
        return HStack(spacing: 10) {
            Text("MIC In \(inputChannel + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                    // Target band −12…−6 dBFS shaded so you can drive straight to it.
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.green.opacity(0.18))
                        .frame(width: (fraction(of: -6) - fraction(of: -12)) * width)
                        .offset(x: fraction(of: -12) * width)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: verdict))
                        .frame(width: fraction(of: hold) * width)
                }
            }
            .frame(height: 12)

            Text(String(format: "%.1f dBFS", hold))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(color(for: verdict))
                .frame(width: 74, alignment: .trailing)

            Text(verdict.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color(for: verdict))
                .frame(width: 210, alignment: .leading)
        }
    }

    private func fraction(of db: Float) -> CGFloat {
        CGFloat(min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1))
    }

    private func color(for verdict: (text: String, ok: Bool, hot: Bool)) -> Color {
        if verdict.hot { return .red }
        if verdict.ok { return .green }
        return .orange
    }
}

// MARK: - Burst envelope plot

/// Draws the captured burst (faint scope trace) with its envelope over the top,
/// and the ideal stimulus envelope time-aligned to the arrival for comparison —
/// the arta-mac equivalent of Linkwitz Fig. 2/6.
struct BurstPlotView: View {
    let result: BurstResult?
    var dbScale: Bool = true

    private let dbRange: Double = 60

    var body: some View {
        PlotStyle.panel(
            Canvas { context, size in
                guard let r = result, !r.responseEnvelope.isEmpty else {
                    context.draw(
                        Text("Press Burst to fire a shaped tone burst and see the envelope.")
                            .font(.callout).foregroundColor(PlotStyle.label),
                        at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }
                drawGrid(context: context, size: size, result: r)
                drawScopeTrace(context: context, size: size, result: r)
                drawStimulusEnvelope(context: context, size: size, result: r)
                drawResponseEnvelope(context: context, size: size, result: r)
                drawMarkers(context: context, size: size, result: r)
            }
        )
    }

    // Y: response envelope normalized to its own peak. Linear 1→0 top→bottom,
    // or dB 0→-dbRange. Each envelope is referenced to its own peak so the SHAPES
    // compare regardless of absolute level (as in the paper's overlays).
    private func yFor(_ linearFraction: Double, _ height: CGFloat) -> CGFloat {
        if dbScale {
            let db = 20 * log10(max(linearFraction, 1e-9))
            return CGFloat(min(max(-db / dbRange, 0), 1)) * height
        } else {
            return CGFloat(1 - min(max(linearFraction, 0), 1)) * height
        }
    }

    private func xFor(_ sample: Int, count: Int, _ width: CGFloat) -> CGFloat {
        CGFloat(sample) / CGFloat(max(count - 1, 1)) * width
    }

    private func drawGrid(context: GraphicsContext, size: CGSize, result r: BurstResult) {
        // Horizontal level lines.
        let levels: [Double] = dbScale ? [0, -10, -20, -30, -40, -50] : [1.0, 0.75, 0.5, 0.25]
        for lv in levels {
            let frac = dbScale ? pow(10, lv / 20) : lv
            let y = yFor(frac, size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(lv == 0 || lv == 1.0 ? PlotStyle.gridMajor : PlotStyle.gridMinor),
                           lineWidth: lv == 0 || lv == 1.0 ? 1 : 0.5)
            let label = dbScale ? "\(Int(lv))" : String(format: "%.2f", lv)
            context.draw(
                Text(label).font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                at: CGPoint(x: 4, y: y - 7), anchor: .leading)
        }
        // Time ticks relative to the burst onset (t=0 at arrival).
        let count = r.response.count
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let sample = Int(Double(count - 1) * fraction)
            let ms = Double(sample - r.arrivalSample) / r.sampleRate * 1000
            let anchor: UnitPoint = fraction == 0 ? .leading : fraction == 1 ? .trailing : .center
            let x = CGFloat(fraction) * size.width + (fraction == 0 ? 4 : fraction == 1 ? -4 : 0)
            context.draw(
                Text(String(format: "%.1f ms", ms)).font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                at: CGPoint(x: x, y: size.height - 9), anchor: anchor)
        }
    }

    /// Faint full-wave view of the raw captured burst behind the envelope.
    private func drawScopeTrace(context: GraphicsContext, size: CGSize, result r: BurstResult) {
        let samples = r.response
        let peak = max(r.responseEnvelopePeak, 1e-9)
        let count = samples.count
        let columns = max(Int(size.width), 1)
        let perCol = Double(count) / Double(columns)
        var path = Path()
        for col in 0..<columns {
            let s0 = Int(Double(col) * perCol)
            let s1 = min(Int(Double(col + 1) * perCol), count)
            guard s0 < count, s1 > s0 else { continue }
            var hi: Float = 0
            for i in s0..<s1 { hi = max(hi, abs(samples[i])) }
            let frac = Double(hi / peak)
            let y = yFor(frac, size.height)
            let x = CGFloat(col)
            path.move(to: CGPoint(x: x, y: size.height))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        context.stroke(path, with: .color(PlotStyle.trace.opacity(0.16)), lineWidth: 1)
    }

    private func drawResponseEnvelope(context: GraphicsContext, size: CGSize, result r: BurstResult) {
        let env = r.responseEnvelope
        let peak = max(r.responseEnvelopePeak, 1e-9)
        let count = env.count
        let stride = max(1, count / (Int(size.width) * 2))
        var path = Path()
        var started = false
        for i in Swift.stride(from: 0, to: count, by: stride) {
            let frac = Double(env[i] / peak)
            let point = CGPoint(x: xFor(i, count: count, size.width), y: yFor(frac, size.height))
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        context.stroke(path, with: .color(PlotStyle.trace), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
    }

    /// The ideal burst envelope, placed at the arrival sample and normalized to its
    /// own peak. Where the measured envelope departs from this is the system's
    /// dynamic distortion.
    private func drawStimulusEnvelope(context: GraphicsContext, size: CGSize, result r: BurstResult) {
        let env = r.stimulusEnvelope
        guard let sPeak = env.max(), sPeak > 0 else { return }
        let count = r.response.count
        let stride = max(1, env.count / (Int(size.width) * 2))
        var path = Path()
        var started = false
        for j in Swift.stride(from: 0, to: env.count, by: stride) {
            let respIndex = r.arrivalSample + j
            guard respIndex < count else { break }
            let frac = Double(env[j] / sPeak)
            let point = CGPoint(x: xFor(respIndex, count: count, size.width), y: yFor(frac, size.height))
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        context.stroke(path, with: .color(PlotStyle.phase.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
    }

    /// Onset (t=0) and burst-end guide lines; energy to the right of "end" is ring-out.
    private func drawMarkers(context: GraphicsContext, size: CGSize, result r: BurstResult) {
        let count = r.response.count
        let onsetX = xFor(r.arrivalSample, count: count, size.width)
        var onset = Path()
        onset.move(to: CGPoint(x: onsetX, y: 0))
        onset.addLine(to: CGPoint(x: onsetX, y: size.height))
        context.stroke(onset, with: .color(PlotStyle.cursor), lineWidth: 1)

        let endIdx = r.arrivalSample + r.burstLengthSamples
        if endIdx < count {
            let endX = xFor(endIdx, count: count, size.width)
            var end = Path()
            end.move(to: CGPoint(x: endX, y: 0))
            end.addLine(to: CGPoint(x: endX, y: size.height))
            context.stroke(end, with: .color(PlotStyle.target.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.draw(
                Text("burst end").font(PlotStyle.labelFont).foregroundColor(PlotStyle.target.opacity(0.9)),
                at: CGPoint(x: endX + 3, y: 10), anchor: .leading)
        }
    }
}
