import AppKit
import SwiftUI

/// `Remindo --snapshot <dir>` renders every notch state to PNGs offscreen, so the UI can be
/// checked without screen-recording permission. Developer tool; not used by the app itself.
@MainActor
enum SnapshotRenderer {
    static func renderAll(to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let prefs = Preferences()
        let store = SessionStore()
        let metrics = NotchMetrics(notchSize: CGSize(width: 186, height: 32), hasNotch: true)
        seed(store)

        var ok = true
        let cases: [(String, NotchMode, String?, PeekKind, Banner?)] = [
            ("1-compact-working", .compact, nil, .event, nil),
            ("2-peek-working", .peek, "working", .event, nil),
            ("3-peek-left-while-working", .peek, "working", .leftWhileWorking, nil),
            ("4-peek-approval", .peek, "approval", .event, nil),
            ("5-peek-question", .peek, "question", .reminder, nil),
            ("6-peek-done", .peek, "done", .event, nil),
            ("7-peek-error", .peek, "error", .event, nil),
            ("8-expanded", .expanded, nil, .event, nil),
            ("9-banner", .peek, nil, .banner, Banner(title: "Remindo is on", subtitle: "Watching Claude Code. I'll light up the notch when it needs you.", state: .done)),
        ]
        for (name, mode, peekID, kind, banner) in cases {
            let model = NotchViewModel(store: store, prefs: prefs)
            model.metrics = metrics
            if name == "1-compact-working" { onlyWorking(store) } else { seed(store) }
            model.debugShow(mode, peek: peekID, kind: kind, banner: banner)
            ok = write(scene(model: model, store: store, metrics: metrics), to: dir.appendingPathComponent(name + ".png")) && ok
        }

        // Spark animation frames for each state.
        for state in AgentState.allCases {
            let frames = HStack(spacing: 18) {
                ForEach(0..<6, id: \.self) { i in
                    SparkView(state: state, size: 44, fixedTime: Double(i) * 0.23,
                              fixedBurst: state == .done ? Double(i) / 6 : nil)
                        .frame(width: 90, height: 90)
                }
            }
            .padding(20)
            .background(Color.black)
            ok = write(frames, to: dir.appendingPathComponent("spark-\(state.rawValue).png")) && ok
        }
        // Arcade lane frames: the chase over time, then the other states.
        let lanes = VStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { i in
                Canvas { ctx, sz in ArcadeStrip.paint(&ctx, size: sz, t: 1000 + Double(i) * 0.9, state: .working, tint: Palette.claude) }
                    .frame(width: 380, height: 24)
            }
            ForEach([AgentState.approval, .done, .error], id: \.self) { st in
                Canvas { ctx, sz in ArcadeStrip.paint(&ctx, size: sz, t: 1000.2, state: st, tint: Palette.claude) }
                    .frame(width: 380, height: 24)
            }
        }
        .padding(16)
        .background(Color.black)
        ok = write(lanes, to: dir.appendingPathComponent("arcade-lanes.png")) && ok
        return ok
    }

    private static func scene(model: NotchViewModel, store: SessionStore, metrics: NotchMetrics) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.78, green: 0.56, blue: 0.52)],
                           startPoint: .top, endPoint: .bottom)
            // Fake menu bar and the physical notch, to check alignment.
            Rectangle().fill(Color.white.opacity(0.22)).frame(height: metrics.notchSize.height)
            NotchShape(topRadius: 4, bottomRadius: 9)
                .fill(Color.black)
                .frame(width: metrics.notchSize.width + 8, height: metrics.notchSize.height)
            NotchRootView(model: model, store: store, actions: NotchActions())
        }
        .frame(width: NotchWindowController.windowSize.width, height: NotchWindowController.windowSize.height)
    }

    private static func write<V: View>(_ view: V, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    private static func onlyWorking(_ store: SessionStore) {
        for id in store.sessions.keys { store.remove(id) }
        var t = 1_000.0
        func next() -> Double { t += 1; return t }
        var e = AgentEvent(agentID: "claude-code", sessionID: "working", action: .turnStart, timestamp: next())
        e.cwd = "/Users/me/Projects/warbot"
        e.prompt = "Refactor the matchmaking queue"
        store.apply(e)
    }

    private static func seed(_ store: SessionStore) {
        for id in store.sessions.keys { store.remove(id) }
        var t = 1_000.0
        func next() -> Double { t += 1; return t }
        func ev(_ id: String, _ action: AgentEvent.Action, cwd: String, detail: String? = nil, prompt: String? = nil,
                summary: String? = nil, host: String? = nil) {
            var e = AgentEvent(agentID: "claude-code", sessionID: id, action: action, timestamp: next())
            e.cwd = cwd
            e.detail = detail
            e.prompt = prompt
            e.summary = summary
            e.hostBundleID = host
            store.apply(e)
        }
        ev("working", .turnStart, cwd: "/Users/me/Projects/warbot", prompt: "Refactor the matchmaking queue",
           host: "com.apple.Terminal")
        ev("working", .activity, cwd: "/Users/me/Projects/warbot", detail: "Editing Matchmaker.swift")
        ev("approval", .turnStart, cwd: "/Users/me/Projects/huminizer", prompt: "Add the export button")
        ev("approval", .approval(toolUseID: nil), cwd: "/Users/me/Projects/huminizer",
           detail: "Run: npm install --save file-saver", host: "com.anthropic.claudefordesktop")
        ev("question", .turnStart, cwd: "/Users/me/Projects/api", prompt: "Set up the database")
        ev("question", .question, cwd: "/Users/me/Projects/api", detail: "Which database should I use: SQLite or Postgres?")
        ev("done", .turnStart, cwd: "/Users/me/Projects/remindo", prompt: "Make the notch animated")
        ev("done", .done, cwd: "/Users/me/Projects/remindo",
           summary: "Added the notch animation and wired up the Claude Code hooks.", host: "com.anthropic.claudefordesktop")
        ev("error", .turnStart, cwd: "/Users/me/Projects/site", prompt: "Deploy")
        ev("error", .failed, cwd: "/Users/me/Projects/site", detail: "API overloaded, try again in a minute")
    }
}
