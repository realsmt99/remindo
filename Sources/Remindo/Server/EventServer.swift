import Foundation
import Darwin

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    /// Lowercased header names.
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var body: Data
    var contentType = "application/json"

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        .json(["ok": false, "error": message], status: status)
    }
}

enum ServerError: Error, CustomStringConvertible {
    case posix(String, Int32)
    var description: String {
        switch self {
        case let .posix(call, code): return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A tiny HTTP/1.1 server bound to 127.0.0.1 only. One request per connection.
/// Plain BSD sockets keep it dependency-free and predictable.
final class EventServer {
    static let maxBody = 32 * 1024 * 1024
    static let maxHeader = 64 * 1024

    let port: UInt16
    private let handler: (HTTPRequest) -> HTTPResponse
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "remindo.http.accept")
    private let workQueue = DispatchQueue(label: "remindo.http.work", qos: .userInitiated, attributes: .concurrent)
    /// Hooks are tiny and quick; a handful of slots is plenty and keeps a stalled client from
    /// tying up every worker thread.
    private let slots = DispatchSemaphore(value: 16)
    private static let requestDeadline: TimeInterval = 3

    init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    deinit { stop() }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.posix("socket", errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw ServerError.posix("bind 127.0.0.1:\(port)", err)
        }
        guard listen(fd, 128) == 0 else {
            let err = errno
            close(fd)
            throw ServerError.posix("listen", err)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.drainAccepts() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
    }

    private func drainAccepts() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }  // EAGAIN: nothing left to accept
            // Accepted sockets inherit O_NONBLOCK on Darwin; this server uses blocking I/O with timeouts.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard slots.wait(timeout: .now()) == .success else {
                close(client)  // saturated: shed load rather than queue up threads
                continue
            }
            workQueue.async { [weak self] in
                guard let self else { close(client); return }
                defer { self.slots.signal() }
                self.serve(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var headerEnd: Int?
        var head: (method: String, target: String, headers: [String: String])?
        var contentLength = 0
        let deadline = Date().addingTimeInterval(Self.requestDeadline)

        while true {
            if let end = headerEnd, buffer.count - end >= contentLength { break }
            if Date() > deadline { break }  // slow-drip clients don't get to hold a slot
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }  // closed, error, or timed out
            buffer.append(contentsOf: chunk[0..<n])

            if headerEnd == nil {
                guard let range = buffer.range(of: Data([13, 10, 13, 10])) else {
                    if buffer.count > Self.maxHeader { respond(fd, .error(431, "headers too large")); return }
                    continue
                }
                headerEnd = range.upperBound
                guard let parsed = Self.parseHead(buffer.subdata(in: 0..<range.lowerBound)) else {
                    respond(fd, .error(400, "malformed request"))
                    return
                }
                head = parsed
                if parsed.headers["transfer-encoding"] != nil {
                    respond(fd, .error(411, "send a Content-Length"))
                    return
                }
                contentLength = Int(parsed.headers["content-length"] ?? "0") ?? -1
                guard contentLength >= 0, contentLength <= Self.maxBody else {
                    respond(fd, .error(413, "body too large"))
                    return
                }
                if parsed.headers["expect"]?.lowercased() == "100-continue" {
                    writeAll(fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                }
            }
        }

        guard let head, let end = headerEnd else { return }
        guard buffer.count - end >= contentLength else {
            respond(fd, .error(400, "incomplete body"))
            return
        }
        let body = buffer.subdata(in: end..<(end + contentLength))
        var components = URLComponents(string: "http://localhost" + head.target)
        if components == nil { components = URLComponents() }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(method: head.method, path: components?.path ?? head.target,
                                  query: query, headers: head.headers, body: body)
        respond(fd, handler(request))
    }

    private static func parseHead(_ data: Data) -> (method: String, target: String, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return (String(requestLine[0]).uppercased(), String(requestLine[1]), headers)
    }

    private func respond(_ fd: Int32, _ response: HTTPResponse) {
        let head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
            + "Content-Type: \(response.contentType)\r\n"
            + "Content-Length: \(response.body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        writeAll(fd, data)
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        default: return "Status"
        }
    }
}
