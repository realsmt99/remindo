import AppKit
import Combine
import SwiftUI

enum PeekKind: Equatable {
    /// Something just happened (finished, needs approval...).
    case event
    /// You switched apps/spaces and something is still waiting on you.
    case reminder
    /// You left the agent's app while it's still working.
    case leftWhileWorking
    /// It happened while you're looking at the agent's app: a short nod, no sound.
    case glance
    /// An app-level message ("Remindo is on").
    case banner
}

struct Banner: Equatable {
    var title: String
    var subtitle: String
    var state: AgentState
}

/// Callbacks the notch UI uses; wired up by the app delegate.
@MainActor
final class NotchActions {
    var focus: (AgentSession) -> Void = { _ in }
    var clearFinished: () -> Void = {}
}

/// Decides what the notch shows: hidden, compact live activity, a peek card, or the full list.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var metrics = NotchMetrics.fallback
    @Published private(set) var mode: NotchMode = .hidden
    @Published private(set) var peekSessionID: String?
    @Published private(set) var peekKind: PeekKind = .event
    @Published private(set) var banner: Banner?

    let store: SessionStore
    let prefs: Preferences

    private var peekDeadline: Date?
    private var peekTimer: Timer?
    private var peekGeneration = 0
    private var hoverInside = false
    private var hoverExpanded = false
    private var hoverWork: DispatchWorkItem?
    private var calmWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    /// Blocked states pulse this long after they start, then hold still (they may sit for hours).
    static let calmAfter: TimeInterval = 45

    init(store: SessionStore, prefs: Preferences) {
        self.store = store
        self.prefs = prefs
        // DispatchQueue.main (not RunLoop.main) so updates keep flowing while a menu is open.
        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recompute()
                    self?.scheduleCalm()
                }
            }
            .store(in: &cancellables)
        prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.recompute() } }
            }
            .store(in: &cancellables)
    }

    /// Re-render once blocked states have pulsed long enough, so their glow can go still.
    private func scheduleCalm() {
        let now = Date()
        let pending = store.sessions.values.compactMap { s -> TimeInterval? in
            guard s.isBlocked, let since = s.attentionAt else { return nil }
            let left = Self.calmAfter - now.timeIntervalSince(since)
            return left > 0 ? left : nil
        }
        calmWork?.cancel()
        guard let soonest = pending.min() else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        calmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + soonest + 0.2, execute: work)
    }

    // MARK: Derived

    var rows: Int { min(max(store.sessions.count, 1), NotchLayout.maxRows) }
    var shapeSize: CGSize { NotchLayout.shapeSize(mode, metrics: metrics, rows: rows) }

    var peekSession: AgentSession? { peekSessionID.flatMap { store.sessions[$0] } }

    /// Can hovering the bare notch open the list?
    var canHoverOpen: Bool { !store.sessions.isEmpty }

    var glowColor: Color {
        switch mode {
        case .hidden: return .clear
        case .compact: return store.focus.map { $0.state == .working ? $0.tint : $0.state.accent } ?? Palette.claude
        case .peek:
            if peekKind == .banner { return banner?.state.accent ?? Palette.claude }
            guard let s = peekSession else { return Palette.claude }
            return s.state == .working ? s.tint : s.state.accent
        case .expanded: return store.focus?.state.accent ?? Palette.claude
        }
    }

    var glowPulses: Bool {
        let session: AgentSession?
        switch mode {
        case .hidden: return false
        case .peek: session = peekKind == .banner ? nil : peekSession
        case .compact, .expanded: session = store.focus
        }
        guard let s = session else { return false }
        if s.state == .working { return true }
        guard s.isBlocked || s.state == .waiting else { return false }
        return Date().timeIntervalSince(s.attentionAt ?? .distantPast) < Self.calmAfter
    }

    // MARK: Peeks

    func peek(_ sessionID: String, kind: PeekKind, duration: TimeInterval) {
        guard store.sessions[sessionID] != nil else { return }
        banner = nil
        peekSessionID = sessionID
        peekKind = kind
        armDeadline(duration)
        recompute()
    }

    func showBanner(_ b: Banner, duration: TimeInterval) {
        banner = b
        peekSessionID = nil
        peekKind = .banner
        armDeadline(duration)
        recompute()
    }

    /// Drops the current peek if it matches (e.g. you came back to the agent's app).
    func endPeek(where predicate: (AgentSession) -> Bool) {
        guard let s = peekSession, predicate(s) else { return }
        clearPeek()
        recompute()
    }

    func endAllPeeks() {
        clearPeek()
        recompute()
    }

    private func armDeadline(_ duration: TimeInterval) {
        peekDeadline = Date().addingTimeInterval(duration)
        peekTimer?.invalidate()
        peekGeneration += 1
        let generation = peekGeneration
        // Matched by generation, not wall-clock time, so a clock change can't strand a card on screen.
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.peekGeneration == generation else { return }
                self.clearPeek()
                self.recompute()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        peekTimer = timer
    }

    private func clearPeek() {
        peekTimer?.invalidate()
        peekTimer = nil
        peekDeadline = nil
        peekSessionID = nil
        banner = nil
    }

    // MARK: Hover

    func setHover(_ inside: Bool) {
        guard inside != hoverInside else { return }
        hoverInside = inside
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hoverInside == inside else { return }
                self.hoverExpanded = inside && self.canHoverOpen
                self.recompute()
            }
        }
        hoverWork = work
        // A short dwell before opening (so passing the cursor through doesn't pop it open),
        // and a grace period before closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.18 : 0.35), execute: work)
    }

    // MARK: Mode

    func recompute() {
        if hoverExpanded && store.sessions.isEmpty { hoverExpanded = false }
        let hasPeek = peekDeadline != nil && (banner != nil || peekSession != nil)
        if peekDeadline != nil && !hasPeek { clearPeek() }

        let next: NotchMode
        if hoverExpanded {
            next = .expanded
        } else if hasPeek {
            next = .peek
        } else if store.sessions.values.contains(where: { $0.needsAttention || ($0.state == .working && prefs.showLiveActivity) }) {
            next = .compact
        } else {
            next = .hidden
        }
        guard next != mode else { return }
        withAnimation(NotchLayout.spring) { mode = next }
    }

    /// For offscreen snapshots only.
    func debugShow(_ mode: NotchMode, peek sessionID: String? = nil, kind: PeekKind = .event, banner: Banner? = nil) {
        self.peekSessionID = sessionID
        self.peekKind = banner == nil ? kind : .banner
        self.banner = banner
        self.mode = mode
    }
}
