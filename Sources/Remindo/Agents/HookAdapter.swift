import Foundation

/// Maps raw hook payloads (Claude Code first, plus Codex / Gemini CLI / Cursor style
/// payloads) onto Remindo events. Unknown events are ignored rather than guessed at.
enum HookAdapter {
    /// Tools that block on the human until they answer.
    static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    static func event(agent rawAgent: String, payload p: [String: Any], timestamp: Double,
                      fallbackSession: String) -> AgentEvent? {
        let agent = rawAgent.isEmpty ? "agent" : rawAgent.lowercased()
        let name = normalize(string(p, "hook_event_name", "hookEventName", "event", "type") ?? "")
        let session = string(p, "session_id", "sessionId", "thread-id", "thread_id", "conversation_id",
                             "conversationId") ?? fallbackSession

        var e = AgentEvent(agentID: agent, sessionID: session, action: .note, timestamp: timestamp)
        e.cwd = string(p, "cwd", "project_dir", "workspace") ?? (p["workspace_roots"] as? [String])?.first
        e.transcriptPath = string(p, "transcript_path", "transcriptPath")

        let toolName = string(p, "tool_name", "toolName")
        let toolInput = (p["tool_input"] as? [String: Any]) ?? (p["toolInput"] as? [String: Any])
        let toolUseID = string(p, "tool_use_id", "toolUseId")
        e.toolUseID = toolUseID

        switch name {
        case "sessionstart":
            e.action = .sessionStart

        case "userpromptsubmit", "beforeagent", "beforesubmitprompt":
            e.action = .turnStart
            e.prompt = string(p, "prompt", "user_prompt")

        case "pretooluse", "beforetool", "beforeshellexecution", "beforemcpexecution", "beforereadfile":
            if let tool = toolName, questionTools.contains(tool) {
                e.action = .question
                e.detail = questionDetail(tool: tool, input: toolInput)
            } else {
                // Tool calls from inside a subagent (possibly a background one that outlives the
                // turn) describe what's happening but never restart a finished session.
                e.action = string(p, "agent_id", "agentId") == nil ? .activity : .note
                e.detail = describe(tool: toolName ?? fallbackTool(for: name), input: toolInput ?? p)
            }

        case "posttooluse", "posttoolusefailure", "permissiondenied", "aftertool", "afterfileedit",
             "aftershellexecution", "aftermcpexecution", "elicitationresult":
            e.action = .resolved(toolUseID: toolUseID)

        case "permissionrequest":
            if let tool = toolName, questionTools.contains(tool) {
                // AskUserQuestion / ExitPlanMode are shown through the permission prompt too.
                e.action = .question
                e.detail = questionDetail(tool: tool, input: toolInput)
            } else {
                e.action = .approval(toolUseID: toolUseID)
                e.detail = approvalDetail(tool: toolName, input: toolInput)
            }

        case "notification":
            let type = normalize(string(p, "notification_type", "notificationType") ?? "")
            let message = string(p, "message")
            switch type {
            case "permissionprompt", "toolpermission":
                e.action = .approval(toolUseID: nil)
                e.detail = message
            case "idleprompt":
                e.action = .waiting
                e.detail = message
            case "elicitationdialog":
                e.action = .question
                e.detail = message ?? "An MCP server needs your input"
            case "":
                guard let m = message?.lowercased() else { return nil }
                if m.contains("permission") || m.contains("approve") {
                    e.action = .approval(toolUseID: nil)
                } else if m.contains("waiting for your input") {
                    e.action = .waiting
                } else {
                    return nil
                }
                e.detail = message
            default:
                return nil  // auth_success, elicitation_complete, ...
            }

        case "elicitation":
            e.action = .question
            e.detail = string(p, "message") ?? "An MCP server needs your input"

        case "stop", "afteragent", "agentturncomplete":
            if let background = p["background_tasks"] as? [Any], !background.isEmpty {
                // The turn paused, but background agents are still running and will wake
                // Claude up for another turn: still cooking, not finished.
                e.action = .note
                e.detail = background.count == 1 ? "Waiting on a background task" : "Waiting on \(background.count) background tasks"
            } else {
                e.action = .done
                e.summary = string(p, "last_assistant_message", "last-assistant-message", "lastAssistantMessage")
            }

        case "stopfailure":
            e.action = .failed
            e.detail = errorText(p) ?? "The turn ended with an error"

        case "subagentstart":
            e.action = .note
            e.detail = "Subagent: " + (string(p, "agent_type", "subagent_type") ?? "working")

        case "subagentstop":
            e.action = .note
            e.detail = "Subagent finished"

        case "precompact", "precompress":
            e.action = .note
            e.detail = "Compacting the conversation"

        case "sessionend":
            e.action = .sessionEnd

        default:
            return nil
        }
        return e
    }

