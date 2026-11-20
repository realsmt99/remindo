import AppKit
import SwiftUI

/// Text with a highlight sweeping across it, like Claude Code's "Cooking…" spinner.
struct ShimmerText: View {
    let text: String
    var base: Color = .white.opacity(0.55)
    var highlight: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t / 1.8).truncatingRemainder(dividingBy: 1))
            let x = -0.6 + phase * 2.2
            Text(text)
                .foregroundStyle(LinearGradient(
                    stops: [
                        .init(color: base, location: 0),
                        .init(color: highlight, location: 0.5),
                        .init(color: base, location: 1),
                    ],
                    startPoint: UnitPoint(x: x - 0.35, y: 0.5),
                    endPoint: UnitPoint(x: x + 0.35, y: 0.5)))
        }
    }
}

/// Icons of the apps hosting agents (Terminal, VS Code, Claude...).
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func icon(for bundleID: String?) -> NSImage? {
        guard let id = bundleID, !id.isEmpty, !misses.contains(id) else { return nil }
        if let image = cache[id] { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            misses.insert(id)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        cache[id] = image
        return image
    }
}

struct HostIcon: View {
    let bundleID: String?
    var size: CGFloat = 22

    var body: some View {
        if let image = AppIcons.icon(for: bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

/// All the words the notch says.
enum StatusText {
    static func title(_ s: AgentSession, kind: PeekKind) -> String {
        if let custom = s.customTitle, s.state != .working || kind != .leftWhileWorking { return custom }
        switch s.state {
        case .working:
            return kind == .leftWhileWorking ? "Still \(s.verb.lowercased())…" : "\(s.verb)…"
        case .approval:
            return "Needs your approval"
        case .waiting:
            return s.persistent ? "Has a question for you" : "Waiting for you"
        case .done:
            return s.isClaude ? "Finished cooking" : "Finished"
        case .error:
            return "Hit a snag"
        case .idle:
            return "Idle"
        }
    }

    static func subtitle(_ s: AgentSession, kind: PeekKind) -> String? {
        switch s.state {
        case .working:
            if kind == .leftWhileWorking { return "I'll light up the notch when it's done" }
            return s.activity ?? s.prompt.map { "“\($0)”" } ?? "On it"
        case .approval:
            return s.detail
        case .waiting:
            return s.detail
        case .done:
            if let summary = s.summary { return summary }
            if let prompt = s.prompt { return "“\(prompt)”" }
            return s.elapsed().map { "Took \(Format.duration($0))" }
        case .error:
            return s.detail
        case .idle:
            return s.detail
        }
    }

    /// One line for the expanded list and the menu.
    static func line(_ s: AgentSession) -> String {
        switch s.state {
        case .working: return s.activity ?? "\(s.verb)…"
        case .approval: return s.detail ?? "Needs your approval"
        case .waiting: return s.persistent ? (s.detail ?? "Has a question for you") : "Waiting for you"
        case .done: return s.acknowledged ? (s.summary ?? "Done") : "Finished cooking · click to open"
        case .error: return s.detail ?? "Hit a snag"
        case .idle: return s.detail ?? "Idle"
        }
    }

    static func time(_ s: AgentSession, now: Date) -> String {
        switch s.state {
        case .working, .approval:
            return s.elapsed(at: now).map(Format.clock) ?? ""
        case .waiting, .idle:
            return Format.ago(s.lastEventAt, now: now)
        case .done, .error:
            if let finished = s.finishedAt, now.timeIntervalSince(finished) > 90 { return Format.ago(finished, now: now) }
            return s.elapsed(at: now).map(Format.duration) ?? ""
        }
    }
}

/// Content fades in with a little blur and settles from slightly smaller.
struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 6 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.94 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeOut(duration: 0.28).delay(0.07)),
            removal: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeIn(duration: 0.12)))
    }
}

/// A small capsule button that works inside the non-activating notch panel.
struct PillButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.09)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}
