import SwiftUI
import ArtaDSP

// MARK: - Shared plot styling
//
// The plot surface is deliberately the same dark charcoal in both system
// themes — like a scope screen or SMAART's graph area — so traces keep the
// same contrast and colour identity everywhere. Window chrome stays native.

enum PlotStyle {
    static let background = Color(red: 0.075, green: 0.085, blue: 0.10)
    static let border = Color.white.opacity(0.10)
    static let gridMinor = Color.white.opacity(0.07)
    static let gridMajor = Color.white.opacity(0.16)
    static let label = Color(white: 0.62)
    static let trace = Color(red: 1.00, green: 0.72, blue: 0.20)   // amber
    static let phase = Color(red: 0.30, green: 0.78, blue: 0.95)   // cyan
    static let target = Color(red: 0.95, green: 0.36, blue: 0.32)  // signal red
    static let cursor = Color(white: 0.9).opacity(0.65)
    static let gateFill = Color(red: 1.00, green: 0.72, blue: 0.20).opacity(0.07)
    static let overlayPalette: [Color] = [
        Color(red: 0.45, green: 0.85, blue: 0.55),
        Color(red: 0.75, green: 0.55, blue: 0.95),
        Color(red: 0.95, green: 0.55, blue: 0.75),
        Color(red: 0.55, green: 0.70, blue: 0.95),
        Color(red: 0.85, green: 0.85, blue: 0.45),
        Color(red: 0.50, green: 0.85, blue: 0.85),
    ]

    static func panel<V: View>(_ content: V) -> some View {
        content
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 1))
    }

    static let labelFont = Font.system(size: 9, weight: .medium, design: .monospaced)
    static let readoutFont = Font.system(size: 11, weight: .semibold, design: .monospaced)
}

// MARK: - Frequency response plot (log-frequency, dB magnitude, optional phase)

struct FRPlotView: View {
    let curves: [FRCurve]
    var phase: [Float] = []
    var phaseFrequencies: [Double] = []
    var showPhase = false
    var fLow: Double = 20
    var fHigh: Double = 20_000
    var dbTop: Double = 20
    var dbRange: Double = 80

    @State private var hoverLocation: CGPoint? = nil

