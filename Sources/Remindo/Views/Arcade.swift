import SwiftUI

/// Retro pixel-arcade look: Claude's spark as a chomping sprite running a dotted lane,
/// chased by a crew of pixel bugs. Original sprites, drawn from tiny character maps.
enum PixelArt {
    /// The spark, "open" frame (rays pointing straight out).
    static let sparkA = [
        "....#....",
        "....#....",
        "..#.#.#..",
        "...###...",
        "#########",
        "...###...",
        "..#.#.#..",
        "....#....",
        "....#....",
    ]
    /// The spark, "chomp" frame (rays swing diagonal).
    static let sparkB = [
        "#.......#",
        ".#..#..#.",
        "..#.#.#..",
        "...###...",
        ".#######.",
        "...###...",
        "..#.#.#..",
        ".#..#..#.",
        "#.......#",
    ]
    /// A little beetle-bug, legs out.
    static let bugA = [
        ".#....#.",
        "..#..#..",
        ".######.",
        "#o##o###",
        "########",
        ".######.",
        "#.#..#.#",
        "#......#",
    ]
    /// Legs in.
    static let bugB = [
        "..#..#..",
        "..#..#..",
        ".######.",
        "##o##o##",
        "########",
        ".######.",
        ".#.##.#.",
        "..#..#..",
    ]
    /// A twinkle left behind when a bug is cleared.
    static let twinkle = [
        "..#..",
        ".###.",
        "#####",
        ".###.",
        "..#..",
    ]

    static func size(_ rows: [String]) -> CGSize {
        CGSize(width: rows.first?.count ?? 0, height: rows.count)
    }

    static func draw(_ rows: [String], _ ctx: inout GraphicsContext, at origin: CGPoint, pixel p: CGFloat,
                     colors: [Character: Color]) {
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let color = colors[ch] else { continue }
                let rect = CGRect(x: (origin.x + CGFloat(x) * p).rounded(), y: (origin.y + CGFloat(y) * p).rounded(),
                                  width: p.rounded(.up), height: p.rounded(.up))
                ctx.fill(Path(rect), with: .color(color))
            }
        }
    }

    static let bugColors: [Color] = [
        Color(red: 0.30, green: 0.86, blue: 0.80),  // teal
        Color(red: 1.00, green: 0.55, blue: 0.76),  // pink
        Color(red: 0.62, green: 0.52, blue: 1.00),  // violet
    ]
}

/// Claude's spark as a pixel sprite. Chomps while working, blinks while waiting on you.
struct PixelSpark: View {
    var state: AgentState
    var size: CGFloat
    var tint: Color = Palette.claude
    var animated = true

    var body: some View {
        let moving = animated && (state == .working || state == .approval || state == .waiting)
        TimelineView(.animation(minimumInterval: 0.16, paused: !moving)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.16)
            Canvas { ctx, sz in
                let rows = state == .working && tick % 2 == 1 ? PixelArt.sparkB : PixelArt.sparkA
                let p = max(1, floor(min(sz.width, sz.height) / 9))
                let origin = CGPoint(x: (sz.width - p * 9) / 2, y: (sz.height - p * 9) / 2)
                var color = tint
                switch state {
                case .approval, .waiting:
                    if tick % 4 >= 2 { color = state.accent }  // blink between coral and the state color
                case .error:
                    color = Color(white: 0.55)
                default:
                    break
                }
                PixelArt.draw(rows, &ctx, at: origin, pixel: p, colors: ["#": color])
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

/// The lane under the peek card: dots, the spark running, bugs chasing.
struct ArcadeStrip: View {
    var state: AgentState
    var tint: Color = Palette.claude

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, sz in
                Self.paint(&ctx, size: sz, t: t, state: state, tint: tint)
            }
        }
        .allowsHitTesting(false)
    }

