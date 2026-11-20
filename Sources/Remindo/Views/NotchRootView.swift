import SwiftUI

/// Everything Remindo draws. The black shape grows out of the real notch.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: SessionStore
    let actions: NotchActions

    var body: some View {
        let mode = model.mode
        let size = model.shapeSize
        let shape = NotchShape(topRadius: NotchLayout.ear(mode), bottomRadius: NotchLayout.corner(mode))

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                GlowHalo(mode: mode, color: model.glowColor, pulsing: model.glowPulses)
                    .frame(width: size.width, height: size.height)

                shape
                    .fill(Color.black)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(mode == .peek || mode == .expanded ? 0.45 : 0), radius: 14, y: 6)

                NotchContent(model: model, store: store, actions: actions)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipShape(shape)
            }
            .frame(width: size.width, height: size.height)
            .opacity(mode == .hidden ? 0 : 1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(NotchLayout.spring, value: mode)
        .animation(NotchLayout.spring, value: model.metrics)
        .environment(\.colorScheme, .dark)
    }
}

/// A soft, breathing glow in the state's color, bleeding out around the notch.
struct GlowHalo: View {
    let mode: NotchMode
    let color: Color
    /// Breathe while an agent works or waits on you; hold still otherwise (saves energy).
    let pulsing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: mode == .hidden || !pulsing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = pulsing ? 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2.4)) : 0.8
            NotchShape(topRadius: NotchLayout.ear(mode), bottomRadius: NotchLayout.corner(mode))
                .fill(color)
                .blur(radius: mode == .compact ? 6 : 12)
                .opacity(mode == .hidden ? 0 : pulse * (mode == .compact ? 0.5 : 0.32))
        }
        .allowsHitTesting(false)
    }
}

struct NotchContent: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: SessionStore
    let actions: NotchActions

    var body: some View {
        ZStack(alignment: .top) {
            switch model.mode {
            case .hidden:
                Color.clear
            case .compact:
                if let s = store.focus {
                    CompactView(session: s, extra: max(0, store.liveCount - 1), metrics: model.metrics,
                                arcade: model.prefs.arcadeStyle)
                        .contentShape(Rectangle())
                        .onTapGesture { actions.focus(s) }
                        .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            case .peek:
                PeekView(model: model, store: store, actions: actions)
                    .transition(.blurFade)
            case .expanded:
                ExpandedView(model: model, store: store, actions: actions)
                    .transition(.blurFade)
            }
        }
        .padding(.horizontal, NotchLayout.ear(model.mode))
    }
}

// MARK: - Compact

struct CompactView: View {
    let session: AgentSession
    let extra: Int
    let metrics: NotchMetrics
    var arcade = false

    var body: some View {
        HStack(spacing: 0) {
            // Left wing: the spark, plus a "+N" badge when more agents want you.
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if arcade {
                        PixelSpark(state: session.state, size: 18, tint: session.tint)
                    } else {
                        SparkView(state: session.state, size: 17, tint: session.tint, celebrateOnAppear: false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if extra > 0 {
                    Text("+\(extra)")
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.claude))
                        .padding(.bottom, 2)
                        .padding(.trailing, 1)
                }
            }
            .frame(width: NotchLayout.wing, height: metrics.notchSize.height)
            Spacer(minLength: metrics.notchSize.width)
            CompactAccessory(session: session, arcade: arcade)
                .frame(width: NotchLayout.wing, height: metrics.notchSize.height)
        }
        .frame(height: metrics.notchSize.height)
    }
}

struct CompactAccessory: View {
    let session: AgentSession
    var arcade = false

