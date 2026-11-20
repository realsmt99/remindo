import SwiftUI

/// Geometry of the Claude-style spark: twelve tapered, slightly irregular rays.
/// Plain CGPaths so the same shape draws in SwiftUI, the menu bar icon and the app icon.
enum SparkGeometry {
    static let rayCount = 12
    static let lengths: [CGFloat] = [1.00, 0.80, 0.94, 0.76, 0.97, 0.84, 0.92, 0.78, 1.00, 0.82, 0.90, 0.77]
    static let widths: [CGFloat] = [1.00, 0.90, 1.05, 0.88, 1.00, 0.95, 1.02, 0.86, 0.98, 0.92, 1.04, 0.90]
    static let jitter: [Double] = [0.00, 0.06, -0.04, 0.05, -0.03, 0.04, -0.06, 0.03, 0.02, -0.05, 0.05, -0.02]

    static func paths(center c: CGPoint, radius r: CGFloat, rotation: Double, scale: CGFloat,
                      length: (Int) -> CGFloat) -> [CGPath] {
        var out: [CGPath] = []
        out.reserveCapacity(rayCount + 1)
        for i in 0..<rayCount {
            let angle = Double(i) / Double(rayCount) * 2 * .pi + jitter[i] + rotation - .pi / 2
            let l = r * lengths[i] * length(i) * scale
            let w0 = r * 0.27 * widths[i] * scale
            let w1 = r * 0.125 * widths[i] * scale
            out.append(ray(center: c, angle: angle, length: l, baseWidth: w0, tipWidth: w1))
        }
        let core = r * 0.19 * scale
        out.append(CGPath(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2),
                          transform: nil))
        return out
    }

    private static func ray(center c: CGPoint, angle a: Double, length l: CGFloat,
                            baseWidth w0: CGFloat, tipWidth w1: CGFloat) -> CGPath {
        let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
        let px = -dy, py = dx  // perpendicular (angle + 90°)
        let tip = CGPoint(x: c.x + dx * l, y: c.y + dy * l)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x + px * w0 / 2, y: c.y + py * w0 / 2))
        p.addLine(to: CGPoint(x: tip.x + px * w1 / 2, y: tip.y + py * w1 / 2))
        // Round the tip: sweep from +90° to -90° through the ray's own direction.
        p.addArc(center: tip, radius: w1 / 2, startAngle: CGFloat(a + .pi / 2), endAngle: CGFloat(a - .pi / 2),
                 clockwise: true)
        p.addLine(to: CGPoint(x: c.x - px * w0 / 2, y: c.y - py * w0 / 2))
        p.closeSubpath()
        return p
    }
}

/// Draws one animation frame of the spark for a given state.
enum SparkPainter {
    static func heartbeat(_ t: Double) -> Double {
        let p = t.truncatingRemainder(dividingBy: 1.4) / 1.4
        func bump(_ c: Double, _ w: Double) -> Double { exp(-pow((p - c) / w, 2)) }
        return min(1, bump(0.12, 0.05) + 0.7 * bump(0.32, 0.06))
    }