    /// The generic `/v1/event` API (`remindo notify`), for agents without hooks.
    static func genericEvent(fields f: [String: String], timestamp: Double, originPID: pid_t?) -> AgentEvent? {
        func field(_ key: String) -> String? {
            guard let v = f[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        let agent = (field("agent") ?? "agent").lowercased()
        guard let state = field("state")?.lowercased() else { return nil }
        let action: AgentEvent.Action
        switch state {
        case "working", "thinking", "busy", "running", "cooking", "start-turn": action = .set(.working)
        case "done", "finished", "complete", "completed", "success", "stop": action = .done
        case "approval", "permission", "needs-approval", "approve", "blocked": action = .approval(toolUseID: nil)
        case "waiting", "input", "question", "ask": action = .question
        case "idle", "ready": action = .set(.idle)
        case "error", "failed", "failure": action = .failed
        case "start", "session-start", "begin": action = .sessionStart
        case "end", "exit", "session-end", "quit": action = .sessionEnd
        default: return nil
        }
        let cwd = field("cwd")
        let session = field("session") ?? "\(agent):\(cwd ?? originPID.map { String($0) } ?? "default")"
        var e = AgentEvent(agentID: agent, sessionID: session, action: action, timestamp: timestamp)
        e.cwd = cwd
        e.title = field("title")
        e.prompt = field("prompt")
        let message = field("message")
        if action == .done { e.summary = message } else { e.detail = message }
        return e
    }

    // MARK: Descriptions

    static func describe(tool: String?, input: [String: Any]?) -> String? {
        guard let tool else { return nil }
        let i = input ?? [:]
        func s(_ key: String) -> String? {
            guard let v = i[key] as? String, !v.isEmpty else { return nil }
            return Format.oneLine(v, limit: 80)
        }
        func file(_ key: String) -> String? { s(key).map { ($0 as NSString).lastPathComponent } }

        switch tool {
        case "Bash", "PowerShell", "Shell", "run_shell_command":
            if let d = s("description") { return d }
            return s("command").map { "Running \($0)" } ?? "Running a command"
        case "Read", "read_file": return "Reading \(file("file_path") ?? file("path") ?? "a file")"
        case "Write", "write_file": return "Writing \(file("file_path") ?? file("path") ?? "a file")"
        case "Edit", "MultiEdit", "replace": return "Editing \(file("file_path") ?? file("path") ?? "a file")"
        case "NotebookEdit": return "Editing \(file("notebook_path") ?? "a notebook")"
        case "Glob": return "Finding \(s("pattern") ?? "files")"
        case "Grep", "search_file_content": return "Searching for \(s("pattern").map { "“\($0)”" } ?? "text")"
        case "WebFetch", "web_fetch": return "Reading \(s("url").flatMap { URL(string: $0)?.host } ?? "a web page")"
        case "WebSearch", "google_web_search": return "Searching the web" + (s("query").map { ": \($0)" } ?? "")
        case "Task", "Agent": return "Delegating: \(s("description") ?? "a subagent")"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Updating the plan"
        case "Skill": return "Using the \(s("skill") ?? s("command") ?? "") skill"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__").filter { !$0.isEmpty }
                if parts.count >= 3 { return "Using \(parts[1]) › \(parts[2...].joined(separator: "_"))" }
            }
            return "Using \(tool)"
        }
    }

    static func approvalDetail(tool: String?, input: [String: Any]?) -> String? {
        guard let tool else { return nil }
        let i = input ?? [:]
        func s(_ key: String) -> String? {
            guard let v = i[key] as? String, !v.isEmpty else { return nil }
            return Format.oneLine(v, limit: 90)
        }
        switch tool {
        case "Bash", "PowerShell": return s("command").map { "Run: \($0)" } ?? "Run a shell command"
        case "Write": return "Create \(s("file_path").map { ($0 as NSString).lastPathComponent } ?? "a file")"
        case "Edit", "MultiEdit", "NotebookEdit":
            return "Edit \((s("file_path") ?? s("notebook_path")).map { ($0 as NSString).lastPathComponent } ?? "a file")"
        case "WebFetch": return "Open \(s("url").flatMap { URL(string: $0)?.host } ?? "a web page")"
        default:
            return describe(tool: tool, input: input).map { "Allow: \($0)" }
        }
    }

    static func questionDetail(tool: String, input: [String: Any]?) -> String {
        if tool == "ExitPlanMode" { return "A plan is ready for your review" }
        if let questions = input?["questions"] as? [[String: Any]],
           let first = questions.first?["question"] as? String {
            return Format.oneLine(first, limit: 110)
        }
        return "Has a question for you"
    }

    // MARK: Helpers

    private static func fallbackTool(for event: String) -> String? {
        switch event {
        case "beforeshellexecution": return "Bash"
        case "beforereadfile": return "Read"
        default: return nil
        }
    }

    private static func errorText(_ p: [String: Any]) -> String? {
        if let s = string(p, "error_message", "message", "reason") { return s }
        if let s = p["error"] as? String, !s.isEmpty { return s }
        if let o = p["error"] as? [String: Any] { return (o["message"] as? String) ?? (o["type"] as? String) }
        return nil
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " }
    }

    static func string(_ p: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let v = p[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }
}
