import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating panel that floats above the menu bar on every Space,
/// including full-screen apps. It never takes focus away from what you're doing.
final class NotchPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks land on the first try even though Remindo is never the active app.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchWindowController {
    static let windowSize = CGSize(width: 720, height: 360)

    let panel: NotchPanel
    private let model: NotchViewModel
    private let prefs: Preferences
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var mouseInside = false
    private var modeWatch: AnyCancellable?

    init(model: NotchViewModel, store: SessionStore, prefs: Preferences, actions: NotchActions) {
        self.model = model
        self.prefs = prefs
        panel = NotchPanel(size: Self.windowSize)

        let host = NotchHostingView(rootView: NotchRootView(model: model, store: store, actions: actions))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.windowSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()
        startMouseTracking()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })

        // When a card appears under a resting cursor no mouse event fires, so re-check
        // click-through whenever the notch changes shape.
        modeWatch = model.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.trackMouse()
                    self?.updatePolling()
                }
            }
    }

    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        switch prefs.displayMode {
        case .notch:
            return screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first
        case .active:
            return NSScreen.main ?? screens.first
        }
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        let metrics = NotchMetrics.measure(screen, forceIsland: prefs.islandEverywhere)
        if model.metrics != metrics { model.metrics = metrics }
        let f = screen.frame
        let size = Self.windowSize
        let frame = NSRect(x: (f.midX - size.width / 2).rounded(), y: f.maxY - size.height,
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

    // MARK: Mouse

    /// Most of the panel is transparent; it only takes the mouse while the cursor is over
    /// what's actually drawn, so the menu bar and apps underneath keep working.
    private func startMouseTracking() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// While the cursor is over the panel the global monitor goes quiet, so poll to notice it
    /// leave, but only then: no timer runs while the notch is idle.
    private func updatePolling() {
        let needed = mouseInside || model.mode == .expanded || model.mode == .peek
        if needed && pollTimer == nil {
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackMouse() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !needed, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
        }
    }

    private func trackMouse() {
        let inside = hotRect().contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside != mouseInside {
            mouseInside = inside
            model.setHover(inside)
            updatePolling()
        }
    }

    /// Screen-space rect of what's drawn (or of the bare notch while hidden).
    private func hotRect() -> NSRect {
        let f = panel.frame
        switch model.mode {
        case .hidden:
            guard model.canHoverOpen else { return .zero }
            let m = model.metrics
            if m.hasNotch {
                let w = m.notchSize.width + 12
                return NSRect(x: f.midX - w / 2, y: f.maxY - m.notchSize.height, width: w, height: m.notchSize.height + 2)
            }
            // No notch: only the very top edge, so menus in the middle of the bar stay clickable.
            return NSRect(x: f.midX - 90, y: f.maxY - 3, width: 180, height: 5)
        default:
            let s = model.shapeSize
            let top = model.metrics.island ? model.metrics.islandTop : 0
            return NSRect(x: f.midX - s.width / 2, y: f.maxY - top - s.height, width: s.width, height: s.height + 2)
        }
    }
}
