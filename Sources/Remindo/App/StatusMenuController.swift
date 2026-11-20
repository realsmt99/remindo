import AppKit
import Combine

/// The menu bar spark: sessions, previews and settings.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store: SessionStore
    private let prefs: Preferences
    private let model: NotchViewModel
    private let coordinator: Coordinator
    private let window: NotchWindowController
    private let serverLine: () -> String
    private var cancellables: Set<AnyCancellable> = []
    private var lastIconState: AgentState?? = .none

    init(store: SessionStore, prefs: Preferences, model: NotchViewModel, coordinator: Coordinator,
         window: NotchWindowController, serverLine: @escaping () -> String) {
        self.store = store
        self.prefs = prefs
        self.model = model
        self.coordinator = coordinator
        self.window = window
        self.serverLine = serverLine
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Remindo"
        refreshIcon()

        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
    }

    private func refreshIcon() {
        let focus = store.focus.map { $0.needsAttention ? $0.state : AgentState.working }
        guard lastIconState != .some(focus) else { return }
        lastIconState = .some(focus)
        item.button?.image = MenuBarIcon.image(state: focus)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header("Remindo"))
        menu.addItem(note(serverLine()))
        menu.addItem(.separator())

        let sessions = store.ordered
        if sessions.isEmpty {
            menu.addItem(note("No agents yet. Start Claude Code and it shows up here."))
        }
        for s in sessions.prefix(10) {
            let title = "\(s.projectName) · \(s.agentName): \(StatusText.line(s))"
            let entry = NSMenuItem(title: Format.oneLine(title, limit: 70), action: #selector(focusSession(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = s.id
            entry.image = MenuBarIcon.dot(s.isLive ? s.state : .idle)
            menu.addItem(entry)
        }
        if store.hasFinished {
            menu.addItem(action("Clear finished", #selector(clearFinished)))
        }

        menu.addItem(.separator())
        let preview = NSMenuItem(title: "Preview the notch", action: nil, keyEquivalent: "")
        let previewMenu = NSMenu()
        for (title, scenario) in [("Full demo", "demo"), ("Cooking…", "working"), ("Needs approval", "approval"),
                                  ("Has a question", "question"), ("Finished cooking", "done"), ("Error", "error")] {
            let entry = NSMenuItem(title: title, action: #selector(runPreview(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = scenario
            previewMenu.addItem(entry)
        }
        preview.submenu = previewMenu
        menu.addItem(preview)

        menu.addItem(.separator())
        menu.addItem(toggle("Remind me when I switch apps or Spaces", prefs.remindOnSwitch, #selector(toggleSwitch)))
        menu.addItem(toggle("Show live activity while agents work", prefs.showLiveActivity, #selector(toggleLive)))
        menu.addItem(toggle("Repeat reminders for approvals", prefs.repeatReminders, #selector(toggleRepeat)))
        menu.addItem(toggle("Remind me even inside the agent's app", prefs.remindWhenHostFrontmost, #selector(toggleHostFront)))
        menu.addItem(toggle("Play sounds", prefs.soundsEnabled, #selector(toggleSounds)))
        menu.addItem(toggle("Arcade style (retro pixels)", prefs.arcadeStyle, #selector(toggleArcade)))

        let display = NSMenuItem(title: "Show on", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.addItem(toggle("Notch display", prefs.displayMode == .notch, #selector(displayNotch)))
        displayMenu.addItem(toggle("Active display", prefs.displayMode == .active, #selector(displayActive)))
        display.submenu = displayMenu
        menu.addItem(display)
        menu.addItem(toggle("Launch at login", LoginItem.isEnabled, #selector(toggleLogin)))

        menu.addItem(.separator())
        if HooksInstaller.isClaudeLinked() {
            menu.addItem(note("Claude Code: linked ✓"))
            menu.addItem(action("Relink Claude Code", #selector(linkClaude)))
            menu.addItem(action("Unlink Claude Code", #selector(unlinkClaude)))
        } else {
            menu.addItem(action("Link Claude Code…", #selector(linkClaude)))
        }
        menu.addItem(action("Open ~/.remindo", #selector(openHome)))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Remindo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func header(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        entry.isEnabled = false
        return entry
    }

    private func note(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func toggle(_ title: String, _ on: Bool, _ selector: Selector) -> NSMenuItem {
        let entry = action(title, selector)
        entry.state = on ? .on : .off
        return entry
    }

    // MARK: Actions

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let s = store.sessions[id] else { return }
        coordinator.focus(s)
    }

    @objc private func clearFinished() { store.clearFinished() }

    @objc private func runPreview(_ sender: NSMenuItem) {
        Demo.run(store: store, scenario: sender.representedObject as? String ?? "demo")
    }

    @objc private func toggleSwitch() { prefs.remindOnSwitch.toggle() }
    @objc private func toggleLive() { prefs.showLiveActivity.toggle() }
    @objc private func toggleRepeat() { prefs.repeatReminders.toggle() }
    @objc private func toggleHostFront() { prefs.remindWhenHostFrontmost.toggle() }
    @objc private func toggleSounds() { prefs.soundsEnabled.toggle() }
    @objc private func toggleArcade() { prefs.arcadeStyle.toggle() }

    @objc private func displayNotch() {
        prefs.displayMode = .notch
        window.reposition()
    }

    @objc private func displayActive() {
        prefs.displayMode = .active
        window.reposition()
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            model.showBanner(Banner(title: "Couldn't change login item", subtitle: error.localizedDescription, state: .error),
                             duration: 6)
        }
    }

    @objc private func linkClaude() {
        HooksInstaller.linkClaude { [weak self] ok, output in
            let subtitle = ok ? "New Claude Code sessions will light up the notch" : Format.oneLine(output, limit: 120)
            self?.model.showBanner(Banner(title: ok ? "Claude Code linked" : "Couldn't link Claude Code",
                                          subtitle: subtitle, state: ok ? .done : .error), duration: 5)
        }
    }

    @objc private func unlinkClaude() {
        HooksInstaller.unlinkClaude { [weak self] ok, output in
            self?.model.showBanner(Banner(title: ok ? "Claude Code unlinked" : "Couldn't unlink Claude Code",
                                          subtitle: ok ? "Remindo's hooks were removed from settings.json" : Format.oneLine(output, limit: 120),
                                          state: ok ? .idle : .error), duration: 5)
        }
    }

    @objc private func openHome() {
        Paths.ensureHome()
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.home))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
