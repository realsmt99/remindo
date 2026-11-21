import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Remindo --readme-shots <dir>` renders the pictures used in the README: each notch state
/// over a desktop-like backdrop, plus animated GIFs of the arcade lane.
@MainActor
extension SnapshotRenderer {
    static func renderReadme(to dir: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return false }
        let prefs = Preferences()
        prefs.arcadeStyle = true
        let store = SessionStore()
        let metrics = NotchMetrics(notchSize: CGSize(width: 186, height: 32), hasNotch: true)
        seedForReadme(store)
        var ok = true

        func shot(_ name: String, _ mode: NotchMode, peek: String? = nil, kind: PeekKind = .event,
                  banner: Banner? = nil, height: CGFloat, time: Double = 1000.35) {
            let model = NotchViewModel(store: store, prefs: prefs)
            model.metrics = metrics
            model.debugShow(mode, peek: peek, kind: kind, banner: banner)
            ArcadeClock.now = time
            ok = write(desk(model: model, store: store, metrics: metrics, height: height),
                       to: dir.appendingPathComponent(name)) && ok
        }

        shot("working.png", .peek, peek: "working", height: 190, time: 4.6)
        shot("approval.png", .peek, peek: "approval", height: 190)
        shot("question.png", .peek, peek: "question", height: 190)
        shot("done.png", .peek, peek: "done", height: 190)
        shot("error.png", .peek, peek: "error", height: 190)
        shot("list.png", .expanded, height: 330)

        // Animated: the card while Claude cooks (the muncher chomping its lane).
        let model = NotchViewModel(store: store, prefs: prefs)
        model.metrics = metrics
        model.debugShow(.peek, peek: "working", kind: .event)
        var frames: [CGImage] = []
        let fps = 15.0
        // One full trip across the lane (~7.5 s) so the GIF loops without a jump.
        let trip = Double(NotchLayout.bodySize(.peek, metrics: metrics, rows: 1).width - 36 - 62 + 140) / 62
        let count = Int(trip * fps)
        for i in 0..<count {
            ArcadeClock.now = Double(i) * trip / Double(count)
            let renderer = ImageRenderer(content: desk(model: model, store: store, metrics: metrics, height: 190))
            renderer.scale = 1
            if let image = renderer.cgImage { frames.append(image) }
        }
        ok = writeGIF(frames, delay: 1 / fps, to: dir.appendingPathComponent("cooking.gif")) && ok

        // The compact live activity in the notch's wings, with one agent cooking.
        let soloStore = SessionStore()
        var e = AgentEvent(agentID: "claude-code", sessionID: "solo", action: .turnStart, timestamp: 1)
        e.cwd = "/Users/me/Projects/game-server"
        soloStore.apply(e)
        let solo = NotchViewModel(store: soloStore, prefs: prefs)
        solo.metrics = metrics
        solo.debugShow(.compact)
        ArcadeClock.now = 3000
        ok = write(desk(model: solo, store: soloStore, metrics: metrics, height: 120),
                   to: dir.appendingPathComponent("compact.png")) && ok
        let compactModel = solo
        var compactFrames: [CGImage] = []
        for i in 0..<16 {
            ArcadeClock.now = 3000 + Double(i) * 0.09
            let renderer = ImageRenderer(content: desk(model: compactModel, store: soloStore, metrics: metrics, height: 80))
            renderer.scale = 1.5
            if let image = renderer.cgImage { compactFrames.append(image) }
        }
        ok = writeGIF(compactFrames, delay: 0.09, to: dir.appendingPathComponent("compact.gif")) && ok

        // The floating island, on a screen without a notch (iMac, external display...).
        let islandMetrics = NotchMetrics(notchSize: CGSize(width: 150, height: 30), hasNotch: false,
                                         island: true, islandTop: 5)
        func islandShot(_ name: String, _ mode: NotchMode, store: SessionStore, peek: String? = nil, height: CGFloat,
                        time: Double = 1000.35) {
            let model = NotchViewModel(store: store, prefs: prefs)
            model.metrics = islandMetrics
            model.debugShow(mode, peek: peek, kind: .event)
            ArcadeClock.now = time
            ok = write(desk(model: model, store: store, metrics: islandMetrics, height: height, notch: false),
                       to: dir.appendingPathComponent(name)) && ok
        }
        islandShot("island-compact.png", .compact, store: soloStore, height: 90, time: 3000)
        islandShot("island-working.png", .peek, store: store, peek: "working", height: 200, time: 4.6)
        islandShot("island-done.png", .peek, store: store, peek: "done", height: 200)
        ArcadeClock.now = nil
        return ok
    }

    /// A slice of a Mac desktop: wallpaper, menu bar, the physical notch, and Remindo on top.
    private static func desk(model: NotchViewModel, store: SessionStore, metrics: NotchMetrics, height: CGFloat,
                             notch: Bool = true) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.30), Color(red: 0.55, green: 0.30, blue: 0.38),
                                    Color(red: 0.93, green: 0.55, blue: 0.40)],
                           startPoint: .top, endPoint: .bottom)
            HStack(spacing: 18) {
                Text("").font(.system(size: 14))
                Text("Finder").bold()
                Text("File"); Text("Edit"); Text("View")
                Spacer()
                Text("Fri 9:41").monospacedDigit()
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .frame(height: notch ? metrics.notchSize.height : 24)
            .background(Color.black.opacity(0.18))
            if notch {
                NotchShape(topRadius: 4, bottomRadius: 9)
                    .fill(Color.black)
                    .frame(width: metrics.notchSize.width + 8, height: metrics.notchSize.height)
            }
            NotchRootView(model: model, store: store, actions: NotchActions())
                .frame(width: NotchWindowController.windowSize.width, height: NotchWindowController.windowSize.height)
                .frame(height: height, alignment: .top)
                .clipped()
        }
        .frame(width: NotchWindowController.windowSize.width, height: height)
        .clipped()
    }

    private static func writeGIF(_ frames: [CGImage], delay: Double, to url: URL) -> Bool {
        guard !frames.isEmpty,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(dest, frame, frameProps) }
        return CGImageDestinationFinalize(dest)
    }

    private static func seedForReadme(_ store: SessionStore) {
        var t = 1_000.0
        func ev(_ id: String, _ action: AgentEvent.Action, cwd: String, detail: String? = nil, prompt: String? = nil,
                summary: String? = nil, host: String? = nil) {
            t += 1
            var e = AgentEvent(agentID: "claude-code", sessionID: id, action: action, timestamp: t)
            e.cwd = cwd; e.detail = detail; e.prompt = prompt; e.summary = summary; e.hostBundleID = host
            store.apply(e)
        }
        ev("working", .turnStart, cwd: "/Users/me/Projects/game-server", prompt: "Refactor the matchmaking queue",
           host: "com.apple.Terminal")
        ev("working", .activity, cwd: "/Users/me/Projects/game-server", detail: "Editing Matchmaker.swift")
        ev("approval", .turnStart, cwd: "/Users/me/Projects/photo-app", prompt: "Add the export button")
        ev("approval", .approval(toolUseID: nil), cwd: "/Users/me/Projects/photo-app",
           detail: "Run: npm install --save file-saver", host: "com.anthropic.claudefordesktop")
        ev("question", .turnStart, cwd: "/Users/me/Projects/api", prompt: "Set up the database")
        ev("question", .question, cwd: "/Users/me/Projects/api", detail: "Which database should I use: SQLite or Postgres?")
        ev("done", .turnStart, cwd: "/Users/me/Projects/blog", prompt: "Add dark mode")
        ev("done", .done, cwd: "/Users/me/Projects/blog",
           summary: "Dark mode is in: a toggle in the header, and it follows the system setting.",
           host: "com.anthropic.claudefordesktop")
        ev("error", .turnStart, cwd: "/Users/me/Projects/site", prompt: "Deploy")
        ev("error", .failed, cwd: "/Users/me/Projects/site", detail: "API overloaded, try again in a minute")
    }
}
