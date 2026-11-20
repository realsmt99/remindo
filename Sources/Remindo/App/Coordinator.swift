import AppKit
import CoreGraphics

/// The "remind me" brain: reacts to agent events and to you switching apps, Spaces,
/// waking the screen or coming back to the keyboard, and decides when the notch speaks up.
@MainActor
final class Coordinator {
    private let store: SessionStore
    private let model: NotchViewModel
    private let prefs: Preferences
    private let window: NotchWindowController

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastReminder = Date.distantPast
    private var lastNag: [String: Date] = [:]
    private var lastFrontBundle: String?
    private var hostAckWork: DispatchWorkItem?
    private var glanceAckWork: [String: DispatchWorkItem] = [:]
    private var nagTimer: Timer?
    private var presenceTimer: Timer?
    private var wasAway = false

    /// No keyboard/mouse input for this long means you're not looking, even if the agent's app is in front.
    private static let awayAfter: TimeInterval = 45

    init(store: SessionStore, model: NotchViewModel, prefs: Preferences, window: NotchWindowController) {
        self.store = store
        self.model = model
        self.prefs = prefs
        self.window = window
    }

    func start() {
        lastFrontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        store.onAttention = { [weak self] session in self?.attention(session) }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.appActivated(app)
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.spaceChanged()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            self?.cameBack()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            self?.cameBack()
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in
            self?.cameBack()
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { [weak self] _ in
            self?.cameBack()
        }

        let nag = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.nag() }
        }
        nag.tolerance = 5
        RunLoop.main.add(nag, forMode: .common)
        nagTimer = nag

        // Notices you returning to the keyboard after being away (screen still on).
        let presence = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPresence() }
        }
        presence.tolerance = 1
        RunLoop.main.add(presence, forMode: .common)
        presenceTimer = presence
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        observers.append((center, token))
    }

    // MARK: Agent events

    private func attention(_ s: AgentSession) {
        let watching = hostIsFrontmost(s) && !prefs.remindWhenHostFrontmost && !userIsAway()
        if watching {
            // You're looking at the agent's app right now: a quick nod, no sound; it counts as seen.
            model.peek(s.id, kind: .glance, duration: s.state == .done || s.state == .error ? 2.6 : 2.4)
            scheduleGlanceAck(s.id)
        } else {
            model.peek(s.id, kind: .event, duration: s.isBlocked ? 8 : 6.5)
            Sounds.play(for: s.state, prefs: prefs)
        }
        lastNag[s.id] = Date()
    }

    private func scheduleGlanceAck(_ id: String) {
        glanceAckWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.glanceAckWork[id] = nil
                guard let s = self.store.sessions[id], self.hostIsFrontmost(s), !self.userIsAway() else { return }
                self.store.acknowledge(id)
            }
        }
        glanceAckWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    // MARK: You moving around

    private func appActivated(_ app: NSRunningApplication?) {
        let bundle = app?.bundleIdentifier
        let previous = lastFrontBundle
        lastFrontBundle = bundle
        if prefs.displayMode == .active { window.reposition() }
        if bundle != nil && bundle == Bundle.main.bundleIdentifier { return }

        if let bundle, store.hasSessions(hostBundleID: bundle) {
            // Back where the agent lives: after a short dwell, everything there counts as seen.
            hostAckWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else { return }
                    self?.store.acknowledgeAll(hostBundleID: bundle)
                }
            }
            hostAckWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
            model.endPeek { $0.hostBundleID == bundle }
        }

        guard prefs.remindOnSwitch else { return }

        if let pending = store.attentionFocus(excludingHost: bundle) {
            remind(pending, kind: .reminder, duration: 4.5)
        } else if let previous, previous != bundle,
                  let blocked = store.sessions.values.filter({ $0.isBlocked && $0.hostBundleID == previous })
                      .min(by: { $0.outranks($1) }) {
            // You saw the prompt but left without answering: one nudge on the way out.
            remind(blocked, kind: .reminder, duration: 4.5, force: true)
        } else if let previous, previous != bundle, let working = store.workingSession(hostBundleID: previous) {
            // You just left the agent's app while it's still cooking.
            remind(working, kind: .leftWhileWorking, duration: 3.2, force: true)
        }
    }

    private func spaceChanged() {
        if prefs.displayMode == .active { window.reposition() }
        guard prefs.remindOnSwitch else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let pending = store.attentionFocus(excludingHost: front) {
            remind(pending, kind: .reminder, duration: 4.5)
        }
    }

    private func cameBack() {
        wasAway = false
        guard let pending = store.attentionFocus() else { return }
        remind(pending, kind: .reminder, duration: 6, force: true)
    }

    private func checkPresence() {
        let away = userIsAway()
        if away {
            wasAway = true
        } else if wasAway {
            cameBack()
        }
    }

    private func userIsAway() -> Bool {
        // ~0 = any input event. Reading idle time needs no special permission.
        guard let anyInput = CGEventType(rawValue: ~0) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) > Self.awayAfter
    }

    private func remind(_ s: AgentSession, kind: PeekKind, duration: TimeInterval, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReminder) > 3.5 else { return }
        lastReminder = now
        model.peek(s.id, kind: kind, duration: duration)
    }

    /// Approvals and questions you haven't looked at yet block the agent, so they get a gentle repeat.
    private func nag() {
        guard prefs.repeatReminders else { return }
        let now = Date()
        lastNag = lastNag.filter { store.sessions[$0.key] != nil }
        let blocked = store.sessions.values
            .filter { $0.isBlocked && $0.needsAttention && !hostIsFrontmost($0) }
            .sorted { $0.outranks($1) }
        for s in blocked {
            let last = lastNag[s.id] ?? s.lastEventAt
            guard now.timeIntervalSince(last) >= 90 else { continue }
            lastNag[s.id] = now
            remind(s, kind: .reminder, duration: 4.5, force: true)
            break
        }
    }

    // MARK: Clicks

    func focus(_ s: AgentSession) {
        store.acknowledge(s.id)
        model.endAllPeeks()
        HostActivator.activate(bundleID: s.hostBundleID, pid: s.hostPID)
    }

    private func hostIsFrontmost(_ s: AgentSession) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if let pid = s.hostPID, front.processIdentifier == pid { return true }
        if let bundle = s.hostBundleID, front.bundleIdentifier == bundle { return true }
        return false
    }
}
