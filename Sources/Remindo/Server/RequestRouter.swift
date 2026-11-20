import Foundation

/// Routes HTTP requests from the `remindo` CLI. Runs on the server's background queue;
/// hands finished events to the main actor through `deliver`.
///
///   POST /v1/hook/<agent>   raw hook JSON (Claude Code, Codex, Gemini CLI, ...)
///   POST /v1/event          generic update: agent, state, title, message, session, cwd
///   GET  /v1/status         current sessions
///   POST /v1/test           play a demo (scenario=demo|working|approval|question|done|error)
///   GET  /health
final class RequestRouter {
    private let port: UInt16
    private let token: String
    private let deliver: (AgentEvent) -> Void
    private let status: () -> Data
    private let test: (String) -> Void

    private struct CachedHost {
        let start: UInt64?
        let bundleID: String?
        let hostPID: pid_t?
    }
    private let lock = NSLock()
    private var hostCache: [pid_t: CachedHost] = [:]

    init(port: UInt16, token: String, deliver: @escaping (AgentEvent) -> Void, status: @escaping () -> Data,
         test: @escaping (String) -> Void) {
        self.port = port
        self.token = token
        self.deliver = deliver
        self.status = status
        self.test = test
    }

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        // Only local tools may talk to us: no browsers (they always send Origin), no DNS rebinding.
        if req.headers["origin"] != nil || req.headers["sec-fetch-mode"] != nil {
            return .error(403, "browser requests are not accepted")
        }
        if let host = req.headers["host"]?.lowercased(), !isLocal(host) {
            return .error(403, "unexpected Host header")
        }
        if req.path == "/health" || req.path == "/" {
            return .json(["ok": true, "app": "Remindo", "version": AppInfo.version, "port": Int(port)])
        }
        guard req.headers["x-remindo-client"] != nil else {
            return .error(403, "missing X-Remindo-Client header")
        }
        guard let presented = req.headers["x-remindo-token"], Self.constantTimeEqual(presented, token) else {
            return .error(403, "missing or wrong X-Remindo-Token (see ~/.remindo/token)")
        }

        switch (req.method, req.path) {
        case ("POST", let path) where path.hasPrefix("/v1/hook/"):
            return hook(agent: String(path.dropFirst("/v1/hook/".count)), req)
        case ("POST", "/v1/event"):
            return generic(req)
        case ("GET", "/v1/status"):
            return HTTPResponse(status: 200, body: status())
        case ("POST", "/v1/test"):
            test(fields(req)["scenario"] ?? "demo")
            return .json(["ok": true])
        default:
            return .error(404, "unknown route \(req.method) \(req.path)")
        }
    }

    private func isLocal(_ host: String) -> Bool {
        let allowed = ["127.0.0.1", "localhost", "[::1]"]
        return allowed.contains(host) || allowed.contains { host == "\($0):\(port)" }
    }

    // MARK: Routes

    private func hook(agent raw: String, _ req: HTTPRequest) -> HTTPResponse {
        let agent = raw.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        guard let object = try? JSONSerialization.jsonObject(with: req.body),
              let payload = object as? [String: Any] else {
            return .error(400, "expected a JSON object")
        }
        let origin = Self.origin(req)
        let fallback = "\(agent.isEmpty ? "agent" : agent)-\(origin.pid.map { String($0) } ?? "anon")"
        guard var event = HookAdapter.event(agent: agent, payload: payload, timestamp: Self.timestamp(req),
                                            fallbackSession: fallback) else {
            return .json(["ok": true, "ignored": true])
        }
        event.origin = origin
        resolveHost(&event)
        deliver(event)
        return .json(["ok": true])
    }

    private func generic(_ req: HTTPRequest) -> HTTPResponse {
        let origin = Self.origin(req)
        guard var event = HookAdapter.genericEvent(fields: fields(req), timestamp: Self.timestamp(req),
                                                   originPID: origin.pid) else {
            return .error(400, "state must be one of working, done, approval, waiting, error, idle, start, end")
        }
        event.origin = origin
        resolveHost(&event)
        deliver(event)
        return .json(["ok": true, "session": event.sessionID])
    }

    // MARK: Helpers

    /// Figures out which app hosts the agent (so a click can bring you back to it) while the
    /// hook process is still alive: the HTTP response hasn't been sent yet.
    private func resolveHost(_ e: inout AgentEvent) {
        if let pid = e.origin.pid, pid > 1 {
            let agentPID = ProcessTree.resolveAgentPID(pid)
            let start = ProcessTree.info(agentPID)?.startSec
            e.agentPID = agentPID
            e.agentStart = start

            lock.lock()
            let cached = hostCache[agentPID]
            lock.unlock()

            if let cached, cached.start == start {
                e.hostBundleID = cached.bundleID
                e.hostPID = cached.hostPID
            } else {
                let host = ProcessTree.hostApp(startingAt: agentPID)
                e.hostBundleID = host?.bundleID
                e.hostPID = host?.pid
                lock.lock()
                if hostCache.count > 512 { hostCache.removeAll() }
                hostCache[agentPID] = CachedHost(start: start, bundleID: host?.bundleID, hostPID: host?.pid)
                lock.unlock()
            }
        }
        // tmux & co. detach from the terminal's process tree; the inherited bundle id still knows.
        if e.hostBundleID == nil, let bundle = e.origin.bundleID { e.hostBundleID = bundle }
    }

    private func fields(_ req: HTTPRequest) -> [String: String] {
        var out = req.query
        let type = req.headers["content-type"]?.lowercased() ?? ""
        if type.contains("json") {
            if let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] {
                for (key, value) in obj { out[key] = (value as? String) ?? "\(value)" }
            }
        } else if !req.body.isEmpty {
            for (key, value) in Self.parseForm(req.body) { out[key] = value }
        }
        return out
    }

    static func parseForm(_ body: Data) -> [String: String] {
        guard let text = String(data: body, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let plus = s.replacingOccurrences(of: "+", with: " ")
                return plus.removingPercentEncoding ?? plus
            }
            guard let first = parts.first else { continue }
            out[decode(first)] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return out
    }

    static func origin(_ req: HTTPRequest) -> EventOrigin {
        var o = EventOrigin()
        if let raw = req.headers["x-remindo-pid"], let pid = Int32(raw.trimmingCharacters(in: .whitespaces)), pid > 1 {
            o.pid = pid
        }
        if let bundle = req.headers["x-remindo-bundle"], !bundle.isEmpty { o.bundleID = bundle }
        if let term = req.headers["x-remindo-term"], !term.isEmpty { o.termProgram = term }
        return o
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    static func timestamp(_ req: HTTPRequest) -> Double {
        if let raw = req.headers["x-remindo-ts"]?.replacingOccurrences(of: ",", with: "."),
           let value = Double(raw), value > 1_000_000_000 {
            return value
        }
        return Date().timeIntervalSince1970
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
