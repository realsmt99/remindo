import AppKit
import SwiftUI

// MARK: - Agent state

/// What an agent session is doing, from the human's point of view.
enum AgentState: String, Codable, CaseIterable {
    case idle
    case working
    case approval   // blocked on a permission prompt
    case waiting    // blocked on an answer, or idle at the prompt
    case done
    case error

    /// Higher wins when several sessions compete for the notch.
    var rank: Int {
        switch self {
        case .approval: return 50
        case .waiting: return 40
        case .error: return 35
        case .done: return 30
        case .working: return 20
        case .idle: return 0
        }
    }

    var accent: Color {
        switch self {
        case .working: return Palette.claude
        case .approval: return Palette.amber
        case .waiting: return Palette.blue
        case .done: return Palette.green
        case .error: return Palette.red
        case .idle: return Palette.muted
        }
    }

    var symbolName: String {
        switch self {
        case .working: return "ellipsis"
        case .approval: return "hand.raised.fill"
        case .waiting: return "bubble.left.fill"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "moon.zzz.fill"
        }
    }
}

enum Palette {
    /// Claude's coral.
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let amber = Color(red: 1.0, green: 0.706, blue: 0.180)
    static let blue = Color(red: 0.392, green: 0.667, blue: 1.0)
    static let green = Color(red: 0.231, green: 0.827, blue: 0.443)
    static let red = Color(red: 1.0, green: 0.333, blue: 0.290)
    static let muted = Color(white: 0.6)
    static let codex = Color(white: 0.93)
    static let gemini = Color(red: 0.42, green: 0.55, blue: 1.0)

    static let nsClaude = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
}

// MARK: - Agents

enum AgentCatalog {
    static func displayName(_ id: String) -> String {
        switch id.lowercased() {
        case "claude-code", "claude", "claudecode", "claude_code": return "Claude Code"
        case "codex", "codex-cli": return "Codex"
        case "gemini", "gemini-cli": return "Gemini CLI"
        case "cursor": return "Cursor"
        case "aider": return "Aider"
        case "agent", "": return "Agent"
        default:
            return id.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    static func isClaude(_ id: String) -> Bool { id.lowercased().hasPrefix("claude") }

    /// The spark is Claude's coral for Claude, and a neutral tint for everyone else.
    static func tint(_ id: String) -> Color {
        let lower = id.lowercased()
        if lower.hasPrefix("claude") { return Palette.claude }
        if lower.hasPrefix("codex") { return Palette.codex }
        if lower.hasPrefix("gemini") { return Palette.gemini }
        return Color(white: 0.9)
    }
}

/// The same whimsical vibe as Claude Code's spinner.
enum Verbs {
    static let all = [
        "Cooking", "Brewing", "Clauding", "Pondering", "Simmering", "Noodling",
        "Percolating", "Conjuring", "Marinating", "Tinkering", "Crafting", "Mulling",
        "Whisking", "Baking", "Concocting", "Scheming",
    ]
    static func random() -> String { all.randomElement() ?? "Cooking" }
}

// MARK: - Events

/// Where an event came from: the hook process, as seen by the CLI.
struct EventOrigin: Equatable {
    var pid: pid_t?
    var bundleID: String?
    var termProgram: String?
}

/// A normalized agent event. Hook payloads from any agent are mapped onto these.
struct AgentEvent {
    enum Action: Equatable {
        case sessionStart
        /// The human sent a prompt: a new turn starts.
        case turnStart
        /// The agent is doing something (tool started, etc.).
        case activity
        /// Informational only; never changes the state.
        case note
        /// The agent is blocked on an answer from the human (question tool, MCP elicitation).
        case question
        /// A tool finished (or was denied): any approval it was waiting on is over.
        case resolved(toolUseID: String?)
        case approval(toolUseID: String?)
        /// Idle at the prompt, waiting for the next instruction.
        case waiting
        case done
        case failed
        case sessionEnd
        /// Generic API: set a state directly.
        case set(AgentState)
    }

    var agentID: String
    var sessionID: String
    var action: Action
    var timestamp: Double
    var cwd: String?
    var detail: String?
    var prompt: String?
    var summary: String?
    var title: String?
    var transcriptPath: String?
    /// The tool call an event belongs to, when the agent says (pairs a question with its answer).
    var toolUseID: String?
    var origin = EventOrigin()
    // Resolved by the router from the process tree.
    var agentPID: pid_t?
    var agentStart: UInt64?
    var hostBundleID: String?
    var hostPID: pid_t?

    init(agentID: String, sessionID: String, action: Action, timestamp: Double) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.action = action
        self.timestamp = timestamp
    }
}

// MARK: - Sessions

struct AgentSession: Identifiable, Equatable {
    let id: String
    var agentID: String
    var cwd: String?
    var state: AgentState = .idle
    /// Approval and question states stay until the agent resolves them; the rest clear once seen.
    var persistent = false
    var acknowledged = true
    var detail: String?
    var activity: String?
    var prompt: String?
    var summary: String?
    var customTitle: String?
    var turnStartedAt: Date?
    var finishedAt: Date?
    var lastEventAt: Date
    var lastEventTS: Double = 0
    var hostBundleID: String?
    var hostPID: pid_t?
    var agentPID: pid_t?
    var agentStart: UInt64?
    var transcriptPath: String?
    var pendingToolUseID: String?
    /// The settled state an approval/question interrupted (a background agent asking after the turn ended).
    var stateBeforeBlock: AgentState?
    /// Transcript size when the current turn started; interrupts are only looked for after it.
    var transcriptBaseline: UInt64?
    var verb: String = Verbs.random()
    /// Bumps whenever something new needs the human.
    var attentionSerial = 0
    let createdAt: Date
    var attentionAt: Date?