    static func paint(_ ctx: inout GraphicsContext, canvas: CGSize, sparkSize: CGFloat, time t: Double,
                      state: AgentState, tint: Color, burst: Double?) {
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let r = sparkSize / 2

        var rotation = 0.0
        var scale: CGFloat = 1
        switch state {
        case .working:
            rotation = t * 1.25
        case .approval:
            let hb = heartbeat(t)
            rotation = sin(t * 9) * 0.07 * hb
            scale = 1 + 0.06 * CGFloat(hb)
        case .waiting:
            rotation = sin(t * 1.1) * 0.3
            scale = 1 + 0.035 * CGFloat(sin(t * 2.4))
        case .done:
            rotation = t * 0.2
        case .error:
            // A short shake when the error arrives, then still.
            if let b = burst { rotation = sin(b * 40) * 0.16 * (1 - b) }
        case .idle:
            rotation = 0.1
        }
        if state == .done, let b = burst { scale *= 1 + 0.3 * CGFloat(sin(min(b, 1) * .pi)) }

        // Aura / rings behind the spark.
        switch state {
        case .working:
            let a = 0.20 + 0.12 * sin(t * 3)
            let rect = CGRect(x: c.x - r * 1.6, y: c.y - r * 1.6, width: r * 3.2, height: r * 3.2)
            ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [tint.opacity(a), tint.opacity(0)]), center: c, startRadius: r * 0.2, endRadius: r * 1.6))
        case .approval:
            let hb = heartbeat(t)
            ring(&ctx, c, r * (1.2 + 0.12 * hb), Palette.amber.opacity(0.5 + 0.5 * hb), width: max(1, r * 0.09))
            let ripple = (t / 1.4).truncatingRemainder(dividingBy: 1)
            ring(&ctx, c, r * (1.15 + 0.75 * ripple), Palette.amber.opacity(0.55 * (1 - ripple)), width: max(0.8, r * 0.06))
        case .waiting:
            let b = 0.5 + 0.5 * sin(t * 2.2)
            ring(&ctx, c, r * (1.18 + 0.08 * b), Palette.blue.opacity(0.35 + 0.4 * b), width: max(1, r * 0.08))
        case .done:
            ring(&ctx, c, r * 1.18, Palette.green.opacity(0.35), width: max(1, r * 0.06))
        case .error:
            ring(&ctx, c, r * 1.18, Palette.red.opacity(0.45), width: max(1, r * 0.07))
        case .idle:
            break
        }

        // "Finished cooking" burst: shockwave and confetti.
        if state == .done, let b = burst {
            let e = 1 - pow(1 - b, 3)
            ring(&ctx, c, r * (0.9 + 1.0 * e), Palette.green.opacity(0.8 * (1 - b)), width: max(0.6, r * 0.14 * (1 - b)))
            for k in 0..<10 {
                let angle = Double(k) / 10 * 2 * .pi + 0.3
                let d = r * (1.0 + 0.85 * e)
                let pr = r * 0.09 * (1 - b)
                let pt = CGPoint(x: c.x + CGFloat(cos(angle)) * d, y: c.y + CGFloat(sin(angle)) * d)
                let color: Color = k % 3 == 0 ? Palette.amber : (k % 2 == 0 ? tint : Palette.green)
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - pr, y: pt.y - pr, width: pr * 2, height: pr * 2)), with: .color(color))
            }
        }

        // The spark itself.
        let rays = SparkGeometry.paths(center: c, radius: r, rotation: rotation, scale: scale) { i in
            lengthFactor(state: state, t: t, ray: i)
        }
        for ray in rays { ctx.fill(Path(ray), with: .color(tint)) }

        // State badge, bottom-right.
        let badgeCenter = CGPoint(x: c.x + r * 0.8, y: c.y + r * 0.8)
        switch state {
        case .done: badge(&ctx, at: badgeCenter, radius: r * 0.42, fill: Palette.green, glyph: .check)
        case .error: badge(&ctx, at: badgeCenter, radius: r * 0.42, fill: Palette.red, glyph: .bang)
        case .approval: badge(&ctx, at: badgeCenter, radius: r * 0.42, fill: Palette.amber, glyph: .bang)
        case .waiting: badge(&ctx, at: badgeCenter, radius: r * 0.42, fill: Palette.blue, glyph: .dots)
        case .working, .idle: break
        }
    }

    private static func lengthFactor(state: AgentState, t: Double, ray i: Int) -> CGFloat {
        switch state {
        case .working: return 0.72 + 0.28 * CGFloat(0.5 + 0.5 * sin(t * 5.0 - Double(i) * 0.85))
        case .approval: return 0.86 + 0.14 * CGFloat(heartbeat(t))
        case .waiting: return 0.86 + 0.10 * CGFloat(0.5 + 0.5 * sin(t * 2.0 + Double(i) * 0.6))
        case .done: return 0.94 + 0.05 * CGFloat(sin(t * 2.4 + Double(i)))
        case .error: return 0.84
        case .idle: return 0.92
        }
    }

    private static func ring(_ ctx: inout GraphicsContext, _ c: CGPoint, _ radius: CGFloat, _ color: Color, width: CGFloat) {
        let rect = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
        ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: width)
    }

    private enum Glyph { case check, bang, dots }

    private static func badge(_ ctx: inout GraphicsContext, at c: CGPoint, radius r: CGFloat, fill: Color, glyph: Glyph) {
        let outer = r * 1.22
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2)), with: .color(.black))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(fill))
        let ink = Color.black.opacity(0.82)
        switch glyph {
        case .check:
            var p = Path()
            p.move(to: CGPoint(x: c.x - r * 0.45, y: c.y + r * 0.02))
            p.addLine(to: CGPoint(x: c.x - r * 0.12, y: c.y + r * 0.34))
            p.addLine(to: CGPoint(x: c.x + r * 0.48, y: c.y - r * 0.32))
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1, r * 0.3), lineCap: .round, lineJoin: .round))
        case .bang:
            let w = r * 0.26
            ctx.fill(Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - r * 0.58, width: w, height: r * 0.72), cornerRadius: w / 2),
                     with: .color(ink))
            let d = r * 0.14
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d, y: c.y + r * 0.3, width: d * 2, height: d * 2)), with: .color(ink))
        case .dots:
            let d = r * 0.13
            for dx in [-0.4, 0.0, 0.4] {
                let x = c.x + r * CGFloat(dx)
                ctx.fill(Path(ellipseIn: CGRect(x: x - d, y: c.y - d, width: d * 2, height: d * 2)), with: .color(ink))
            }
        }
    }
}

