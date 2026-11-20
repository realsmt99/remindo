import AppKit
import Darwin

/// Process-tree helpers built on libproc. Used to find which app (Terminal, VS Code,
/// the Claude desktop app...) is hosting an agent, and whether the agent is still alive.
enum ProcessTree {
    struct Info {
        let pid: pid_t
        let ppid: pid_t
        let name: String
        let startSec: UInt64
    }

    struct Host {
        let bundleID: String?
        let pid: pid_t
    }

    /// Wrappers that sit between an agent and its hook command.
    private static let wrappers: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env", "nu", "xonsh", "timeout",
    ]

    static func info(_ pid: pid_t) -> Info? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let longName = withUnsafeBytes(of: bsd.pbi_name) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let shortName = withUnsafeBytes(of: bsd.pbi_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return Info(pid: pid, ppid: pid_t(bsd.pbi_ppid), name: longName.isEmpty ? shortName : longName,
                    startSec: bsd.pbi_start_tvsec)
    }

    /// The hook's parent may be a shell wrapper; climb to the actual agent process.
    static func resolveAgentPID(_ pid: pid_t) -> pid_t {
        var current = pid
        for _ in 0..<4 {
            guard let i = info(current) else { break }
            let name = (i.name as NSString).lastPathComponent.lowercased()
            guard wrappers.contains(name), i.ppid > 1 else { break }
            current = i.ppid
        }
        return current
    }

    /// Walks up from `pid` to the first regular (Dock-visible) app.
    static func hostApp(startingAt pid: pid_t) -> Host? {
        var current = pid
        var seen = Set<pid_t>()
        for _ in 0..<32 {
            guard current > 1, !seen.contains(current) else { break }
            seen.insert(current)
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return Host(bundleID: app.bundleIdentifier, pid: current)
            }
            guard let i = info(current) else { break }
            current = i.ppid
        }
        return nil
    }

    /// Alive, and still the same process we saw (pids get reused).
    static func isAlive(_ pid: pid_t, startSec: UInt64?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH { return false }
        guard let start = startSec else { return true }
        guard let i = info(pid) else { return false }
        return i.startSec == start
    }
}
