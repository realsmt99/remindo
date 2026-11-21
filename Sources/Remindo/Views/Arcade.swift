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

    /// The spark-muncher: a spiky coral body with an eye; the mouth is a wedge cut on the right.
    static let muncherBody = [
        ".#..#..#.",
        "..#####..",
        "#.#####.#",
        ".#######.",
        "#########",
        ".#######.",
        "#.#####.#",
        "..#####..",
        ".#..#..#.",
    ]

    private static var muncherCache: [Int: [String]] = [:]

    /// `open` 0 (closed) to 1 (wide), quantized to a few frames for a crisp pixel look.
    static func muncher(open: Double) -> [String] {
        let level = max(0, min(3, Int((open * 3).rounded())))
        if let cached = muncherCache[level] { return cached }
        let slope = Double(level) / 3 * 1.1
        let rows = muncherBody.enumerated().map { (y, row) -> String in
            String(row.enumerated().map { (x, ch) -> Character in
                let dx = x - 4, dy = abs(y - 4)
                if level > 0 && dx >= 1 && Double(dy) <= Double(dx) * slope { return "." }
                if x == 4 && y == 2 { return "e" }  // the eye
                return ch
            })
        }
        muncherCache[level] = rows
        return rows
    }

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
        TimelineView(.animation(minimumInterval: 0.09, paused: !moving)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.09)
            Canvas { ctx, sz in
                let chomp = [0.0, 0.5, 1.0, 0.5]
                let rows = PixelArt.muncher(open: state == .working ? chomp[tick % 4] : 0)
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
                PixelArt.draw(rows, &ctx, at: origin, pixel: p, colors: ["#": color, "e": .black])
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

/// The lane under the peek card: a little arcade level. The spark-muncher eats its way
/// along the dots, power pellets send the bug crew fleeing, the score ticks up.
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

    private static let speed: Double = 62          // points per second
    private static let spacing: CGFloat = 12       // between dots
    private static let laneStart: CGFloat = 62     // room for the score on the left
    private static let pelletEvery = 14            // a couple of power pellets per lane

    static func paint(_ ctx: inout GraphicsContext, size sz: CGSize, t: Double, state: AgentState, tint: Color) {
        let p: CGFloat = 2
        let midY = sz.height / 2
        let body = 9 * p, bugW = 8 * p
        let dotXs = stride(from: laneStart, to: sz.width - 6, by: spacing).map { $0 }
        let frame = Int(t / 0.16) % 2

        // Where the muncher is: running the lane while working, resting otherwise.
        let loop = Double(sz.width - laneStart + 140)
        let run = t * speed
        var x: CGFloat
        switch state {
        case .working: x = laneStart - 70 + CGFloat(run.truncatingRemainder(dividingBy: loop))
        case .done: x = sz.width - body - 4
        default: x = laneStart + (sz.width - laneStart) * 0.45
        }
        let mouth = x + body * 0.62           // dots disappear when they reach the mouth
        let level = Int(run / loop)

        // Dots and pellets; remember what was eaten and when (for pops and the score).
        var score = 0
        var lastPelletAge: Double?
        for (i, dx) in dotXs.enumerated() {
            let isPellet = i % pelletEvery == pelletEvery / 2
            let eaten = state == .done || (state == .working && dx < mouth)
            if eaten {
                score += isPellet ? 50 : 10
                let age = Double(mouth - dx) / speed
                if state == .working && age < 0.22 { pop(&ctx, at: CGPoint(x: dx + 1.5, y: midY), age: age / 0.22, pellet: isPellet) }
                if isPellet && state == .working {
                    lastPelletAge = min(lastPelletAge ?? .infinity, age)
                    if age < 0.7 {  // "+50" floats up
                        let rise = CGFloat(age / 0.7)
                        ctx.draw(Text("+50").font(.arcade(8)).foregroundColor(Palette.amber.opacity(1 - Double(rise))),
                                 at: CGPoint(x: dx, y: midY - 6 - rise * 8))
                    }
                }
                continue
            }
            if isPellet {
                let blink = Int(t * 4) % 2 == 0
                let r: CGFloat = 3.5
                ctx.fill(Path(ellipseIn: CGRect(x: dx - r + 1.5, y: midY - r, width: r * 2, height: r * 2)),
                         with: .color(Palette.claude.opacity(blink ? 1 : 0.45)))
            } else {
                ctx.fill(Path(CGRect(x: dx, y: midY - 1.5, width: 3, height: 3)),
                         with: .color(Color(red: 1, green: 0.84, blue: 0.7).opacity(0.85)))
            }
        }
        if state == .working { score += (level % 40) * dotXs.count * 10 + level * 0 }

        // Score, arcade style.
        let label = state == .done ? "CLEAR" : String(format: "1UP %04d", score)
        ctx.draw(Text(label).font(.arcade(8.5)).foregroundColor(state == .done ? Palette.green : .white.opacity(0.75)),
                 at: CGPoint(x: 2, y: midY), anchor: .leading)

        // The bug crew.
        let scared = state == .working && (lastPelletAge ?? .infinity) < 1.8
        for (i, color) in PixelArt.bugColors.enumerated() {
            var bx = x - CGFloat(i + 1) * (bugW + 10) - 6
            let wobble = CGFloat((frame + i) % 2)
            switch state {
            case .done:
                let tw = 0.5 + 0.5 * sin(t * 6 + Double(i))
                PixelArt.draw(PixelArt.twinkle, &ctx, at: CGPoint(x: laneStart + 30 + CGFloat(i) * 52, y: midY - 5),
                              pixel: p, colors: ["#": color.opacity(0.35 + 0.65 * tw)])
            case .error:
                let gx = x + (i == 1 ? body + 3 : -bugW - 3 - CGFloat(i) * 3)
                PixelArt.draw(PixelArt.bugA, &ctx, at: CGPoint(x: gx, y: midY - bugW / 2), pixel: p,
                              colors: ["#": color, "o": .white])
            case .approval, .waiting:
                PixelArt.draw(PixelArt.bugA, &ctx, at: CGPoint(x: bx, y: midY - bugW / 2), pixel: p,
                              colors: ["#": color.opacity(0.7), "o": .white])
            default:
                if bx < laneStart - 10 { continue }  // still offstage behind the score
                var c = color
                if scared, let age = lastPelletAge {
                    bx -= CGFloat(min(age, 1)) * 34 + CGFloat(i) * 6   // they flee
                    let flash = age > 1.2 && Int(t * 8) % 2 == 0
                    c = flash ? .white : Color(red: 0.55, green: 0.62, blue: 0.8)
                }
                PixelArt.draw(frame == 0 ? PixelArt.bugA : PixelArt.bugB, &ctx,
                              at: CGPoint(x: bx, y: midY - bugW / 2 + wobble), pixel: p,
                              colors: ["#": c, "o": scared ? Color(white: 0.15) : .white])
            }
        }

        // The muncher: jaws timed so they snap shut on each dot.
        var open = 0.0
        if state == .working {
            let phase = Double((mouth - laneStart).truncatingRemainder(dividingBy: spacing) / spacing)
            open = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        }
        var color = tint
        if state == .approval || state == .waiting, frame == 1 { color = state.accent }
        if state == .error { color = Color(white: 0.55) }
        PixelArt.draw(PixelArt.muncher(open: open), &ctx, at: CGPoint(x: x, y: midY - body / 2), pixel: p,
                      colors: ["#": color, "e": .black])
    }

    private static func pop(_ ctx: inout GraphicsContext, at c: CGPoint, age a: Double, pellet: Bool) {
        let d = CGFloat(2 + a * (pellet ? 12 : 7))
        let alpha = 1 - a
        let color = pellet ? Palette.amber : Color(red: 1, green: 0.9, blue: 0.75)
        for (dx, dy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
            ctx.fill(Path(CGRect(x: c.x + CGFloat(dx) * d - 1, y: c.y + CGFloat(dy) * d - 1, width: 2, height: 2)),
                     with: .color(color.opacity(alpha)))
        }
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