/// The animated Claude spark. `size` is the spark; the canvas is twice that so rings,
/// badges and the "done" burst have room to breathe.
struct SparkView: View {
    var state: AgentState
    var size: CGFloat
    var tint: Color = Palette.claude
    var animated = true
    /// Play the one-shot burst/shake when this view appears already finished. State changes
    /// while visible always play it.
    var celebrateOnAppear = true
    /// Render a fixed frame (snapshots, icons).
    var fixedTime: Double?
    var fixedBurst: Double?

    /// Start of the one-shot "done" burst / "error" shake.
    @State private var burstStart: Date?
    /// Approval/question sparks pulse for a while, then hold still (they can wait for hours).
    @State private var calm = false
    private static let burstDuration = 1.1

    var body: some View {
        Group {
            if let fixedTime {
                canvas(time: fixedTime, burst: fixedBurst)
            } else {
                // Small sparks (the compact wings) don't need 60 fps; finished/idle ones sit still
                // once their one-shot animation is over, so a waiting reminder costs ~nothing.
                TimelineView(.animation(minimumInterval: size < 24 ? 1.0 / 30.0 : 1.0 / 60.0,
                                        paused: !animated || !isMoving)) { context in
                    canvas(time: context.date.timeIntervalSinceReferenceDate, burst: burstProgress(at: context.date))
                }
            }
        }
        .frame(width: size * 2, height: size * 2)
        .frame(width: size, height: size)
        .onAppear {
            if celebrateOnAppear && (state == .done || state == .error) { burstStart = Date() }
        }
        .onChange(of: state) { _, newState in
            if newState == .done || newState == .error { burstStart = Date() }
        }
        .task(id: burstStart) {
            guard burstStart != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64((Self.burstDuration + 0.15) * 1_000_000_000))
            if !Task.isCancelled { burstStart = nil }
        }
        .task(id: state) {
            calm = false
            guard state == .approval || state == .waiting else { return }
            try? await Task.sleep(nanoseconds: UInt64(NotchViewModel.calmAfter * 1_000_000_000))
            if !Task.isCancelled { calm = true }
        }
        .allowsHitTesting(false)
    }

    private var isMoving: Bool {
        switch state {
        case .working: return true
        case .approval, .waiting: return !calm
        case .done, .error: return burstStart != nil
        case .idle: return false
        }
    }

    private func canvas(time: Double, burst: Double?) -> some View {
        Canvas { ctx, canvasSize in
            SparkPainter.paint(&ctx, canvas: canvasSize, sparkSize: size, time: time, state: state, tint: tint, burst: burst)
        }
    }

    private func burstProgress(at date: Date) -> Double? {
        guard let start = burstStart else { return nil }
        let p = date.timeIntervalSince(start) / Self.burstDuration
        return (0..<1).contains(p) ? p : nil
    }
}
