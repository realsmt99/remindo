import Foundation

/// Reads the tail of a Claude Code transcript (JSONL) without loading the whole file.
/// Paths come from hook payloads, so only regular files are opened and reads are bounded.
enum TranscriptReader {
    /// Size of a regular file, or nil (missing, a FIFO, a device...).
    static func size(of path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }

    /// Lines from max(`from`, size - maxBytes) to the end of the file.
    private static func tailLines(path: String, maxBytes: Int, from: UInt64? = nil) -> [Substring] {
        guard let size = size(of: path) else { return [] }
        var start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        if let from { start = max(start, min(from, size)) }
        guard start < size, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Starting mid-file probably cut the first line in half.
        if start > 0 && from == nil, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func object(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func texts(in message: [String: Any]) -> [String] {
        if let s = message["content"] as? String { return [s] }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }
    }

    /// The final text the assistant wrote, if any.
    static func lastAssistantText(path: String) -> String? {
        for line in tailLines(path: path, maxBytes: 768 * 1024).reversed() {
            guard line.contains("\"assistant\""), let obj = object(line),
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            let text = texts(in: message).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// True when the newest conversational entry written after `offset` is Claude Code's
    /// "[Request interrupted by user]" marker.
    static func interrupted(path: String, after offset: UInt64?) -> Bool {
        for line in tailLines(path: path, maxBytes: 64 * 1024, from: offset).reversed() {
            guard let obj = object(line), let type = obj["type"] as? String else { continue }
            guard type == "user" || type == "assistant" else { continue }
            guard type == "user", let message = obj["message"] as? [String: Any] else { return false }
            if let blocks = message["content"] as? [[String: Any]],
               blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                return false
            }
            return texts(in: message).contains { $0.hasPrefix("[Request interrupted by user") }
        }
        return false
    }
}
