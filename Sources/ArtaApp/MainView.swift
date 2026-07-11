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
                Stepper("In channel: \(model.inputChannel + 1)", value: $model.inputChannel, in: 0...63)

                Button("Refresh devices") { model.refreshDevices() }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Click: gate start (cursor) · Shift-click: gate end (marker)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cursor to peak") {
                    model.cursorSample = max(0, model.peakIndex(of: model.impulseResponse) - 20)
                    model.recomputeFrequencyResponse()
                }
                .disabled(model.impulseResponse.isEmpty)
            }
            .padding(8)

            IRPlotView(
                samples: model.impulseResponse,
                sampleRate: model.irSampleRate,
                cursorSample: $model.cursorSample,
                markerSample: $model.markerSample,
                onGateChanged: { model.recomputeFrequencyResponse() }
            )
            .padding([.leading, .trailing, .bottom], 8)
        }
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