    var body: some View {
        Group {
            if session.state == .working {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.shortClock(session.elapsed(at: context.date) ?? 0))
                        .font(arcade ? .arcade(11) : .system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(arcade ? Palette.claude : .white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Image(systemName: session.state.symbolName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(session.state.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: session.needsAttention && session.isBlocked)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Peek

struct PeekView: View {
    @ObservedObject var model: NotchViewModel
    /// Observed so the card follows the session live (summary arriving, approval granted...).
    @ObservedObject var store: SessionStore
    let actions: NotchActions

    var body: some View {
        let bandWidth = NotchLayout.bodySize(.peek, metrics: model.metrics, rows: 1).width
        let arcade = model.prefs.arcadeStyle
        if let banner = model.banner {
            PeekCard(metrics: model.metrics, bandWidth: bandWidth, leading: "Remindo", trailing: "",
                     state: banner.state, tint: Palette.claude,
                     title: arcade ? banner.title.uppercased() : banner.title, shimmer: false,
                     subtitle: banner.subtitle, hostBundleID: nil, celebrate: true, arcade: arcade)
        } else if let id = model.peekSessionID, let s = store.sessions[id] {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PeekCard(metrics: model.metrics, bandWidth: bandWidth, leading: s.projectName,
                         trailing: StatusText.time(s, now: context.date),
                         state: s.state, tint: s.tint,
                         title: arcade ? StatusText.arcadeTitle(s, kind: model.peekKind) : StatusText.title(s, kind: model.peekKind),
                         shimmer: s.state == .working, subtitle: StatusText.subtitle(s, kind: model.peekKind),
                         hostBundleID: s.hostBundleID,
                         celebrate: model.peekKind == .event || model.peekKind == .glance, arcade: arcade)
            }
            .contentShape(Rectangle())
            .onTapGesture { actions.focus(s) }
        }
    }
}

struct PeekCard: View {
    let metrics: NotchMetrics
    /// Width of the card body; the top band's two labels each get one wing of it.
    let bandWidth: CGFloat
    let leading: String
    let trailing: String
    let state: AgentState
    let tint: Color
    let title: String
    let shimmer: Bool
    let subtitle: String?
    let hostBundleID: String?
    /// Play the "finished" burst when the card appears (fresh news only, not reminders).
    let celebrate: Bool
    var arcade = false

    var body: some View {
        let wing = max(40, (bandWidth - metrics.notchSize.width) / 2 - 24)
        VStack(spacing: 0) {
            // The band beside the physical notch: each label stays within its own wing.
            HStack(spacing: 0) {
                Text(leading).lineLimit(1).truncationMode(.tail)
                    .frame(width: wing, alignment: .leading)
                Spacer(minLength: 0)
                Text(trailing).lineLimit(1).monospacedDigit()
                    .frame(width: wing, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 16)
            .frame(height: metrics.notchSize.height)

            HStack(alignment: .center, spacing: 14) {
                Group {
                    if arcade {
                        PixelSpark(state: state, size: 36, tint: tint)
                    } else {
                        SparkView(state: state, size: 38, tint: tint, celebrateOnAppear: celebrate)
                    }
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Group {
                        if shimmer {
                            ShimmerText(text: title)
                        } else {
                            Text(title).foregroundStyle(arcade ? arcadeColor : .white)
                        }
                    }
                    .font(arcade ? .arcade(14) : .system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                HostIcon(bundleID: hostBundleID, size: 24)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, arcade ? 2 : 8)
            .frame(maxHeight: .infinity)

            if arcade {
                ArcadeStrip(state: state, tint: tint)
                    .frame(height: 20)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
        }
    }

    private var arcadeColor: Color {
        switch state {
        case .done, .error, .approval, .waiting: return state.accent
        default: return .white
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: SessionStore
    let actions: NotchActions

    var body: some View {
        let metrics = model.metrics
        let sessions = Array(store.ordered.prefix(NotchLayout.maxRows))
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SparkView(state: .idle, size: 12, animated: false)
                Text("Remindo")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: metrics.notchSize.width + 12)
                Text(headline)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 16)
            .frame(height: metrics.notchSize.height)

            VStack(spacing: 6) {
                ForEach(sessions) { s in
                    SessionRow(session: s)
                        .onTapGesture { actions.focus(s) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if store.hasFinished {
                    PillButton(title: "Clear finished") { actions.clearFinished() }
                }
                Spacer()
                if store.sessions.count > NotchLayout.maxRows {
                    Text("+\(store.sessions.count - NotchLayout.maxRows) more in the menu bar")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 9)
        }
    }

    private var headline: String {
        let waiting = store.sessions.values.filter(\.needsAttention).count
        let working = store.sessions.values.filter { $0.state == .working }.count
        if waiting > 0 { return "\(waiting) need\(waiting == 1 ? "s" : "") you" }
        if working > 0 { return "\(working) cooking" }
        return store.sessions.count == 1 ? "1 agent" : "\(store.sessions.count) agents"
    }
}

struct SessionRow: View {
    let session: AgentSession
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if NotchLayout.arcade {
                    PixelSpark(state: session.state, size: 22, tint: session.tint)
                } else {
                    SparkView(state: session.state, size: 20, tint: session.tint, celebrateOnAppear: false)
                }
            }
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(session.agentName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .lineLimit(1)
                Text(StatusText.line(session))
                    .font(.system(size: 11))
                    .foregroundStyle(session.isLive ? session.state.accent : .white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(StatusText.time(session, now: context.date))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            HostIcon(bundleID: session.hostBundleID, size: 18)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.10 : 0.055)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
