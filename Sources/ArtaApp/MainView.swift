import SwiftUI
import ArtaDSP

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab = .frequencyResponse

    enum Tab: String, CaseIterable {
        case frequencyResponse = "Frequency Response"
        case impulse = "Impulse Response"
        case room = "Room Acoustics"
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(8)

                Divider()

                switch tab {
                case .frequencyResponse: FRPanel()
                case .impulse: IRPanel()
                case .room: RoomPanel()
                }

                Divider()
                HStack {
                    if model.isMeasuring { ProgressView().controlSize(.small) }
                    Text(model.statusMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(6)
            }
        }
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @EnvironmentObject var model: AppModel

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
                HStack {
                    Text("From")
                    TextField("Hz", value: $model.f1, format: .number)
                    Text("to")
                    TextField("Hz", value: $model.f2, format: .number)
                    Text("Hz")
                }
                Picker("Length", selection: $model.sweepDuration) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("4 s").tag(4.0)
                }
                Picker("Level", selection: $model.outputLevelDB) {
                    Text("-6 dBFS").tag(-6.0)
                    Text("-12 dBFS").tag(-12.0)
                    Text("-20 dBFS").tag(-20.0)
                    Text("-30 dBFS").tag(-30.0)
                }
                Picker("Decay wait", selection: $model.postSilence) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("4 s").tag(4.0)
                }
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

                Spacer()

                Button("Set as overlay") { model.setCurrentAsOverlay() }
                    .disabled(model.currentFR == nil)
                Button("Load target...") { model.loadTargetCurve() }
                Button("Clear overlays") { model.clearOverlays() }
                    .disabled(model.overlays.isEmpty)
            }
            .padding(8)

            FRPlotView(curves: allCurves)
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
                if !model.impulseResponse.isEmpty {
                    Text(String(format: "delay est. %.1f ms",
                                model.systemDelaySamples / model.irSampleRate * 1000))
                        .font(.system(size: 11, design: .monospaced))
                }
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
