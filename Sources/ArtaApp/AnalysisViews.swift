import SwiftUI
import ArtaDSP

/// Phase 2 analyses on the current impulse response: ETC (energy-time curve),
/// step response, and cumulative spectral decay waterfall.
struct AnalysisPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: Mode = .etc
    @State private var etc: [Float] = []
    @State private var step: [Float] = []
    @State private var csd: [[Float]] = []
    @State private var csdSampleRate: Double = 48000
    @State private var csdFFTLength = 1024
    @State private var computing = false

    enum Mode: String, CaseIterable {
        case etc = "ETC (Envelope)"
        case step = "Step Response"
        case csd = "CSD Waterfall"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()
                if computing { ProgressView().controlSize(.small) }
                Button("Compute") { recompute() }
                    .disabled(model.impulseResponse.isEmpty || computing)
            }
            .padding(8)

            Group {
                switch mode {
                case .etc:
                    TimeCurvePlot(
                        values: etc, sampleRate: model.irSampleRate,
                        yTop: 0, yRange: 70, yLabel: "dB",
                        emptyHint: "Press Compute to derive the ETC from the current impulse response.")
                case .step:
                    TimeCurvePlot(
                        values: step, sampleRate: model.irSampleRate,
                        yTop: 1, yRange: 2, yLabel: "",
                        emptyHint: "Press Compute to derive the step response.")
                case .csd:
                    CSDWaterfallPlot(
                        slices: csd, sampleRate: csdSampleRate, fftLength: csdFFTLength,
                        emptyHint: "Press Compute for the cumulative spectral decay waterfall.")
                }
            }
            .padding([.leading, .trailing, .bottom], 8)
        }
        // Keyed on the generation counter, not the sample count: two sweeps at
        // the same settings produce IRs of identical length, so the count never
        // changed and the previous measurement's ETC/step/CSD stayed on screen.
        .onChange(of: model.irGeneration) { _ in
            etc = []; step = []; csd = []
        }
    }

    private func recompute() {
        let ir = model.impulseResponse
        guard !ir.isEmpty else { return }
        let fs = model.irSampleRate
        let cursor = model.cursorSample
        computing = true
        let currentMode = mode

        DispatchQueue.global(qos: .userInitiated).async {
            var newETC: [Float] = []
            var newStep: [Float] = []
            var newCSD: [[Float]] = []
            let from = min(max(0, cursor), ir.count - 1)
            switch currentMode {
            case .etc:
                // From the cursor (just ahead of the direct sound), 1.5 s max —
                // skips the propagation-delay lead-in and keeps the Hilbert FFT sane.
                let window = Array(ir[from..<min(ir.count, from + Int(fs * 1.5))])
                newETC = Analysis.energyTimeCurveDB(ir: window)
            case .step:
                // Integrate from the cursor, not from t=0 — the lead-in silence
                // only adds offset drift before the wavefront.
                let window = Array(ir[from..<min(ir.count, from + Int(fs * 0.05))])
                newStep = Analysis.stepResponse(ir: window)
            case .csd:
                newCSD = Analysis.cumulativeSpectralDecay(
                    ir: ir, startIndex: from,
                    fftLength: 1024, blockShift: 8, maxBlocks: 50)
            }
            DispatchQueue.main.async {
                etc = newETC
                step = newStep
                csd = newCSD
                csdSampleRate = fs
                csdFFTLength = 1024
                computing = false
            }
        }
    }
}

// MARK: - Generic time-domain curve plot

struct TimeCurvePlot: View {
    let values: [Float]
    let sampleRate: Double
    let yTop: Double
    let yRange: Double
    let yLabel: String
    let emptyHint: String

