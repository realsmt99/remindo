import Foundation

/// Keeps ~/.remindo/bin/remindo in sync with the app and links Claude Code to it.
/// The actual settings.json edit lives in the CLI (`remindo install-claude`), so the
/// terminal and the menu do exactly the same thing.
@MainActor
enum HooksInstaller {
    static var bundledCLI: String? { Bundle.main.path(forResource: "remindo", ofType: nil) }

    /// Copies the CLI that ships inside Remindo.app to ~/.remindo/bin when missing or outdated.
    static func ensureCLI() {
        guard let source = bundledCLI else { return }
        let fm = FileManager.default
        if let bundled = fm.contents(atPath: source), fm.contents(atPath: Paths.cli) == bundled { return }
        Paths.ensureHome()
        let temp = Paths.cli + ".new"
        try? fm.removeItem(atPath: temp)
        do {
            try fm.copyItem(atPath: source, toPath: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: Paths.cli), withItemAt: URL(fileURLWithPath: temp))
        } catch {
            if !fm.fileExists(atPath: Paths.cli) { try? fm.moveItem(atPath: temp, toPath: Paths.cli) }
            NSLog("Remindo: couldn't update the CLI: \(error)")
        }
    }

    static func isClaudeLinked() -> Bool {
        guard let text = try? String(contentsOfFile: Paths.claudeSettings, encoding: .utf8) else { return false }
        return text.contains("/.remindo/bin/remindo")
    }

    static func linkClaude(_ completion: @escaping (Bool, String) -> Void) {
        runCLI(["install-claude"], completion)
    }

    static func unlinkClaude(_ completion: @escaping (Bool, String) -> Void) {
        runCLI(["uninstall-claude"], completion)
    }

    private static func runCLI(_ args: [String], _ completion: @escaping (Bool, String) -> Void) {
        ensureCLI()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", Paths.cli] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { finished in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = finished.terminationStatus == 0
            DispatchQueue.main.async { completion(ok, output) }
        }
        do {
            try process.run()
        } catch {
            completion(false, error.localizedDescription)
        }
    }
}
