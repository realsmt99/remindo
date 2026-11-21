import AppKit
import Security
import ServiceManagement

@MainActor
final class Preferences: ObservableObject {
    enum DisplayMode: String {
        /// The built-in display with the notch (falls back to the main display).
        case notch
        /// Whichever display you're working on.
        case active
    }

    private enum Key {
        static let sounds = "soundsEnabled"
        static let switchReminders = "remindOnSwitch"
        static let live = "showLiveActivity"
        static let hostFront = "remindWhenHostFrontmost"
        static let repeatReminders = "repeatReminders"
        static let display = "displayMode"
        static let arcade = "arcadeStyle"
        static let island = "islandEverywhere"
        static let port = "port"
    }

    private let defaults = UserDefaults.standard

    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: Key.sounds) } }
    @Published var remindOnSwitch: Bool { didSet { defaults.set(remindOnSwitch, forKey: Key.switchReminders) } }
    @Published var showLiveActivity: Bool { didSet { defaults.set(showLiveActivity, forKey: Key.live) } }
    @Published var remindWhenHostFrontmost: Bool { didSet { defaults.set(remindWhenHostFrontmost, forKey: Key.hostFront) } }
    @Published var repeatReminders: Bool { didSet { defaults.set(repeatReminders, forKey: Key.repeatReminders) } }
    @Published var arcadeStyle: Bool {
        didSet {
            defaults.set(arcadeStyle, forKey: Key.arcade)
            NotchLayout.arcade = arcadeStyle
        }
    }
    /// Show the floating island even on a notched MacBook (it floats just below the notch).
    @Published var islandEverywhere: Bool { didSet { defaults.set(islandEverywhere, forKey: Key.island) } }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Key.display) } }

    /// Fixed for the life of the process: `defaults write dev.remindo.Remindo port 47474`.
    let port: UInt16

    init() {
        defaults.register(defaults: [
            Key.sounds: true,
            Key.switchReminders: true,
            Key.live: true,
            Key.hostFront: false,
            Key.repeatReminders: true,
            Key.display: DisplayMode.notch.rawValue,
            Key.arcade: true,
            Key.island: false,
            Key.port: 47474,
        ])
        soundsEnabled = defaults.bool(forKey: Key.sounds)
        remindOnSwitch = defaults.bool(forKey: Key.switchReminders)
        showLiveActivity = defaults.bool(forKey: Key.live)
        remindWhenHostFrontmost = defaults.bool(forKey: Key.hostFront)
        repeatReminders = defaults.bool(forKey: Key.repeatReminders)
        arcadeStyle = defaults.bool(forKey: Key.arcade)
        islandEverywhere = defaults.bool(forKey: Key.island)
        NotchLayout.arcade = defaults.bool(forKey: Key.arcade)
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Key.display) ?? "") ?? .notch
        let raw = defaults.integer(forKey: Key.port)
        port = (1024...65535).contains(raw) ? UInt16(raw) : 47474
    }
}

enum Paths {
    /// ~/.remindo, or $REMINDO_HOME (same override as the CLI; handy for isolated test runs).
    static let home: String = {
        if let custom = ProcessInfo.processInfo.environment["REMINDO_HOME"], !custom.isEmpty { return custom }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".remindo")
    }()
    static var bin: String { home + "/bin" }
    static var cli: String { bin + "/remindo" }
    static var portFile: String { home + "/port" }

    static var claudeSettings: String {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
        return dir + "/settings.json"
    }

    static var tokenFile: String { home + "/token" }

    static func ensureHome() {
        try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        // Only you can look inside (the token lives here).
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home)
    }

    static func writePort(_ port: UInt16) {
        try? "\(port)\n".write(toFile: portFile, atomically: true, encoding: .utf8)
    }

    /// A per-user secret the CLI must present, so other accounts on this Mac (which share the
    /// loopback interface) can neither read your sessions nor post fake events.
    static func loadOrCreateToken() -> String {
        if let text = try? String(contentsOfFile: tokenFile, encoding: .utf8) {
            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.count >= 32, token.allSatisfy(\.isHexDigit) { return token }
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(atPath: tokenFile)
        FileManager.default.createFile(atPath: tokenFile, contents: Data((token + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }
}

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
enum Sounds {
    static func play(for state: AgentState, prefs: Preferences) {
        guard prefs.soundsEnabled else { return }
        let name: String
        switch state {
        case .done: name = "Glass"
        case .approval: name = "Ping"
        case .waiting: name = "Pop"
        case .error: name = "Basso"
        case .working, .idle: return
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// Brings the agent's app (Terminal, VS Code, Claude...) to the front.
@MainActor
enum HostActivator {
    static func activate(bundleID: String?, pid: pid_t?) {
        var app: NSRunningApplication?
        if let pid { app = NSRunningApplication(processIdentifier: pid) }
        if app == nil, let bundleID {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        // LaunchServices activation works from a background app, which NSRunningApplication.activate
        // no longer reliably does under macOS 14's cooperative activation.
        if let url = app?.bundleURL ?? bundleID.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        } else {
            app?.activate()
        }
    }
}
