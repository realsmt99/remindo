import AppKit
import Combine

/// Owns every agent session and turns raw events into human-facing state.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [String: AgentSession] = [:]

    /// Fired after an event put a session into a state the human should see.
    var onAttention: ((AgentSession) -> Void)?

    private let transcriptQueue = DispatchQueue(label: "remindo.transcripts", qos: .utility)
    private var transcriptMTimes: [String: Date] = [:]
    private var maintenance: Timer?

    // MARK: Queries

    /// All sessions, most important first, in a stable order (rows don't jump around).
    var ordered: [AgentSession] {
        sessions.values.sorted { $0.outranks($1) }
    }

    /// The session that deserves the notch right now.
    var focus: AgentSession? {
        sessions.values.filter(\.isLive).min { $0.outranks($1) }
    }

    var liveCount: Int { sessions.values.filter(\.isLive).count }

    /// The most important session waiting on the human, optionally ignoring the app they're already in.
    func attentionFocus(excludingHost host: String? = nil) -> AgentSession? {
        sessions.values
            .filter { $0.needsAttention && (host == nil || $0.hostBundleID != host) }
            .min { $0.outranks($1) }
    }

    func workingSession(hostBundleID: String) -> AgentSession? {
        sessions.values
            .filter { $0.state == .working && $0.hostBundleID == hostBundleID }
            .min { $0.outranks($1) }
    }

    func hasSessions(hostBundleID: String) -> Bool {
        sessions.values.contains { $0.hostBundleID == hostBundleID }
    }

    var hasFinished: Bool {
        sessions.values.contains { [.done, .error, .idle].contains($0.state) || ($0.state == .waiting && !$0.persistent) }
    }

    // MARK: Events

    func apply(_ e: AgentEvent) {
        let now = Date()

        if case .sessionEnd = e.action {
            guard var s = sessions[e.sessionID] else { return }
            if s.needsAttention && (s.state == .done || s.state == .error) {
                // The agent quit, but the human hasn't seen the result yet: keep the reminder.
                s.agentPID = nil
                s.lastEventAt = now
                sessions[s.id] = s
            } else {
                remove(e.sessionID)
            }
            return
        }

        let isNew = sessions[e.sessionID] == nil
        var s = sessions[e.sessionID] ?? AgentSession(id: e.sessionID, agentID: e.agentID, now: now)

        // Async hooks can arrive out of order; never let an older event overwrite a newer state.
        if e.timestamp + 0.000_5 < s.lastEventTS {
            mergeMetadata(&s, e)
            sessions[s.id] = s
            return
        }
        s.lastEventTS = max(s.lastEventTS, e.timestamp)
        s.lastEventAt = now
        mergeMetadata(&s, e)

        let previous = s.state
        /// The session already finished a turn: stray tool events (background agents) mustn't revive it.
        let settled = [.done, .error, .idle].contains(previous) && (s.turnStartedAt != nil || s.finishedAt != nil)
        var attention = false

        switch e.action {
        case .sessionStart:
            break

        case .turnStart:
            s.state = .working
            s.persistent = false
            s.acknowledged = true
            s.turnStartedAt = now
            s.finishedAt = nil
            s.summary = nil
            s.detail = nil
            s.activity = nil
            s.customTitle = e.title
            s.pendingToolUseID = nil
            s.stateBeforeBlock = nil
            s.verb = Verbs.random()
            s.transcriptBaseline = s.transcriptPath.flatMap(TranscriptReader.size(of:))
            if let prompt = e.prompt { s.prompt = Format.oneLine(prompt, limit: 140) }

        case .activity:
            if let d = e.detail { s.activity = d }
            // Blocked prompts are cleared by their own answer (.resolved), not by a parallel tool.
            if s.state == .working || s.isBlocked { break }
            // A turn that started without a prompt (background agents waking Claude up, a
            // scheduled run), a missed turn start, or Remindo launched mid-turn.
            beginWorking(&s, now: now, keepTimer: false)

        case .note:
            if s.state == .working, let d = e.detail { s.activity = d }

        case .question:
            let duplicate = previous == .waiting && s.persistent && (e.detail == nil || e.detail == s.detail)
            if !s.isBlocked { s.stateBeforeBlock = settled ? previous : nil }
            if !duplicate || s.pendingToolUseID == nil { s.pendingToolUseID = e.toolUseID }
            s.state = .waiting
            s.persistent = true
            s.detail = e.detail ?? s.detail ?? "Has a question for you"
            if s.turnStartedAt == nil { s.turnStartedAt = now }
            if !duplicate {
                s.acknowledged = false
                attention = true
            }

        case .resolved(let toolUseID):
            switch s.state {
            case _ where s.isBlocked:
                if s.pendingToolUseID == nil || toolUseID == nil || toolUseID == s.pendingToolUseID {
                    unblock(&s, now: now)
                }
            case .working:
                break
            default:
                if !settled { beginWorking(&s, now: now, keepTimer: false) }
            }

        case .approval(let toolUseID):
            // A generic "needs permission" notification while a question is open is that question.
            if previous == .waiting && s.persistent && toolUseID == nil { break }
            if previous == .approval
                && (toolUseID == nil || s.pendingToolUseID == nil || toolUseID == s.pendingToolUseID) {
                // The same prompt reported twice (PermissionRequest + Notification, either order):
                // keep the most precise tool id and detail, and don't ring twice.
                if let toolUseID {
                    s.pendingToolUseID = toolUseID
                    if let d = e.detail { s.detail = d }
                } else if s.detail == nil {
                    s.detail = e.detail
                }
                break
            }
            if !s.isBlocked { s.stateBeforeBlock = settled ? previous : nil }
            s.state = .approval
            s.persistent = true
            s.acknowledged = false
            s.pendingToolUseID = toolUseID
            s.detail = e.detail ?? "Needs your permission"
            if s.turnStartedAt == nil { s.turnStartedAt = now }
            attention = true

        case .waiting:
            // Claude Code says this after ~60s idle at the prompt. Only worth a nudge if the
            // human hasn't already seen the result, and never over a pending approval or question.
            if s.isBlocked { break }
            if (s.state == .done || s.state == .idle || s.state == .error) && s.acknowledged { break }
            if s.state == .waiting { break }
            s.state = .waiting
            s.persistent = false
            s.acknowledged = false
            s.detail = e.detail ?? "Waiting for your next prompt"
            attention = true

        case .done:
            // Claude Code fires Stop in a few non-turn situations too; only celebrate real turns,
            // or a turn that started before Remindo was watching (it carries the final message).
            let turnWasRunning = [.working, .approval, .waiting].contains(previous)
            if s.isClaude && !turnWasRunning {
                // A repeat of the Stop we already announced; but a new final message means a new
                // (prompt-less) turn finished, e.g. Claude woke up after background work.
                let message = e.summary.flatMap { Format.summary($0) }
                if previous == .done && (message == nil || message == s.summary) { break }
                if previous == .idle && !(isNew && e.summary != nil) { break }
            }
            s.state = .done
            s.persistent = false
            s.acknowledged = false
            s.finishedAt = now
            s.pendingToolUseID = nil
            s.stateBeforeBlock = nil
            s.detail = nil
            if let title = e.title { s.customTitle = title }
            if let summary = e.summary.flatMap({ Format.summary($0) }) {
                s.summary = summary
            } else if let path = s.transcriptPath {
                loadSummary(sessionID: s.id, path: path, serial: s.attentionSerial + 1)
            }
            attention = true

        case .failed:
            s.state = .error
            s.persistent = false
            s.acknowledged = false
            s.finishedAt = now
            s.pendingToolUseID = nil
            s.stateBeforeBlock = nil
            s.detail = e.detail.map { Format.oneLine($0, limit: 140) } ?? "Something went wrong"
            attention = true

        case .set(let state):
            switch state {
            case .working:
                if s.state != .working { beginWorking(&s, now: now, keepTimer: false) }
                if let d = e.detail { s.activity = d }
                if let t = e.title { s.customTitle = t }
            case .idle:
                s.state = .idle
                s.persistent = false
                s.acknowledged = true
                s.detail = e.detail
                s.pendingToolUseID = nil
                s.stateBeforeBlock = nil
            default:
                s.state = state
                s.persistent = false
                s.acknowledged = false
                s.detail = e.detail
                if state == .done || state == .error { s.finishedAt = now }
                if let t = e.title { s.customTitle = t }
                attention = true
            }

        case .sessionEnd:
            break
        }

        if attention {
            s.attentionSerial += 1
            s.attentionAt = now
        }
        sessions[s.id] = s
        if attention { onAttention?(s) }
    }

    private func mergeMetadata(_ s: inout AgentSession, _ e: AgentEvent) {
        if let cwd = e.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let path = e.transcriptPath, !path.isEmpty { s.transcriptPath = path }
        if let pid = e.agentPID {
            s.agentPID = pid
            s.agentStart = e.agentStart
        }
        if let bundle = e.hostBundleID { s.hostBundleID = bundle }
        if let pid = e.hostPID { s.hostPID = pid }
    }

    private func beginWorking(_ s: inout AgentSession, now: Date, keepTimer: Bool) {
        if s.state != .working && !keepTimer { s.verb = Verbs.random() }
        s.state = .working
        s.persistent = false
        s.acknowledged = true
        s.pendingToolUseID = nil
        s.stateBeforeBlock = nil
        s.detail = nil
        s.finishedAt = nil
        if !keepTimer || s.turnStartedAt == nil { s.turnStartedAt = now }
    }

    /// An approval or question was answered: back to work, or back to rest if the turn had already ended.
    private func unblock(_ s: inout AgentSession, now: Date) {
        if let before = s.stateBeforeBlock {
            s.state = before
            s.persistent = false
            s.acknowledged = true
            s.pendingToolUseID = nil
            s.stateBeforeBlock = nil
            s.detail = nil
        } else {
            beginWorking(&s, now: now, keepTimer: true)
        }
    }

    // MARK: Human actions

    func acknowledge(_ id: String) {
        guard var s = sessions[id] else { return }
        s.acknowledged = true
        if s.state == .waiting && !s.persistent { s.state = .idle }
        sessions[id] = s
    }

    /// The human is in the agent's app: everything there counts as seen, including a pending
    /// prompt (they're looking at it). It stays on the notch until it's resolved, just quietly.
    func acknowledgeAll(hostBundleID: String) {
        for (id, s) in sessions where s.hostBundleID == hostBundleID && !s.acknowledged {
            acknowledge(id)
        }
    }

    func clearFinished() {
        for (id, s) in sessions {
            let finished = [.done, .error, .idle].contains(s.state) || (s.state == .waiting && !s.persistent)
            if finished { remove(id) }
        }
    }

    func remove(_ id: String) {
        sessions.removeValue(forKey: id)
        transcriptMTimes.removeValue(forKey: id)
    }

    // MARK: Transcripts

    private func loadSummary(sessionID: String, path: String, serial: Int) {
        transcriptQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            let text = TranscriptReader.lastAssistantText(path: path).flatMap { Format.summary($0) }
            guard let text else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, var s = self.sessions[sessionID],
                          s.attentionSerial == serial, s.state == .done else { return }
                    s.summary = text
                    self.sessions[sessionID] = s
                }
            }
        }
    }

    /// Esc in Claude Code ends a turn without a Stop hook; the transcript is the only witness.
    /// Only lines written after this turn started count, so an old marker can't end a new turn.
    private func checkTranscriptForInterrupt(_ s: AgentSession) {
        guard let path = s.transcriptPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let mtime = attrs[.modificationDate] as? Date else { return }
        if transcriptMTimes[s.id] == mtime { return }
        transcriptMTimes[s.id] = mtime
        let id = s.id
        let stamp = s.lastEventTS
        let baseline = s.transcriptBaseline
        transcriptQueue.async { [weak self] in
            guard TranscriptReader.interrupted(path: path, after: baseline) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, var cur = self.sessions[id], cur.lastEventTS == stamp,
                          [.working, .approval, .waiting].contains(cur.state) else { return }
                    cur.state = .idle
                    cur.persistent = false
                    cur.acknowledged = true
                    cur.pendingToolUseID = nil
                    cur.stateBeforeBlock = nil
                    cur.detail = "Interrupted"
                    cur.finishedAt = Date()
                    self.sessions[id] = cur
                }
            }
        }
    }

    // MARK: Maintenance

    func startMaintenance() {
        guard maintenance == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        maintenance = timer
    }

    private func tick() {
        let now = Date()
        for s in Array(sessions.values) {
            if let pid = s.agentPID, !ProcessTree.isAlive(pid, startSec: s.agentStart) {
                agentExited(s.id)
                continue
            }
            let quiet = now.timeIntervalSince(s.lastEventAt)
            switch s.state {
            case .working, .approval:
                if quiet > 2 * 3600 {
                    markIdle(s.id, detail: "No news for a while")
                } else {
                    checkTranscriptForInterrupt(s)
                }
            case .waiting where s.persistent:
                checkTranscriptForInterrupt(s)
            case .idle:
                if quiet > 4 * 3600 { remove(s.id) }
            case .done, .error, .waiting:
                if (s.acknowledged && quiet > 4 * 3600) || quiet > 12 * 3600 { remove(s.id) }
            }
        }
    }

    private func agentExited(_ id: String) {
        guard var s = sessions[id] else { return }
        if s.needsAttention && (s.state == .done || s.state == .error) {
            s.agentPID = nil
            sessions[id] = s
        } else {
            remove(id)
        }
    }

    private func markIdle(_ id: String, detail: String) {
        guard var s = sessions[id] else { return }
        s.state = .idle
        s.persistent = false
        s.acknowledged = true
        s.stateBeforeBlock = nil
        s.detail = detail
        sessions[id] = s
    }

    // MARK: Status API

    func statusJSON() -> Data {
        let iso = ISO8601DateFormatter()
        let items: [[String: Any]] = ordered.map { s in
            var d: [String: Any] = [
                "id": s.id,
                "agent": s.agentID,
                "state": s.state.rawValue,
                "project": s.projectName,
                "needsAttention": s.needsAttention,
                "acknowledged": s.acknowledged,
                "lastEventAt": iso.string(from: s.lastEventAt),
            ]
            if let v = s.cwd { d["cwd"] = v }
            if let v = s.detail { d["detail"] = v }
            if let v = s.activity { d["activity"] = v }
            if let v = s.prompt { d["prompt"] = v }
            if let v = s.summary { d["summary"] = v }
            if let v = s.hostBundleID { d["host"] = v }
            if let v = s.agentPID { d["pid"] = Int(v) }
            if let v = s.turnStartedAt { d["turnStartedAt"] = iso.string(from: v) }
            if let v = s.elapsed() { d["elapsedSeconds"] = Int(v) }
            return d
        }
        let payload: [String: Any] = ["ok": true, "sessions": items]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}