    init(id: String, agentID: String, now: Date = Date()) {
        self.id = id
        self.agentID = agentID
        self.lastEventAt = now
        self.createdAt = now
    }

    var agentName: String { AgentCatalog.displayName(agentID) }
    var isClaude: Bool { AgentCatalog.isClaude(agentID) }
    var tint: Color { AgentCatalog.tint(agentID) }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return agentName }
        let name = (cwd as NSString).lastPathComponent
        return (name.isEmpty || name == "/") ? agentName : name
    }

    /// Blocked on the human (a permission prompt or a question), seen or not.
    var isBlocked: Bool { state == .approval || (state == .waiting && persistent) }

    /// True while the notch should keep reminding: something new the human hasn't looked at yet.
    /// Visiting the agent's app counts as looking (you can't approve without seeing the prompt).
    var needsAttention: Bool {
        switch state {
        case .approval, .waiting, .done, .error: return !acknowledged
        case .working, .idle: return false
        }
    }

    /// Worth showing on the notch right now.
    var isLive: Bool { state == .working || isBlocked || needsAttention }

    var displayRank: Int {
        if needsAttention { return state.rank }
        if isBlocked { return 22 }
        return state == .working ? AgentState.working.rank : 0
    }

    /// Stable ordering: importance first, then the newest call for attention, then first seen.
    func outranks(_ other: AgentSession) -> Bool {
        if displayRank != other.displayRank { return displayRank > other.displayRank }
        let mine = attentionAt ?? .distantPast, theirs = other.attentionAt ?? .distantPast
        if mine != theirs { return mine > theirs }
        if createdAt != other.createdAt { return createdAt < other.createdAt }
        return id < other.id
    }

    func elapsed(at now: Date = Date()) -> TimeInterval? {
        guard let start = turnStartedAt else { return nil }
        return max(0, (finishedAt ?? now).timeIntervalSince(start))
    }
}

// MARK: - Formatting

enum Format {
    /// "42s", "3m 12s", "1h 04m"
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    /// "0:42", "12:05", "1:02:03"
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Fits the compact wing: "0:42", "12:05", "1h02".
    static func shortClock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s >= 3600 { return String(format: "%dh%02d", s / 3600, (s % 3600) / 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 10 { return "now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    /// Collapses whitespace and trims to `limit` characters.
    static func oneLine(_ text: String, limit: Int = 160) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// First meaningful line of a (markdown) message, cleaned up for a one-line preview.
    static func summary(_ text: String, limit: Int = 150) -> String? {
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("|") || line.hasPrefix("---") { continue }
            while let first = line.first, "#>-*+".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            if line.count < 2 { continue }
            return oneLine(line, limit: limit)
        }
        return nil
    }
}
