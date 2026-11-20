import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private let store = SessionStore()
    private let actions = NotchActions()
    private var model: NotchViewModel!
    private var window: NotchWindowController!
    private var coordinator: Coordinator!
    private var statusMenu: StatusMenuController!
    private var router: RequestRouter?
    private var server: EventServer?
    private var serverError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if anotherInstanceIsRunning() {
            NSApp.terminate(nil)
            return
        }
        Paths.ensureHome()
        HooksInstaller.ensureCLI()

        model = NotchViewModel(store: store, prefs: prefs)
        window = NotchWindowController(model: model, store: store, prefs: prefs, actions: actions)
        coordinator = Coordinator(store: store, model: model, prefs: prefs, window: window)
        actions.focus = { [weak self] session in self?.coordinator.focus(session) }
        actions.clearFinished = { [weak self] in self?.store.clearFinished() }
        coordinator.start()
        store.startMaintenance()

        startServer()
        statusMenu = StatusMenuController(store: store, prefs: prefs, model: model, coordinator: coordinator,
                                          window: window) { [weak self] in
            if let error = self?.serverError { return "Not listening: \(error)" }
            return "Listening on 127.0.0.1:\(self?.server?.port ?? 0)"
        }
    }

    private func startServer() {
        let store = self.store
        let token = Paths.loadOrCreateToken()
        var lastError: Error?
        // Another account on this Mac may already hold the port; walk up a few. The CLI finds
        // the one in use through ~/.remindo/port.
        for offset in 0..<10 {
            let port = prefs.port &+ UInt16(offset)
            if Self.ownInstanceAnswers(port: port, token: token) {
                // Our own Remindo already serves this (e.g. a second copy was launched): don't
                // grab another port and redirect the hooks. Let the running one keep its job.
                NSLog("Remindo: already running on port \(port); quitting this copy")
                NSApp.terminate(nil)
                return
            }
            let router = makeRouter(port: port, token: token, store: store)
            let server = EventServer(port: port) { request in router.handle(request) }
            do {
                try server.start()
                self.router = router
                self.server = server
                Paths.writePort(port)
                model.showBanner(Banner(title: "Remindo is on",
                                        subtitle: HooksInstaller.isClaudeLinked()
                                            ? "Watching Claude Code. I'll light up the notch when it needs you."
                                            : "Link Claude Code from the menu bar spark to get started.",
                                        state: .done),
                                 duration: 3.5)
                return
            } catch {
                lastError = error
            }
        }
        serverError = lastError.map { "\($0)" } ?? "unknown error"
        model.showBanner(Banner(title: "Can't listen on port \(prefs.port)", subtitle: serverError ?? "", state: .error),
                         duration: 8)
    }

    private func makeRouter(port: UInt16, token: String, store: SessionStore) -> RequestRouter {
        RequestRouter(
            port: port,
            token: token,
            deliver: { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { store.apply(event) } }
            },
            status: {
                DispatchQueue.main.sync { MainActor.assumeIsolated { store.statusJSON() } }
            },
            test: { scenario in
                DispatchQueue.main.async { MainActor.assumeIsolated { Demo.run(store: store, scenario: scenario) } }
            })
    }

    /// True when a Remindo that knows our token answers on this port.
    private static func ownInstanceAnswers(port: UInt16, token: String) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/status") else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0.6)
        request.setValue("app-probe", forHTTPHeaderField: "X-Remindo-Client")
        request.setValue(token, forHTTPHeaderField: "X-Remindo-Token")
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]  // straight to loopback
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        session.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 0.8)
        return ok
    }

    private func anotherInstanceIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != me }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}