    private let decadeTicks: [Double] = [
        20, 30, 40, 50, 60, 80, 100, 200, 300, 400, 500, 600, 800,
        1000, 2000, 3000, 4000, 5000, 6000, 8000, 10_000, 20_000
    ]
    private let labeledTicks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]

    var body: some View {
        PlotStyle.panel(
            Canvas { context, size in
                drawGrid(context: context, size: size)
                if showPhase, !phase.isEmpty {
                    drawPhase(context: context, size: size)
                }
                for curve in curves {
                    drawCurve(curve, context: context, size: size)
                }
                drawLegend(context: context, size: size)
                if let hover = hoverLocation {
                    drawCursor(at: hover, context: context, size: size)
                }
            }
            .onContinuousHover { hoverPhase in
                switch hoverPhase {
                case .active(let location): hoverLocation = location
                case .ended: hoverLocation = nil
                }
            }
        )
    }

    private func xFor(_ f: Double, _ size: CGSize) -> CGFloat {
        let logLow = log10(fLow)
        let logHigh = log10(fHigh)
        return CGFloat((log10(f) - logLow) / (logHigh - logLow)) * size.width
    }

    private func fFor(_ x: CGFloat, _ size: CGSize) -> Double {
        let logLow = log10(fLow)
        let logHigh = log10(fHigh)
        return pow(10, logLow + Double(x / size.width) * (logHigh - logLow))
    }

    private func yFor(_ db: Double, _ size: CGSize) -> CGFloat {
        CGFloat((dbTop - db) / dbRange) * size.height
    }

    private func yForPhase(_ degrees: Double, _ size: CGSize) -> CGFloat {
        CGFloat((180.0 - degrees) / 360.0) * size.height
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        for f in decadeTicks where f >= fLow && f <= fHigh {
            let x = xFor(f, size)
            let major = labeledTicks.contains(f)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(major ? PlotStyle.gridMajor : PlotStyle.gridMinor),
                           lineWidth: major ? 1 : 0.5)
            if major {
                let label = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
                context.draw(
                    Text(label).font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                    at: CGPoint(x: x + 3, y: size.height - 9), anchor: .leading)
            }
        }
        var db = dbTop
        while db >= dbTop - dbRange {
            let y = yFor(db, size)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(db == 0 ? PlotStyle.gridMajor : PlotStyle.gridMinor),
                           lineWidth: db == 0 ? 1 : 0.5)
            context.draw(
                Text("\(Int(db))").font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                at: CGPoint(x: 4, y: y - 7), anchor: .leading)
            db -= 10
        }
        if showPhase {
            for deg in [180, 90, 0, -90, -180] {
                context.draw(
                    Text("\(deg)°").font(PlotStyle.labelFont)
                        .foregroundColor(PlotStyle.phase.opacity(0.8)),
                    at: CGPoint(x: size.width - 4, y: yForPhase(Double(deg), size) + (deg == 180 ? 8 : deg == -180 ? -8 : 0)),
                    anchor: .trailing)
            }
        }
    }

    private func drawPhase(context: GraphicsContext, size: CGSize) {
        var path = Path()
        var started = false
        var lastY: CGFloat? = nil
        for i in 0..<min(phase.count, phaseFrequencies.count) {
            let f = phaseFrequencies[i]
            guard f >= fLow, f <= fHigh else { continue }
            let point = CGPoint(x: xFor(f, size), y: yForPhase(Double(phase[i]), size))
            // Break the line at ±180° wraps instead of drawing vertical strokes.
            if started, let ly = lastY, abs(point.y - ly) > size.height * 0.5 {
                started = false
            }
            if started {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                started = true
            }
            lastY = point.y
        }
        context.stroke(path, with: .color(PlotStyle.phase.opacity(0.85)), lineWidth: 1.1)
    }

    private func drawCurve(_ curve: FRCurve, context: GraphicsContext, size: CGSize) {
        var path = Path()
        var started = false
        for i in 0..<min(curve.frequencies.count, curve.magnitudesDB.count) {
            let f = curve.frequencies[i]
            guard f >= fLow, f <= fHigh else { continue }
            let point = CGPoint(x: xFor(f, size), y: yFor(Double(curve.magnitudesDB[i]), size))
            guard point.y.isFinite else { continue }
            if started {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                started = true
            }
        }
        let style = StrokeStyle(lineWidth: curve.isTarget ? 1.3 : 1.7,
                                lineJoin: .round,
                                dash: curve.isTarget ? [6, 3] : [])
        context.stroke(path, with: .color(curve.color), style: style)
    }

    private func drawLegend(context: GraphicsContext, size: CGSize) {
        var y: CGFloat = 10
        var entries: [(String, Color, Bool)] = curves.map { ($0.name, $0.color, $0.isTarget) }
        if showPhase, !phase.isEmpty { entries.append(("Phase", PlotStyle.phase, false)) }
        guard entries.count > 1 || showPhase else { return }
        for (name, color, dashed) in entries {
            var line = Path()
            line.move(to: CGPoint(x: 10, y: y))
            line.addLine(to: CGPoint(x: 28, y: y))
            context.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 2] : []))
            context.draw(
                Text(name).font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                at: CGPoint(x: 33, y: y), anchor: .leading)
            y += 13
        }
    }

    private func drawCursor(at location: CGPoint, context: GraphicsContext, size: CGSize) {
        guard location.x >= 0, location.x <= size.width else { return }
        var path = Path()
        path.move(to: CGPoint(x: location.x, y: 0))
        path.addLine(to: CGPoint(x: location.x, y: size.height))
        context.stroke(path, with: .color(PlotStyle.cursor), lineWidth: 1)

        let f = fFor(location.x, size)
        var readout = f >= 1000 ? String(format: "%.2f kHz", f / 1000) : String(format: "%.1f Hz", f)
        if let main = curves.last(where: { !$0.isTarget }),
           let idx = nearestIndex(in: main.frequencies, to: f) {
            readout += String(format: "  %.1f dB", main.magnitudesDB[idx])
            if showPhase, idx < phase.count {
                readout += String(format: "  %.0f°", phase[idx])
            }
        }
        let anchor: UnitPoint = location.x > size.width - 170 ? .trailing : .leading
        let x = anchor == .leading ? location.x + 8 : location.x - 8
        context.draw(
            Text(readout).font(PlotStyle.readoutFont).foregroundColor(.white),
            at: CGPoint(x: x, y: 12), anchor: anchor)
    }

    private func nearestIndex(in freqs: [Double], to f: Double) -> Int? {
        guard !freqs.isEmpty else { return nil }
        var lo = 0
        var hi = freqs.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if freqs[mid] < f { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - Impulse response plot (time domain with cursor / marker / gate)

struct IRPlotView: View {
    let samples: [Float]
    let sampleRate: Double
    @Binding var cursorSample: Int
    @Binding var markerSample: Int?
    var onGateChanged: () -> Void

    var body: some View {
        GeometryReader { geo in
            PlotStyle.panel(
                Canvas { context, size in
                    drawWaveform(context: context, size: size)
                    drawGate(context: context, size: size)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let idx = sampleFor(x: value.location.x, width: geo.size.width)
                            if NSEvent.modifierFlags.contains(.shift) {
                                markerSample = idx
                            } else {
                                cursorSample = idx
                            }
                            onGateChanged()
                        }
                )
            )
        }
    }

    private func sampleFor(x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, !samples.isEmpty else { return 0 }
        return min(max(Int(x / width * CGFloat(samples.count)), 0), samples.count - 1)
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        guard !samples.isEmpty else {
            context.draw(Text("No impulse response — run a measurement or load a .pir file.")
                .font(.callout).foregroundColor(PlotStyle.label),
                at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        // Horizontal zero line.
        let mid = size.height / 2
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: mid))
        zero.addLine(to: CGPoint(x: size.width, y: mid))
        context.stroke(zero, with: .color(PlotStyle.gridMinor), lineWidth: 1)

        let peak = max(samples.map(abs).max() ?? 1, 1e-9)
        let columns = Int(size.width)
        let samplesPerColumn = max(1, samples.count / max(columns, 1))

        var path = Path()
        for col in 0..<columns {
            let start = col * samplesPerColumn
            guard start < samples.count else { break }
            let end = min(start + samplesPerColumn, samples.count)
            var lo = samples[start]
            var hi = samples[start]
            for i in start..<end {
                lo = min(lo, samples[i])
                hi = max(hi, samples[i])
            }
            let x = CGFloat(col)
            let yHi = mid - CGFloat(hi / peak) * mid * 0.9
            let yLo = mid - CGFloat(lo / peak) * mid * 0.9
            path.move(to: CGPoint(x: x, y: yHi))
            path.addLine(to: CGPoint(x: x, y: max(yLo, yHi + 0.5)))
        }
        context.stroke(path, with: .color(PlotStyle.trace), lineWidth: 1)

        // Time axis labels.
        let totalMs = Double(samples.count) / sampleRate * 1000
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let ms = totalMs * fraction
            let anchor: UnitPoint = fraction == 0 ? .leading : fraction == 1 ? .trailing : .center
            let x = CGFloat(fraction) * size.width + (fraction == 0 ? 4 : fraction == 1 ? -4 : 0)
            context.draw(
                Text(String(format: "%.0f ms", ms)).font(PlotStyle.labelFont)
                    .foregroundColor(PlotStyle.label),
                at: CGPoint(x: x, y: size.height - 9), anchor: anchor)
        }
    }

    private func drawGate(context: GraphicsContext, size: CGSize) {
        guard !samples.isEmpty else { return }
        let cursorX = CGFloat(cursorSample) / CGFloat(samples.count) * size.width
        var cursorPath = Path()
        cursorPath.move(to: CGPoint(x: cursorX, y: 0))
        cursorPath.addLine(to: CGPoint(x: cursorX, y: size.height))
        context.stroke(cursorPath, with: .color(PlotStyle.trace.opacity(0.9)), lineWidth: 1)

        if let marker = markerSample {
            let markerX = CGFloat(marker) / CGFloat(samples.count) * size.width
            var markerPath = Path()
            markerPath.move(to: CGPoint(x: markerX, y: 0))
            markerPath.addLine(to: CGPoint(x: markerX, y: size.height))
            context.stroke(markerPath, with: .color(PlotStyle.target), lineWidth: 1)

            if markerX > cursorX {
                let gateRect = CGRect(x: cursorX, y: 0, width: markerX - cursorX, height: size.height)
                context.fill(Path(gateRect), with: .color(PlotStyle.gateFill))
            }
            let gateMs = Double(marker - cursorSample) / sampleRate * 1000
            context.draw(
                Text(String(format: "gate %.1f ms", gateMs))
                    .font(PlotStyle.readoutFont).foregroundColor(PlotStyle.trace),
                at: CGPoint(x: (cursorX + max(markerX, cursorX)) / 2, y: 12))
        }
    }
}