    static func paint(_ ctx: inout GraphicsContext, size sz: CGSize, t: Double, state: AgentState, tint: Color) {
        let p: CGFloat = 2
        let midY = sz.height / 2
        let sparkW = 9 * p, bugW = 8 * p
        let spacing: CGFloat = 12
        let frame = Int(t / 0.16) % 2

        // Where the spark is along the lane.
        let loop = sz.width + 120
        var sparkX: CGFloat
        switch state {
        case .working:
            sparkX = CGFloat((t * 60).truncatingRemainder(dividingBy: Double(loop))) - 60
        case .done:
            sparkX = sz.width - sparkW - 6
        default:
            sparkX = sz.width * 0.5 - sparkW / 2
        }

        // Dots: eaten behind the spark (all eaten once the level is clear).
        var x: CGFloat = 6
        while x < sz.width - 4 {
            let eaten = state == .done || x < sparkX + sparkW / 2
            if !eaten {
                let d: CGFloat = 3
                ctx.fill(Path(CGRect(x: x, y: midY - d / 2, width: d, height: d)),
                         with: .color(Color(red: 1, green: 0.84, blue: 0.7).opacity(0.85)))
            }
            x += spacing
        }

        // The crew.
        for (i, color) in PixelArt.bugColors.enumerated() {
            let bx = sparkX - CGFloat(i + 1) * (bugW + 12) - 4
            let by = midY - bugW / 2 + (state == .working ? CGFloat(((frame + i) % 2)) : 0)
            switch state {
            case .done:
                // Level clear: the bugs turn into twinkles.
                let tw = 0.5 + 0.5 * sin(t * 6 + Double(i))
                PixelArt.draw(PixelArt.twinkle, &ctx, at: CGPoint(x: sz.width * 0.2 + CGFloat(i) * 46, y: midY - 5),
                              pixel: p, colors: ["#": color.opacity(0.35 + 0.65 * tw)])
            case .error:
                // Game over: they've caught the spark.
                let gx = sparkX + (i == 1 ? sparkW + 4 : -bugW - 4 - CGFloat(i) * 2)
                PixelArt.draw(i == 0 ? PixelArt.bugA : PixelArt.bugB, &ctx, at: CGPoint(x: gx, y: midY - bugW / 2),
                              pixel: p, colors: ["#": color, "o": .white])
            case .approval, .waiting:
                // Paused: everyone frozen, the crew politely waiting.
                PixelArt.draw(PixelArt.bugA, &ctx, at: CGPoint(x: bx, y: midY - bugW / 2), pixel: p,
                              colors: ["#": color.opacity(0.75), "o": .white])
            default:
                PixelArt.draw(frame == 0 ? PixelArt.bugA : PixelArt.bugB, &ctx, at: CGPoint(x: bx, y: by), pixel: p,
                              colors: ["#": color, "o": .white])
            }
        }

        // The spark.
        var sparkColor = tint
        if state == .approval || state == .waiting, frame == 1 { sparkColor = state.accent }
        if state == .error { sparkColor = Color(white: 0.55) }
        let rows = state == .working && frame == 1 ? PixelArt.sparkB : PixelArt.sparkA
        PixelArt.draw(rows, &ctx, at: CGPoint(x: sparkX, y: midY - sparkW / 2), pixel: p, colors: ["#": sparkColor])
    }
}

extension StatusText {
    /// Big arcade headline.
    static func arcadeTitle(_ s: AgentSession, kind: PeekKind) -> String {
        if let custom = s.customTitle, s.state != .working { return custom.uppercased() }
        switch s.state {
        case .working: return kind == .leftWhileWorking ? "STILL \(s.verb.uppercased())..." : "\(s.verb.uppercased())..."
        case .approval: return "PRESS OK TO CONTINUE"
        case .waiting: return s.persistent ? "YOUR MOVE" : "PLAYER 1 READY?"
        case .done: return "LEVEL CLEAR!"
        case .error: return "GAME OVER"
        case .idle: return "PAUSED"
        }
    }
}

extension Font {
    /// Chunky, blocky lettering for the arcade look.
    static func arcade(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .monospaced) }
}
