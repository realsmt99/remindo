import AppKit

@main
enum RemindoMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        let app = NSApplication.shared

        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            exit(IconRenderer.renderIconSet(to: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            exit(SnapshotRenderer.renderAll(to: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
        }
        if args.contains("--unregister-login") {
            try? LoginItem.set(false)
            exit(0)
        }

        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
