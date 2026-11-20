import Foundation

/// Plays fake agent events so you can preview every animation.
@MainActor
enum Demo {
    static func run(store: SessionStore, scenario: String) {
        let id = "remindo-demo-\(scenario)"
        let cwd = NSHomeDirectory() + "/Projects/remindo"
        var clock = Date().timeIntervalSince1970

        func event(_ action: AgentEvent.Action, detail: String? = nil, prompt: String? = nil,
                   summary: String? = nil) -> AgentEvent {
            clock += 0.01
            var e = AgentEvent(agentID: "claude-code", sessionID: id, action: action, timestamp: clock)
            e.cwd = cwd
            e.detail = detail
            e.prompt = prompt
            e.summary = summary
            return e
        }

        let start = event(.turnStart, prompt: "Make the notch reminder animated")
        var steps: [(TimeInterval, AgentEvent)]
        switch scenario {
        case "working":
            steps = [(0, start), (0.3, event(.activity, detail: "Editing SparkView.swift"))]
        case "approval":
            steps = [(0, start), (0.5, event(.approval(toolUseID: nil), detail: "Run: npm install --save express"))]
        case "question":
            steps = [(0, start), (0.5, event(.question, detail: "Which database should I use: SQLite or Postgres?"))]
        case "done":
            steps = [(0, start), (0.6, event(.done, summary: "Added the notch animation and wired up the Claude Code hooks."))]
        case "error":
            steps = [(0, start), (0.6, event(.failed, detail: "API overloaded, try again in a minute"))]
        default:
            steps = [
                (0, start),
                (0.4, event(.activity, detail: "Reading NotchView.swift")),
                (3.5, event(.approval(toolUseID: nil), detail: "Run: swift build -c release")),
                (7.5, event(.resolved(toolUseID: nil))),
                (7.6, event(.activity, detail: "Running swift build")),
                (11, event(.done, summary: "Built Remindo and linked it to Claude Code. Everything passes.")),
            ]
        }

        store.remove(id)
        for (delay, e) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { store.apply(e) }
            }
        }
        let last = steps.map(\.0).max() ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + last + 30) {
            MainActor.assumeIsolated { store.remove(id) }
        }
    }
}