    var body: some View {
        PlotStyle.panel(
            Canvas { context, size in
                guard !values.isEmpty else {
                    context.draw(Text(emptyHint).font(.callout).foregroundColor(PlotStyle.label),
                                 at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }
                drawGrid(context: context, size: size)
                var path = Path()
                var started = false
                let stride = max(1, values.count / Int(max(size.width, 1)) / 2)
                for i in Swift.stride(from: 0, to: values.count, by: stride) {
                    let x = CGFloat(i) / CGFloat(values.count) * size.width
                    let yNorm = (yTop - Double(values[i])) / yRange
                    let y = CGFloat(min(max(yNorm, 0), 1)) * size.height
                    if started { path.addLine(to: CGPoint(x: x, y: y)) }
                    else { path.move(to: CGPoint(x: x, y: y)); started = true }
                }
                context.stroke(path, with: .color(PlotStyle.trace),
                               style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            }
        )
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        for fraction in [0.25, 0.5, 0.75] {
            var h = Path()
            h.move(to: CGPoint(x: 0, y: size.height * fraction))
            h.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            context.stroke(h, with: .color(PlotStyle.gridMinor), lineWidth: 0.5)
            var v = Path()
            v.move(to: CGPoint(x: size.width * fraction, y: 0))
            v.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            context.stroke(v, with: .color(PlotStyle.gridMinor), lineWidth: 0.5)
        }
        let totalMs = Double(values.count) / sampleRate * 1000
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let anchor: UnitPoint = fraction == 0 ? .leading : fraction == 1 ? .trailing : .center
            let x = CGFloat(fraction) * size.width + (fraction == 0 ? 4 : fraction == 1 ? -4 : 0)
            context.draw(
                Text(String(format: "%.0f ms", totalMs * fraction))
                    .font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                at: CGPoint(x: x, y: size.height - 9), anchor: anchor)
        }
        if !yLabel.isEmpty {
            for fraction in [0.0, 0.5, 1.0] {
                let value = yTop - yRange * fraction
                context.draw(
                    Text(String(format: "%.0f %@", value, yLabel))
                        .font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                    at: CGPoint(x: 4, y: CGFloat(fraction) * size.height * 0.96 + 6), anchor: .leading)
            }
        }
    }
}

// MARK: - CSD waterfall

struct CSDWaterfallPlot: View {
    let slices: [[Float]]
    let sampleRate: Double
    let fftLength: Int
    let emptyHint: String

    private let dbRange: Double = 30
    private let fLow: Double = 200
    private var fHigh: Double { min(20_000, sampleRate / 2) }

    var body: some View {
        PlotStyle.panel(canvas)
    }

    private var canvas: some View {
        Canvas { context, size in
            guard !slices.isEmpty else {
                context.draw(Text(emptyHint).font(.callout).foregroundColor(PlotStyle.label),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            // Classic waterfall projection: newest slice (t=0) at the front
            // bottom, older slices shifted up-right, drawn back to front.
            let sliceCount = slices.count
            let xShiftTotal = size.width * 0.25
            let yShiftTotal = size.height * 0.45
            let plotW = size.width - xShiftTotal - 30
            let plotH = size.height - yShiftTotal - 30

            let binHz = sampleRate / Double(fftLength)
            let logLow = log10(fLow)
            let logHigh = log10(fHigh)

            for s in Swift.stride(from: sliceCount - 1, through: 0, by: -1) {
                let depth = Double(s) / Double(max(sliceCount - 1, 1)) // 0 = front
                let xOff = CGFloat(depth) * xShiftTotal
                let yOff = CGFloat(1.0 - depth) * yShiftTotal

                var path = Path()
                var started = false
                let slice = slices[s]
                for bin in 1..<slice.count {
                    let f = Double(bin) * binHz
                    guard f >= fLow, f <= fHigh else { continue }
                    let xNorm = (log10(f) - logLow) / (logHigh - logLow)
                    let dbNorm = min(max(Double(-slice[bin]) / dbRange, 0), 1)
                    let x = xOff + CGFloat(xNorm) * plotW
                    let y = 20 + yOff + CGFloat(dbNorm) * plotH
                    if started { path.addLine(to: CGPoint(x: x, y: y)) }
                    else { path.move(to: CGPoint(x: x, y: y)); started = true }
                }
                let hue = 0.6 - 0.6 * depth // blue (old) -> red (front)
                context.stroke(
                    path,
                    with: .color(Color(hue: max(hue, 0), saturation: 0.8, brightness: 0.9)),
                    lineWidth: s == 0 ? 1.4 : 0.8)
            }

            for f in [200.0, 500, 1000, 2000, 5000, 10_000, 20_000] where f >= fLow && f <= fHigh {
                let xNorm = (log10(f) - logLow) / (logHigh - logLow)
                let label = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
                context.draw(
                    Text(label).font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                    at: CGPoint(x: CGFloat(xNorm) * plotW, y: size.height - 9))
            }
            context.draw(
                Text("0 to -\(Int(dbRange)) dB · front slice = t0, back = later decay")
                    .font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                at: CGPoint(x: size.width - 8, y: 10), anchor: .trailing)
        }
    }
}
