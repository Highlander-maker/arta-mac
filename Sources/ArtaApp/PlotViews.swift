import SwiftUI
import ArtaDSP

// MARK: - Frequency response plot (log-frequency, dB magnitude)

struct FRPlotView: View {
    let curves: [FRCurve]
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
        Canvas { context, size in
            drawGrid(context: context, size: size)
            for curve in curves {
                drawCurve(curve, context: context, size: size)
            }
            if let hover = hoverLocation {
                drawCursor(at: hover, context: context, size: size)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverLocation = location
            case .ended: hoverLocation = nil
            }
        }
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

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let gridColor = Color.gray.opacity(0.25)
        let labelColor = Color.secondary

        for f in decadeTicks where f >= fLow && f <= fHigh {
            let x = xFor(f, size)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(gridColor), lineWidth: labeledTicks.contains(f) ? 1 : 0.5)
            if labeledTicks.contains(f) {
                let label = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
                context.draw(
                    Text(label).font(.system(size: 9)).foregroundColor(labelColor),
                    at: CGPoint(x: x + 2, y: size.height - 8), anchor: .leading)
            }
        }
        var db = dbTop
        while db >= dbTop - dbRange {
            let y = yFor(db, size)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: db == 0 ? 1 : 0.5)
            context.draw(
                Text("\(Int(db))").font(.system(size: 9)).foregroundColor(labelColor),
                at: CGPoint(x: 4, y: y - 6), anchor: .leading)
            db -= 10
        }
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
        let style = StrokeStyle(lineWidth: curve.isTarget ? 1.2 : 1.6,
                                dash: curve.isTarget ? [6, 3] : [])
        context.stroke(path, with: .color(curve.color), style: style)
    }

    private func drawCursor(at location: CGPoint, context: GraphicsContext, size: CGSize) {
        guard location.x >= 0, location.x <= size.width else { return }
        var path = Path()
        path.move(to: CGPoint(x: location.x, y: 0))
        path.addLine(to: CGPoint(x: location.x, y: size.height))
        context.stroke(path, with: .color(.yellow.opacity(0.7)), lineWidth: 1)

        let f = fFor(location.x, size)
        var readout = String(format: "%.0f Hz", f)
        if let main = curves.first(where: { !$0.isTarget }),
           let idx = nearestIndex(in: main.frequencies, to: f) {
            readout += String(format: "  %.1f dB", main.magnitudesDB[idx])
        }
        context.draw(
            Text(readout).font(.system(size: 10, design: .monospaced)).foregroundColor(.primary),
            at: CGPoint(x: min(location.x + 6, size.width - 60), y: 12), anchor: .leading)
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
            Canvas { context, size in
                drawWaveform(context: context, size: size)
                drawGate(context: context, size: size)
            }
            .background(Color(nsColor: .textBackgroundColor))
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
        }
    }

    private func sampleFor(x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, !samples.isEmpty else { return 0 }
        return min(max(Int(x / width * CGFloat(samples.count)), 0), samples.count - 1)
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        guard !samples.isEmpty else {
            context.draw(Text("No impulse response — run a measurement or load a .pir file.")
                .font(.callout).foregroundColor(.secondary),
                at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let peak = max(samples.map(abs).max() ?? 1, 1e-9)
        let mid = size.height / 2
        let columns = Int(size.width)
        let samplesPerColumn = max(1, samples.count / max(columns, 1))

        var path = Path()
        for col in 0..<columns {
            let start = col * samplesPerColumn
            guard start < samples.count else { break }
            let end = min(start + samplesPerColumn, samples.count)
            var lo: Float = 0
            var hi: Float = 0
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
        context.stroke(path, with: .color(.blue), lineWidth: 1)

        // Time axis labels.
        let totalMs = Double(samples.count) / sampleRate * 1000
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let ms = totalMs * fraction
            context.draw(
                Text(String(format: "%.0f ms", ms)).font(.system(size: 9)).foregroundColor(.secondary),
                at: CGPoint(x: CGFloat(fraction) * size.width + (fraction == 0 ? 20 : -24),
                            y: size.height - 8))
        }
    }

    private func drawGate(context: GraphicsContext, size: CGSize) {
        guard !samples.isEmpty else { return }
        let cursorX = CGFloat(cursorSample) / CGFloat(samples.count) * size.width
        var cursorPath = Path()
        cursorPath.move(to: CGPoint(x: cursorX, y: 0))
        cursorPath.addLine(to: CGPoint(x: cursorX, y: size.height))
        context.stroke(cursorPath, with: .color(.yellow), lineWidth: 1)

        if let marker = markerSample {
            let markerX = CGFloat(marker) / CGFloat(samples.count) * size.width
            var markerPath = Path()
            markerPath.move(to: CGPoint(x: markerX, y: 0))
            markerPath.addLine(to: CGPoint(x: markerX, y: size.height))
            context.stroke(markerPath, with: .color(.red), lineWidth: 1)

            if markerX > cursorX {
                let gateRect = CGRect(x: cursorX, y: 0, width: markerX - cursorX, height: size.height)
                context.fill(Path(gateRect), with: .color(.yellow.opacity(0.06)))
            }
            let gateMs = Double(marker - cursorSample) / sampleRate * 1000
            context.draw(
                Text(String(format: "gate %.1f ms", gateMs))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.orange),
                at: CGPoint(x: (cursorX + (markerX > cursorX ? markerX : cursorX)) / 2, y: 12))
        }
    }
}
