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
    static let combined = Color(red: 0.43, green: 0.56, blue: 0.91) // predicted sum
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
    /// The full audio span the axis defaults to, and the limits any zoom is
    /// clamped into. Shared with `AppModel`'s zoom state so "full range" means
    /// the same thing in both places.
    static let fullLow: Double = 20
    static let fullHigh: Double = 20_000

    /// Ignore a right-drag shorter than this — a stray right-click shouldn't
    /// zoom the axis into a sliver.
    private static let minDragPixels: CGFloat = 6

    let curves: [FRCurve]
    var showPhase = false
    var unwrapPhase = false
    var fLow: Double = FRPlotView.fullLow
    var fHigh: Double = FRPlotView.fullHigh
    var dbTop: Double = 20
    var dbRange: Double = 80
    /// Right-drag a band to zoom the frequency axis. Omit for a fixed-axis plot.
    var onZoomToRange: ((Double, Double) -> Void)? = nil
    /// Escape → back to full range. Returns true if there was a zoom to undo.
    var onResetZoom: (() -> Bool)? = nil

    @State private var hoverLocation: CGPoint? = nil
    @State private var dragBand: DragBand? = nil

    /// Pixel bounds of an in-progress right-drag selection.
    private struct DragBand {
        var start: CGFloat
        var current: CGFloat
    }

    /// Phase traces, one per curve that carries phase, clipped to the visible band
    /// and unwrapped if asked.
    ///
    /// Clipping *before* unwrapping is deliberate: outside the sweep band the
    /// deconvolution has nothing to divide by and returns noise, and unwrapping
    /// through that noise accumulates a bogus offset that corrupts the in-band
    /// slope. Restricting to what's on screen means zooming into the crossover
    /// also cleans up the unwrap.
    private var phaseTraces: [(color: Color, points: [(f: Double, deg: Double)])] {
        guard showPhase else { return [] }
        return curves.compactMap { curve in
            guard !curve.phaseDegrees.isEmpty else { return nil }
            let n = min(curve.frequencies.count, curve.phaseDegrees.count)
            var freqs: [Double] = []
            var raw: [Float] = []
            for i in 0..<n {
                let f = curve.frequencies[i]
                guard f >= fLow, f <= fHigh else { continue }
                freqs.append(f)
                raw.append(curve.phaseDegrees[i])
            }
            guard freqs.count > 1 else { return nil }
            let degs = unwrapPhase ? PhaseUnwrap.degrees(raw) : raw.map(Double.init)
            return (curve.color, Array(zip(freqs, degs)).map { (f: $0.0, deg: $0.1) })
        }
    }

    /// Phase axis bounds: fixed ±180° when wrapped, fitted to the data when
    /// unwrapped (rounded out to whole 90° steps so the gridlines stay meaningful).
    private var phaseBounds: (low: Double, high: Double) {
        guard unwrapPhase else { return (-180, 180) }
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        for trace in phaseTraces {
            for point in trace.points {
                low = min(low, point.deg)
                high = max(high, point.deg)
            }
        }
        guard low < high else { return (-180, 180) }
        let pad = max((high - low) * 0.08, 15)
        return (((low - pad) / 90).rounded(.down) * 90,
                ((high + pad) / 90).rounded(.up) * 90)
    }

    /// Up to 5 evenly-spaced labelled phase gridlines across whatever range is in use.
    private var phaseTicks: [Double] {
        let bounds = phaseBounds
        guard unwrapPhase else { return [180, 90, 0, -90, -180] }
        let span = bounds.high - bounds.low
        guard span > 0 else { return [0] }
        let step = max((span / 4 / 90).rounded() * 90, 90)
        return stride(from: bounds.low, through: bounds.high, by: step).map { $0 }
    }

    private let decadeTicks: [Double] = [
        20, 30, 40, 50, 60, 80, 100, 200, 300, 400, 500, 600, 800,
        1000, 2000, 3000, 4000, 5000, 6000, 8000, 10_000, 20_000
    ]
    private let labeledTicks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]

    /// Frequency gridlines for whatever span is visible, and whether each is
    /// labelled. The fixed decade set thins out badly once you zoom into a
    /// crossover — 60–90 Hz leaves a single tick and no label at all — so a
    /// narrow span falls back to evenly-spaced round numbers, all labelled.
    private var frequencyTicks: [(f: Double, labeled: Bool)] {
        let inSpan = decadeTicks.filter { $0 >= fLow && $0 <= fHigh }
        if inSpan.count >= 4 {
            return inSpan.map { ($0, labeledTicks.contains($0)) }
        }
        let target = (fHigh - fLow) / 5
        guard target > 0 else { return inSpan.map { ($0, true) } }
        let magnitude = pow(10, log10(target).rounded(.down))
        let step = [1.0, 2.0, 5.0, 10.0].first { magnitude * $0 >= target }.map { magnitude * $0 }
            ?? magnitude * 10
        var ticks: [(f: Double, labeled: Bool)] = []
        var f = (fLow / step).rounded(.up) * step
        while f <= fHigh {
            ticks.append((f, true))
            f += step
        }
        return ticks.isEmpty ? inSpan.map { ($0, true) } : ticks
    }

    /// Axis label for a frequency. Handles the zoomed-in cases the old
    /// `Int(f / 1000)` formatting got wrong — 1200 Hz read as "1k".
    private func tickLabel(_ f: Double) -> String {
        if f >= 1000 {
            let k = f / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return f == f.rounded() ? "\(Int(f))" : String(format: "%.1f", f)
    }

    var body: some View {
        PlotStyle.panel(
            Canvas { context, size in
                drawGrid(context: context, size: size)
                drawPhase(context: context, size: size)
                for curve in curves {
                    drawCurve(curve, context: context, size: size)
                }
                if let band = dragBand {
                    drawDragBand(band, context: context, size: size)
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
            .overlay(zoomGestureCatcher)
        )
    }

    @ViewBuilder
    private var zoomGestureCatcher: some View {
        if let onZoomToRange {
            DragZoomCatcher(
                onDragChanged: { start, current, _ in
                    dragBand = DragBand(start: start, current: current)
                },
                onDragEnded: { start, end, size in
                    dragBand = nil
                    guard size.width > 0, abs(end - start) >= Self.minDragPixels else { return }
                    onZoomToRange(fFor(min(start, end), size), fFor(max(start, end), size))
                },
                onEscape: { onResetZoom?() ?? false }
            )
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

    private func yForPhase(_ degrees: Double, _ size: CGSize) -> CGFloat {
        let bounds = phaseBounds
        let span = bounds.high - bounds.low
        guard span > 0 else { return size.height / 2 }
        return CGFloat((bounds.high - degrees) / span) * size.height
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        for tick in frequencyTicks {
            let x = xFor(tick.f, size)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(tick.labeled ? PlotStyle.gridMajor : PlotStyle.gridMinor),
                           lineWidth: tick.labeled ? 1 : 0.5)
            if tick.labeled {
                // Keep the label inside the plot: the rightmost tick (e.g. 20k)
                // sits on the edge, so anchor it trailing instead of leading.
                let nearRight = x > size.width - 24
                context.draw(
                    Text(tickLabel(tick.f)).font(PlotStyle.labelFont).foregroundColor(PlotStyle.label),
                    at: CGPoint(x: nearRight ? x - 3 : x + 3, y: size.height - 9),
                    anchor: nearRight ? .trailing : .leading)
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
        // Phase axis labels are neutral grey now that each phase trace takes its
        // own curve's colour — a single cyan axis would imply one cyan trace.
        if showPhase, !phaseTraces.isEmpty {
            let bounds = phaseBounds
            for deg in phaseTicks {
                let y = yForPhase(deg, size)
                guard y.isFinite else { continue }
                let nudge: CGFloat = deg >= bounds.high - 0.5 ? 8 : (deg <= bounds.low + 0.5 ? -8 : 0)
                context.draw(
                    Text("\(Int(deg))°").font(PlotStyle.labelFont)
                        .foregroundColor(PlotStyle.label.opacity(0.9)),
                    at: CGPoint(x: size.width - 4, y: y + nudge),
                    anchor: .trailing)
            }
        }
    }

    /// One dashed trace per curve carrying phase, in that curve's own colour, so
    /// two sources' phase can be followed independently through the crossover.
    /// Dashed vs solid is what separates phase from magnitude at the same colour.
    private func drawPhase(context: GraphicsContext, size: CGSize) {
        for trace in phaseTraces {
            var path = Path()
            var started = false
            var lastY: CGFloat? = nil
            for point in trace.points {
                let p = CGPoint(x: xFor(point.f, size), y: yForPhase(point.deg, size))
                guard p.y.isFinite else { continue }
                // Wrapped phase jumps the full plot height at ±180 — break the line
                // there rather than stroking a vertical bar across the graph.
                // Unwrapped phase is continuous, so it never needs breaking.
                if !unwrapPhase, started, let ly = lastY, abs(p.y - ly) > size.height * 0.5 {
                    started = false
                }
                if started {
                    path.addLine(to: p)
                } else {
                    path.move(to: p)
                    started = true
                }
                lastY = p.y
            }
            context.stroke(path, with: .color(trace.color.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.1, lineJoin: .round, dash: [3, 2]))
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
        let style = StrokeStyle(lineWidth: curve.isTarget || curve.isCombined ? 1.3 : 1.7,
                                lineJoin: .round,
                                dash: curve.isTarget ? [6, 3] : [])
        context.stroke(path, with: .color(curve.color), style: style)
    }

    /// The band being selected by an in-progress right-drag: a low-alpha fill so
    /// the traces underneath stay readable, hard edges, and a live Hz readout —
    /// you're picking a frequency window, so the numbers matter more than the box.
    private func drawDragBand(_ band: DragBand, context: GraphicsContext, size: CGSize) {
        let x0 = min(band.start, band.current)
        let x1 = max(band.start, band.current)
        guard x1 - x0 > 0.5 else { return }

        context.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                     with: .color(.white.opacity(0.10)))
        for x in [x0, x1] {
            var edge = Path()
            edge.move(to: CGPoint(x: x, y: 0))
            edge.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(edge, with: .color(PlotStyle.cursor), lineWidth: 1)
        }
        context.draw(
            Text("\(tickLabel(fFor(x0, size)))–\(tickLabel(fFor(x1, size))) Hz")
                .font(PlotStyle.readoutFont).foregroundColor(.white),
            at: CGPoint(x: (x0 + x1) / 2, y: size.height - 26), anchor: .center)
    }

    private func drawLegend(context: GraphicsContext, size: CGSize) {
        var y: CGFloat = 10
        var entries: [(String, Color, Bool)] = curves.map { ($0.name, $0.color, $0.isTarget) }
        // Phase shares each curve's colour, so the legend just explains the dashes.
        if !phaseTraces.isEmpty { entries.append(("phase (dashed)", PlotStyle.label, true)) }
        guard entries.count > 1 else { return }
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
            // Read phase off the same curve the dB figure came from, so the two
            // numbers under the cursor always describe one measurement.
            if showPhase, idx < main.phaseDegrees.count {
                readout += String(format: "  %.0f°", main.phaseDegrees[idx])
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
    /// Visible sample window (zoom/pan). Caller clamps these to valid bounds.
    let visibleStart: Int
    let visibleLength: Int
    var ampZoom: Double = 1
    var signalPeak: Float = 1
    // Frozen reference IR for delay comparison.
    var frozenSamples: [Float] = []
    var frozenPeak: Float = 1
    var frozenPeakIndex: Int = 0
    var currentPeakIndex: Int = 0
    var deltaMs: Double? = nil
    @Binding var cursorSample: Int
    @Binding var markerSample: Int?
    var onGateChanged: () -> Void
    var onZoom: (Double, Int) -> Void
    var onAmpZoom: (Double) -> Void = { _ in }
    var onPan: (Int) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            PlotStyle.panel(
                Canvas { context, size in
                    drawWaveform(context: context, size: size)
                    drawGate(context: context, size: size)
                    drawDelta(context: context, size: size)
                }
                .overlay(
                    ScrollZoomCatcher { dy, dx, precise, loc, size, shift in
                        let unit: Double = precise ? 0.006 : 0.15
                        if shift {
                            // Vertical (amplitude) magnification.
                            onAmpZoom(exp(Double(dy) * unit))
                        } else {
                            // Scroll up = zoom in, centred on the pointer.
                            let pivot = sampleFor(x: loc.x, width: size.width)
                            onZoom(exp(Double(-dy) * unit), pivot)
                            if abs(dx) > 0 {
                                onPan(Int(Double(dx) / size.width * Double(visibleLength)))
                            }
                        }
                    }
                )
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
                .simultaneousGesture(
                    MagnificationGesture()
                        .onEnded { scale in
                            // Pinch out (scale > 1) narrows the window = zoom in.
                            let pivot = visibleStart + visibleLength / 2
                            onZoom(1.0 / Double(scale), pivot)
                        }
                )
            )
        }
    }

    private func xFor(_ sample: Int, _ width: CGFloat) -> CGFloat {
        CGFloat(sample - visibleStart) / CGFloat(max(visibleLength, 1)) * width
    }

    private func clampY(_ y: CGFloat, _ height: CGFloat) -> CGFloat {
        min(max(y, 0), height)
    }

    private func sampleFor(x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, !samples.isEmpty else { return 0 }
        let s = visibleStart + Int(x / width * CGFloat(visibleLength))
        return min(max(s, 0), samples.count - 1)
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

        // Frozen reference trace (behind), then the current trace on top.
        if !frozenSamples.isEmpty {
            drawTrace(context: context, size: size, samples: frozenSamples,
                      peak: frozenPeak, color: PlotStyle.phase.opacity(0.55), lineWidth: 1)
        }
        drawTrace(context: context, size: size, samples: samples,
                  peak: signalPeak, color: PlotStyle.trace, lineWidth: 1)

        if ampZoom > 1.01 {
            context.draw(
                Text(String(format: "×%.0f", ampZoom)).font(PlotStyle.labelFont)
                    .foregroundColor(PlotStyle.label),
                at: CGPoint(x: size.width - 6, y: 10), anchor: .trailing)
        }

        // Time axis labels reflect the visible window.
        let winStart = min(max(visibleStart, 0), samples.count - 1)
        let winLen = max(min(visibleStart + visibleLength, samples.count) - winStart, 1)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let sample = Double(winStart) + Double(winLen) * fraction
            let ms = sample / sampleRate * 1000
            let anchor: UnitPoint = fraction == 0 ? .leading : fraction == 1 ? .trailing : .center
            let x = CGFloat(fraction) * size.width + (fraction == 0 ? 4 : fraction == 1 ? -4 : 0)
            context.draw(
                Text(String(format: "%.2f ms", ms)).font(PlotStyle.labelFont)
                    .foregroundColor(PlotStyle.label),
                at: CGPoint(x: x, y: size.height - 9), anchor: anchor)
        }
    }

    /// Draws one min/max waveform trace across the visible window.
    private func drawTrace(context: GraphicsContext, size: CGSize,
                           samples: [Float], peak: Float, color: Color, lineWidth: CGFloat) {
        guard !samples.isEmpty else { return }
        let mid = size.height / 2
        let pk = max(peak, 1e-9)
        let gain = CGFloat(ampZoom)
        let columns = max(Int(size.width), 1)
        let winStart = min(max(visibleStart, 0), samples.count - 1)
        let winEnd = min(winStart + visibleLength, samples.count)
        let winLen = max(winEnd - winStart, 1)
        let samplesPerColumn = Double(winLen) / Double(columns)

        var path = Path()
        for col in 0..<columns {
            let s0 = winStart + Int(Double(col) * samplesPerColumn)
            let s1 = winStart + Int(Double(col + 1) * samplesPerColumn)
            guard s0 < samples.count else { break }
            let end = min(max(s1, s0 + 1), samples.count)
            var lo = samples[s0]
            var hi = samples[s0]
            for i in s0..<end {
                lo = min(lo, samples[i])
                hi = max(hi, samples[i])
            }
            let x = CGFloat(col)
            let yHi = clampY(mid - CGFloat(hi / pk) * mid * 0.9 * gain, size.height)
            let yLo = clampY(mid - CGFloat(lo / pk) * mid * 0.9 * gain, size.height)
            path.move(to: CGPoint(x: x, y: yHi))
            path.addLine(to: CGPoint(x: x, y: max(yLo, yHi + 0.5)))
        }
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    /// Marks the frozen reference arrival and calls out the delay difference.
    private func drawDelta(context: GraphicsContext, size: CGSize) {
        guard !frozenSamples.isEmpty, let delta = deltaMs else { return }
        let refX = xFor(frozenPeakIndex, size.width)
        if refX >= 0, refX <= size.width {
            var line = Path()
            line.move(to: CGPoint(x: refX, y: 0))
            line.addLine(to: CGPoint(x: refX, y: size.height))
            context.stroke(line, with: .color(PlotStyle.phase),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            context.draw(
                Text("ref").font(PlotStyle.labelFont).foregroundColor(PlotStyle.phase),
                at: CGPoint(x: refX + 3, y: 22), anchor: .leading)
        }
        let curX = xFor(currentPeakIndex, size.width)
        let distance = Acoustics.distanceMeters(forDeltaMs: abs(delta))
        let text = String(format: "Δ %.2f ms   %.2f m", delta, distance)
        let cx = min(max((refX + curX) / 2, 70), size.width - 70)
        context.draw(
            Text(text).font(PlotStyle.readoutFont).foregroundColor(.white),
            at: CGPoint(x: cx, y: 38), anchor: .center)
    }

    private func drawGate(context: GraphicsContext, size: CGSize) {
        guard !samples.isEmpty else { return }
        let cursorX = xFor(cursorSample, size.width)
        if cursorX >= 0, cursorX <= size.width {
            var cursorPath = Path()
            cursorPath.move(to: CGPoint(x: cursorX, y: 0))
            cursorPath.addLine(to: CGPoint(x: cursorX, y: size.height))
            context.stroke(cursorPath, with: .color(PlotStyle.trace.opacity(0.9)), lineWidth: 1)
        }

        if let marker = markerSample {
            let markerX = xFor(marker, size.width)
            if markerX >= 0, markerX <= size.width {
                var markerPath = Path()
                markerPath.move(to: CGPoint(x: markerX, y: 0))
                markerPath.addLine(to: CGPoint(x: markerX, y: size.height))
                context.stroke(markerPath, with: .color(PlotStyle.target), lineWidth: 1)
            }

            // Fill the gate region (clipped to the visible plot).
            let gateLo = max(min(cursorX, markerX), 0)
            let gateHi = min(max(cursorX, markerX), size.width)
            if gateHi > gateLo {
                let gateRect = CGRect(x: gateLo, y: 0, width: gateHi - gateLo, height: size.height)
                context.fill(Path(gateRect), with: .color(PlotStyle.gateFill))
            }
            let gateMs = Double(marker - cursorSample) / sampleRate * 1000
            context.draw(
                Text(String(format: "gate %.2f ms", gateMs))
                    .font(PlotStyle.readoutFont).foregroundColor(PlotStyle.trace),
                at: CGPoint(x: min(max((gateLo + gateHi) / 2, 40), size.width - 40), y: 12))
        }
    }
}
