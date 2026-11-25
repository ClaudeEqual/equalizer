import SwiftUI

/// The sound graph: live spectrum of what is playing, the real EQ curve on top, and the points.
/// In parametric mode the points can be dragged; a double-click on an empty spot adds a point.
struct CurveView: View {
    @ObservedObject var model: EQModel
    @ObservedObject var live: LiveData
    @State private var dragging: UUID? = nil

    private let dbRange = 30.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, sz in
                    draw(in: &ctx, size: sz)
                }
                if model.settings.mode == .parametric {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture(size: size))
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2).onEnded { v in
                                if nearestBand(to: v.location, size: size) == nil {
                                    let g = (db(atY: v.location.y, height: size.height) * 2).rounded() / 2
                                    model.addBand(frequency: freq(atX: v.location.x, width: size.width), gain: g)
                                }
                            }
                        )
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("График звучания: слева бас, справа высокие")
    }

    // MARK: Geometry

    private func x(_ f: Double, width: CGFloat) -> CGFloat {
        CGFloat(log(f / 20) / log(1000)) * width
    }

    private func y(_ db: Double, height: CGFloat) -> CGFloat {
        let half = height / 2
        return half - CGFloat(max(-dbRange, min(dbRange, db)) / dbRange) * (half - 12)
    }

    private func freq(atX px: CGFloat, width: CGFloat) -> Double {
        let t = Double(max(0, min(width, px)) / max(width, 1))
        return 20 * pow(1000, t)
    }

    private func db(atY py: CGFloat, height: CGFloat) -> Double {
        let half = height / 2
        let v = Double((half - py) / max(half - 12, 1)) * dbRange
        return max(-24, min(24, v))
    }

    private func pointY(_ b: ParamBand, height: CGFloat) -> CGFloat {
        (b.kind == .highPass || b.kind == .lowPass) ? y(0, height: height) : y(b.gain, height: height)
    }

    private func nearestBand(to p: CGPoint, size: CGSize) -> UUID? {
        var best: (UUID, CGFloat)? = nil
        for b in model.settings.bands {
            let dx = x(b.frequency, width: size.width) - p.x
            let dy = pointY(b, height: size.height) - p.y
            let d = sqrt(dx * dx + dy * dy)
            if d < 20 && (best == nil || d < best!.1) { best = (b.id, d) }
        }
        return best?.0
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragging == nil {
                    dragging = nearestBand(to: g.startLocation, size: size)
                    if let id = dragging { model.selectedBand = id }
                }
                guard let id = dragging else { return }
                let f = freq(atX: g.location.x, width: size.width)
                let d = (db(atY: g.location.y, height: size.height) * 2).rounded() / 2
                model.updateBand(id) { b in
                    b.frequency = (f * 10).rounded() / 10
                    if b.kind != .highPass && b.kind != .lowPass { b.gain = d }
                }
            }
            .onEnded { _ in dragging = nil }
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let gridColor = Color.white.opacity(0.06)
        let labelColor = Theme.muted

        // Spectrum of what is playing
        let spec = live.spectrum
        if !spec.isEmpty {
            var bars = Path()
            let n = spec.count
            for i in 0..<n {
                let x0 = w * CGFloat(i) / CGFloat(n)
                let x1 = w * CGFloat(i + 1) / CGFloat(n)
                let level = CGFloat(max(0, min(1, (spec[i] + 90) / 90)))
                let barH = level * h * 0.85
                if barH > 0.5 {
                    bars.addRect(CGRect(x: x0 + 0.5, y: h - barH, width: max(x1 - x0 - 1, 0.5), height: barH))
                }
            }
            ctx.fill(bars, with: .color(Color.white.opacity(0.06)))
        }

        // Grid
        for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            let px = x(f, width: w)
            var p = Path()
            p.move(to: CGPoint(x: px, y: 0))
            p.addLine(to: CGPoint(x: px, y: h))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 1)
            ctx.draw(Text(EQModel.label(f)).font(.system(size: 10)).foregroundColor(labelColor),
                     at: CGPoint(x: px + 3, y: h - 8), anchor: .leading)
        }
        for d in [-24.0, -12, 12, 24] {
            let py = y(d, height: h)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: py))
            p.addLine(to: CGPoint(x: w, y: py))
            ctx.stroke(p, with: .color(gridColor), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
            ctx.draw(Text(d > 0 ? "+\(Int(d))" : "\(Int(d))").font(.system(size: 10)).foregroundColor(labelColor),
                     at: CGPoint(x: 4, y: py - 7), anchor: .leading)
        }
        let zeroY = y(0, height: h)
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: zeroY))
        zero.addLine(to: CGPoint(x: w, y: zeroY))
        ctx.stroke(zero, with: .color(Color.white.opacity(0.18)), lineWidth: 1)

        // The real response curve
        let curve = model.curve
        let freqs = EQModel.curveFrequencies
        if curve.count == freqs.count, !curve.isEmpty {
            var line = Path()
            for i in 0..<curve.count {
                let pt = CGPoint(x: x(freqs[i], width: w), y: y(curve[i], height: h))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            var area = line
            area.addLine(to: CGPoint(x: w, y: zeroY))
            area.addLine(to: CGPoint(x: 0, y: zeroY))
            area.closeSubpath()
            let active = model.isOn && !model.comparing
            ctx.fill(area, with: .color(Theme.accent.opacity(active ? 0.15 : 0.05)))
            ctx.stroke(line, with: .color(Theme.accent.opacity(active ? 1 : 0.35)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }

        // Points
        switch model.settings.mode {
        case .graphic:
            let n = model.settings.bandCount
            let fs = EQModel.frequencies(for: n)
            let r: CGFloat = n <= 15 ? 4 : (n <= 20 ? 3 : 2)
            for i in 0..<min(n, model.settings.gains.count) {
                let c = CGPoint(x: x(fs[i], width: w), y: y(model.settings.gains[i], height: h))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Color.white.opacity(0.85)))
            }
        case .parametric:
            for (i, b) in model.settings.bands.enumerated() {
                let selected = b.id == model.selectedBand
                let r: CGFloat = selected ? 11 : 9
                let c = CGPoint(x: x(b.frequency, width: w), y: pointY(b, height: h))
                let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(circle, with: .color(selected ? Theme.accent : Color(white: 0.8)))
                ctx.stroke(circle, with: .color(Theme.bg), lineWidth: 2)
                ctx.draw(Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.bg),
                         at: c, anchor: .center)
            }
        }
    }
}
