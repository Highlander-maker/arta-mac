import SwiftUI
import ArtaDSP

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab = .frequencyResponse

    enum Tab: String, CaseIterable {
        case frequencyResponse = "Frequency Response"
        case impulse = "Impulse Response"
        case analysis = "Analysis"
        case room = "Room Acoustics"
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar()
                .navigationSplitViewColumnWidth(min: 270, ideal: 290)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)

                    Spacer()
                    MeasurementReadouts()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()

                switch tab {
                case .frequencyResponse: FRPanel()
                case .impulse: IRPanel()
                case .analysis: AnalysisPanel()
                case .room: RoomPanel()
                }

                Divider()
                HStack(spacing: 8) {
                    if model.isMeasuring { ProgressView().controlSize(.small) }
                    if model.generatorRunning {
                        Label("GEN", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    Text(model.statusMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }
}

/// Delay / input peak / correlation chips from the last measurement.
struct MeasurementReadouts: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if !model.impulseResponse.isEmpty {
                chip("delay", String(format: "%.2f ms",
                                     model.systemDelaySamples / model.irSampleRate * 1000))
            }
            if let peak = model.lastPeakDBFS {
                chip("in pk", String(format: "%.1f dBFS", peak),
                     warn: peak < -60 || peak > -3)
            }
            if let corr = model.lastCorrelationDB {
                chip("corr", String(format: "%.0f dB", corr), warn: corr < -20)
            }
        }
    }

    private func chip(_ title: String, _ value: String, warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(warn ? .orange : .primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - Input level meter

/// Live gain-staging meter: RMS fill + decaying peak-hold, per input channel.
/// Floor -60 dBFS, ceiling 0 dBFS. Zones: green below -18, amber -18...-3 (a
/// healthy measurement level lives here), red above -3 (clipping risk).
struct InputMeterView: View {
    @ObservedObject var meter: InputMeter

    private let floorDB: Float = -60
    private let ceilingDB: Float = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = meter.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if meter.rmsDB.isEmpty {
                Text(meter.running ? "Listening..." : "Meter stopped.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(meter.rmsDB.indices, id: \.self) { ch in
                    channelRow(index: ch)
                }
            }
        }
    }

    private func channelRow(index: Int) -> some View {
        let rms = meter.rmsDB[index]
        let hold = index < meter.holdDB.count ? meter.holdDB[index] : rms
        return HStack(spacing: 6) {
            Text("In \(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 34, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(zoneColor(rms))
                        .frame(width: fraction(of: rms) * width)
                    // Peak-hold tick
                    Rectangle()
                        .fill(zoneColor(hold).opacity(0.9))
                        .frame(width: 2)
                        .offset(x: max(0, fraction(of: hold) * width - 1))
                }
            }
            .frame(height: 10)

            Text(String(format: "%.0f", hold))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(zoneColor(hold))
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func fraction(of db: Float) -> CGFloat {
        CGFloat(min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1))
    }

    private func zoneColor(_ db: Float) -> Color {
        if db > -3 { return .red }
        if db > -18 { return .green }
        return .secondary
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @EnvironmentObject var model: AppModel

    /// Common alignment frequencies: sub/top crossover region + reference tones.
    private let quickFrequencies: [Double] = [40, 63, 80, 100, 125, 1000, 4000, 10_000]

    var body: some View {
        Form {
            Section("Devices") {
                Picker("Output", selection: $model.outputDeviceID) {
                    Text("System default").tag(nil as UInt32?)
                    ForEach(model.devices.filter { $0.outputChannels > 0 }) { dev in
                        Text(dev.label).tag(dev.id as UInt32?)
                    }
                }
                Stepper("Out channel: \(model.outputChannel + 1)", value: $model.outputChannel, in: 0...63)

                Picker("Input", selection: $model.inputDeviceID) {
                    Text("System default").tag(nil as UInt32?)
                    ForEach(model.devices.filter { $0.inputChannels > 0 }) { dev in
                        Text(dev.label).tag(dev.id as UInt32?)
                    }
                }
                .onChange(of: model.inputDeviceID) { _ in model.restartMeterForDeviceChange() }
                Stepper("In channel: \(model.inputChannel + 1)", value: $model.inputChannel, in: 0...63)

                Toggle("Loop reference (dual-channel)", isOn: $model.useLoopReference)
                if model.useLoopReference {
                    Stepper("Loop channel: \(model.referenceChannel + 1)", value: $model.referenceChannel, in: 0...63)
                    Text("Patch output \(model.referenceChannel + 1) back into input \(model.referenceChannel + 1). The sweep drives the speaker (out \(model.outputChannel + 1)) and the loop together — mic on in \(model.inputChannel + 1) measures the PA, the loop is the reference. Transfer function = mic ÷ loop, SMAART-style.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Refresh devices") {
                    model.refreshDevices()
                    model.restartMeterForDeviceChange()
                }
            }

            Section("Input levels") {
                InputMeterView(meter: model.meter)
            }

            Section("Sweep") {
                Picker("Preset", selection: $model.sweepPreset) {
                    ForEach(SweepPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .onChange(of: model.sweepPreset) { newValue in
                    model.applyPreset(newValue)
                }
                Text(model.sweepPreset.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                LabeledContent("Range") {
                    HStack(spacing: 4) {
                        TextField("", value: $model.f1, format: .number.grouping(.never))
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: model.f1) { _ in model.sweepFieldEdited() }
                        Text("–").foregroundColor(.secondary)
                        TextField("", value: $model.f2, format: .number.grouping(.never))
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: model.f2) { _ in model.sweepFieldEdited() }
                        Text("Hz").foregroundColor(.secondary)
                    }
                }
                Picker("Length", selection: $model.sweepDuration) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("3 s").tag(3.0)
                    Text("4 s").tag(4.0)
                }
                .onChange(of: model.sweepDuration) { _ in model.sweepFieldEdited() }
                Picker("Level", selection: $model.outputLevelDB) {
                    Text("-6 dBFS").tag(-6.0)
                    Text("-12 dBFS").tag(-12.0)
                    Text("-20 dBFS").tag(-20.0)
                    Text("-30 dBFS").tag(-30.0)
                }
                Picker("Decay wait", selection: $model.postSilence) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("1.5 s").tag(1.5)
                    Text("2 s").tag(2.0)
                    Text("4 s").tag(4.0)
                }
                .onChange(of: model.postSilence) { _ in model.sweepFieldEdited() }
            }

            Section {
                Button {
                    model.runMeasurement()
                } label: {
                    Label(model.isMeasuring ? "Measuring..." : "Measure",
                          systemImage: "waveform.badge.mic")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isMeasuring)
                .controlSize(.large)
            }

            Section("Generator") {
                Picker("Signal", selection: $model.generatorMode) {
                    ForEach(GeneratorMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.generatorMode) { _ in model.restartGeneratorIfRunning() }

                if model.generatorMode != .pink {
                    LabeledContent(model.generatorMode == .sine ? "Frequency" : "Centre") {
                        HStack(spacing: 4) {
                            TextField("", value: $model.generatorFrequency, format: .number.grouping(.never))
                                .frame(width: 68)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { model.restartGeneratorIfRunning() }
                            Text("Hz").foregroundColor(.secondary)
                        }
                    }
                    // Quick-pick chips for the usual alignment frequencies.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                              spacing: 4) {
                        ForEach(quickFrequencies, id: \.self) { f in
                            Button {
                                model.generatorFrequency = f
                                model.restartGeneratorIfRunning()
                            } label: {
                                Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(model.generatorFrequency == f ? .accentColor : nil)
                        }
                    }
                }

                if model.generatorMode == .pinkBand {
                    Picker("Bandwidth", selection: $model.generatorFraction) {
                        Text("1/1 octave").tag(1)
                        Text("1/3 octave").tag(3)
                    }
                    .onChange(of: model.generatorFraction) { _ in model.restartGeneratorIfRunning() }
                }

                HStack {
                    Text("Level")
                    Slider(value: $model.generatorLevelDB, in: -50...0, step: 1) { _ in
                        model.generatorLevelChanged()
                    }
                    Text(String(format: "%.0f dB", model.generatorLevelDB))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }

                Button {
                    model.toggleGenerator()
                } label: {
                    Label(model.generatorRunning ? "Stop" : "Start",
                          systemImage: model.generatorRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(model.generatorRunning ? .red : nil)
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.isMeasuring)
            }

            Section("Alignment Click") {
                Text("Clicks main + subs together — nudge the offset until they land as one hit.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Stepper("Main ch: \(model.clickChannelA + 1)", value: $model.clickChannelA, in: 0...63)
                    .onChange(of: model.clickChannelA) { _ in model.restartAlignmentClickIfRunning() }
                Stepper("Sub ch: \(model.clickChannelB + 1)", value: $model.clickChannelB, in: 0...63)
                    .onChange(of: model.clickChannelB) { _ in model.restartAlignmentClickIfRunning() }

                LabeledContent("Sub offset") {
                    HStack(spacing: 4) {
                        TextField("", value: $model.clickDelayMsB, format: .number.precision(.fractionLength(1)))
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { model.restartAlignmentClickIfRunning() }
                        Text("ms").foregroundColor(.secondary)
                    }
                }
                Slider(value: $model.clickDelayMsB, in: -50...50, step: 0.1) { _ in
                    model.restartAlignmentClickIfRunning()
                }
                HStack(spacing: 4) {
                    ForEach([-5.0, -1.0, -0.5, 0.5, 1.0, 5.0], id: \.self) { nudge in
                        Button(nudge > 0 ? "+\(nudge, specifier: "%.1f")" : "\(nudge, specifier: "%.1f")") {
                            model.clickDelayMsB += nudge
                            model.restartAlignmentClickIfRunning()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    Spacer()
                    Button("Zero") {
                        model.clickDelayMsB = 0
                        model.restartAlignmentClickIfRunning()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                HStack {
                    Text("Rate")
                    Slider(value: $model.clickRateHz, in: 0.5...8, step: 0.5) { _ in
                        model.restartAlignmentClickIfRunning()
                    }
                    Text(String(format: "%.1f Hz", model.clickRateHz))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }

                HStack {
                    Text("Level")
                    Slider(value: $model.clickLevelDB, in: -50...0, step: 1) { _ in
                        model.clickLevelChanged()
                    }
                    Text(String(format: "%.0f dB", model.clickLevelDB))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }

                Button {
                    model.toggleAlignmentClick()
                } label: {
                    Label(model.clickRunning ? "Stop" : "Start",
                          systemImage: model.clickRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(model.clickRunning ? .red : nil)
                .disabled(model.isMeasuring)
            }

            Section("Files") {
                Button("Load .pir...") { model.loadPIR() }
                Button("Save .pir...") { model.savePIR() }
                    .disabled(model.impulseResponse.isEmpty)
                Button("Export .frd...") { model.exportFRD() }
                    .disabled(model.currentFR == nil)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Frequency response panel

struct FRPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Smoothing", selection: $model.smoothing) {
                    Text("None").tag(0)
                    Text("1/1").tag(1)
                    Text("1/3").tag(3)
                    Text("1/6").tag(6)
                    Text("1/12").tag(12)
                    Text("1/24").tag(24)
                }
                .frame(maxWidth: 220)
                .onChange(of: model.smoothing) { _ in model.recomputeFrequencyResponse() }

                Picker("Gate window", selection: $model.gateTailFraction) {
                    Text("Uniform").tag(0.0)
                    Text("Hann 12%").tag(0.12)
                    Text("Hann 25%").tag(0.25)
                    Text("Hann 50%").tag(0.5)
                }
                .frame(maxWidth: 200)
                .onChange(of: model.gateTailFraction) { _ in model.recomputeFrequencyResponse() }

                VStack(alignment: .leading, spacing: 1) {
                    Picker("FFT", selection: $model.fftSize) {
                        Text("4096").tag(4096)
                        Text("8192").tag(8192)
                        Text("16384").tag(16384)
                        Text("32768").tag(32768)
                        Text("65536").tag(65536)
                        Text("131072").tag(131072)
                    }
                    .onChange(of: model.fftSize) { _ in model.recomputeFrequencyResponse() }

                    if model.effectiveFFTSize != model.fftSize {
                        Text("using \(model.effectiveFFTSize) (gate longer)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if model.irSampleRate > 0 {
                        Text(String(format: "%.2f Hz/bin", model.irSampleRate / Double(model.effectiveFFTSize)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 170)

                Toggle("Phase", isOn: $model.showPhase)
                    .toggleStyle(.checkbox)

                Spacer()

                Button("Set as overlay") { model.setCurrentAsOverlay() }
                    .disabled(model.currentFR == nil)
                Button("Load target...") { model.loadTargetCurve() }
                Button("Clear overlays") { model.clearOverlays() }
                    .disabled(model.overlays.isEmpty)
            }
            .padding(8)

            FRPlotView(
                curves: allCurves,
                phase: model.currentPhase,
                phaseFrequencies: model.currentFR?.frequencies ?? [],
                showPhase: model.showPhase
            )
            .padding([.leading, .trailing, .bottom], 8)
        }
    }

    private var allCurves: [FRCurve] {
        var curves = model.overlays
        if let current = model.currentFR { curves.append(current) }
        return curves
    }
}

// MARK: - Impulse response panel

struct IRPanel: View {
    @EnvironmentObject var model: AppModel

    private var empty: Bool { model.impulseResponse.isEmpty }
    private var zoomed: Bool { model.irViewLength > 0 && !empty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Scroll: zoom · Shift-scroll: amplitude · Click: gate start · Shift-click: gate end")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()

                ControlGroup {
                    Button {
                        model.irZoom(factor: 0.5)
                    } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (around the cursor)")
                    .keyboardShortcut("=", modifiers: [])
                    Button {
                        model.irZoom(factor: 2.0)
                    } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                    .keyboardShortcut("-", modifiers: [])
                }
                .frame(width: 88)
                .disabled(empty)

                Button("Gate") { model.irZoomToGate() }
                    .help("Zoom to fit the current gate")
                    .disabled(empty || model.markerSample == nil)
                Button("Fit") { model.irFit() }
                    .help("Show the whole impulse response")
                    .keyboardShortcut("0", modifiers: [])
                    .disabled(empty || (!zoomed && model.irAmpZoom <= 1.01))
                Button("Cursor to peak") {
                    model.cursorSample = max(0, model.peakIndex(of: model.impulseResponse) - 20)
                    model.recomputeFrequencyResponse()
                }
                .disabled(empty)

                Divider().frame(height: 16)

                if model.frozenIR.isEmpty {
                    Button("Freeze") { model.freezeIR() }
                        .help("Snapshot this IR as a delay reference, then move the mic and measure again")
                        .disabled(empty)
                } else {
                    Button("Clear ref") { model.clearFrozenIR() }
                        .help("Remove the frozen reference IR")
                    if let d = model.irDeltaMs {
                        Text(String(format: "Δ %.2f ms · %.2f m", d, abs(d) / 1000 * 343))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .padding(8)

            IRPlotView(
                samples: model.impulseResponse,
                sampleRate: model.irSampleRate,
                visibleStart: model.irVisibleRange.lowerBound,
                visibleLength: max(model.irVisibleRange.count, 1),
                ampZoom: model.irAmpZoom,
                signalPeak: model.irPeak,
                frozenSamples: model.frozenIR,
                frozenPeak: model.frozenIRPeak,
                frozenPeakIndex: model.frozenIRPeakIndex,
                currentPeakIndex: model.irPeakIndex,
                deltaMs: model.irDeltaMs,
                cursorSample: $model.cursorSample,
                markerSample: $model.markerSample,
                onGateChanged: { model.recomputeFrequencyResponse() },
                onZoom: { factor, pivot in model.irZoom(factor: factor, center: pivot) },
                onAmpZoom: { factor in model.irAmpZoomBy(factor) },
                onPan: { delta in model.irPanBy(delta) }
            )
            .padding([.leading, .trailing], 8)

            if zoomed {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(model.irVisibleRange.lowerBound) },
                            set: { model.irViewStart = Int($0) }
                        ),
                        in: 0...Double(max(model.impulseResponse.count - model.irVisibleRange.count, 1))
                    )
                    Text(String(format: "%.0f–%.0f ms",
                                Double(model.irVisibleRange.lowerBound) / model.irSampleRate * 1000,
                                Double(model.irVisibleRange.upperBound) / model.irSampleRate * 1000))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 96, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Room acoustics panel

struct RoomPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Recompute") { model.recomputeRoomAcoustics() }
                    .disabled(model.impulseResponse.isEmpty)
                Button("Compute STI") { model.computeSTI() }
                    .disabled(model.impulseResponse.isEmpty)
                Spacer()
                if let sti = model.stiResult {
                    Text(String(format: "STI %.2f (%@) · %%ALcons %.1f%%",
                                sti.sti, sti.rating, sti.alcons))
                        .font(.system(size: 12, design: .monospaced))
                        .bold()
                }
            }
            .padding([.top, .leading, .trailing], 8)

            if model.bandParams.isEmpty && model.roomParams == nil {
                Spacer()
                Text("Run a measurement (or load a .pir) to see ISO 3382 room parameters.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                paramTable
                Spacer()
            }
        }
    }

    private var paramTable: some View {
        let columns = [("", 70.0)] + model.bandParams.map { (format(center: $0.center), 70.0) } + [("Wide", 70.0)]
        let rows: [(String, (RoomAcousticParams) -> String)] = [
            ("T30 (s)", { $0.t30.map { String(format: "%.2f", $0) } ?? "–" }),
            ("T20 (s)", { $0.t20.map { String(format: "%.2f", $0) } ?? "–" }),
            ("EDT (s)", { $0.edt.map { String(format: "%.2f", $0) } ?? "–" }),
            ("C50 (dB)", { String(format: "%.1f", $0.c50) }),
            ("C80 (dB)", { String(format: "%.1f", $0.c80) }),
            ("D50 (%)", { String(format: "%.0f", $0.d50) }),
            ("Ts (ms)", { String(format: "%.0f", $0.ts) }),
        ]

        return ScrollView(.horizontal) {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    ForEach(columns.indices, id: \.self) { i in
                        Text(columns[i].0).bold().frame(minWidth: 60, alignment: .trailing)
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        Text(rows[r].0).bold().frame(minWidth: 60, alignment: .trailing)
                        ForEach(model.bandParams.indices, id: \.self) { b in
                            Text(rows[r].1(model.bandParams[b].params))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        if let wide = model.roomParams {
                            Text(rows[r].1(wide))
                                .font(.system(size: 11, design: .monospaced))
                        } else {
                            Text("–")
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func format(center: Double) -> String {
        center >= 1000 ? "\(Int(center / 1000))k" : "\(Int(center))"
    }
}
