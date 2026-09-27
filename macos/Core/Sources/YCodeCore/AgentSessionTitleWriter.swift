import Foundation
import Darwin

/// Persist names through each CLI's native metadata format/API. Running pi instances
/// must use the extension bridge so their in-memory session tree stays consistent.
public enum YCodeAgentSessionTitleWriter {
    public enum Outcome: Equatable, Sendable {
        /// 名字已经写进会话文件。
        case written
        /// 这家 CLI 的会话文件格式里没有可追加的标题字段。
        case unsupported
        /// 支持，但这条会话在磁盘上还没有文件（刚建、CLI 还没落盘）。
        case missingFile
        case failed(String)
    }

    /// - Parameter introspect: agent profile 的 `introspect` 解析器 id（`pi` / `claude` / `codex`…），
    ///   跟历史扫描用的是同一个口径，别再引入第二套 agent 判定。
    @discardableResult
    public static func write(title: String, introspect: String?, jsonlPath: String?,
                             sessionID: String? = nil, command: String = "codex",
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> Outcome {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unsupported }
        if introspect == "codex" {
            guard let sessionID else { return .missingFile }
            do {
                _ = try YCodeCodexTitleClient.rename(command: command, sessionID: sessionID, name: trimmed, environment: environment)
                return .written
            } catch { return .failed(error.localizedDescription) }
        }
        guard introspect == "pi" || introspect == "claude" else { return .unsupported }
        guard let jsonlPath, !jsonlPath.isEmpty else { return .missingFile }
        let url = URL(fileURLWithPath: jsonlPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missingFile }
        if introspect == "claude" {
            guard let sessionID else { return .missingFile }
            do {
                let line = try JSONSerialization.data(withJSONObject: ["type": "custom-title", "customTitle": trimmed, "sessionId": sessionID])
                return append(line: line, to: url)
            } catch { return .failed(error.localizedDescription) }
        }
        return appendPiSessionInfo(title: trimmed, url: url)
    }

    /// pi 的条目形状（见 `dist/core/session-manager.js` 的 `appendSessionInfo`）：
    /// `{"type":"session_info","id":<8 位>,"parentId":<上一条的 id 或 null>,"timestamp":…,"name":…}`。
    /// `name` 里的换行按 pi 自己的规矩折成空格，否则一条记录会被拆成两行 JSONL。
    private static func appendPiSessionInfo(title: String, url: URL) -> Outcome {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return .failed("读不到会话文件：\(url.path)")
        }
        let name = title
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let entry: [String: Any] = [
            "type": "session_info",
            "id": uniqueEntryID(in: data),
            // 挂在当前最后一条下面。pi 自己下一次追加仍然用它内存里的 leaf，
            // 于是同一个父节点下会多出一个分支——这不影响取名字：
            // `getSessionName()` 扫的是文件顺序，不是树。
            "parentId": lastEntryID(in: data) ?? NSNull(),
            "timestamp": piTimestamp(Date()),
            "name": name
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return .failed("会话标题无法序列化")
        }
        return append(line: line, to: url)
    }

    private static func append(line: Data, to url: URL) -> Outcome {
        // O_APPEND is essential: seekToEnd + write can overwrite a concurrent CLI append.
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { return .failed("无法打开会话文件") }
        defer { Darwin.close(fd) }
        var payload = Data()
        // A leading newline also separates an interrupted final record; blank JSONL lines are valid.
        payload.append(10)
        payload.append(line)
        payload.append(10)
        let count = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == payload.count else { return .failed("会话名称写入不完整") }
        return .written
    }

    /// 文件里最后一条非空记录的 id。解析失败就返回 nil —— 挂成孤儿节点也能被读到名字。
    private static func lastEntryID(in data: Data) -> String? {
        var end = data.endIndex
        while end > data.startIndex {
            // 跳过末尾的换行。
            while end > data.startIndex, data[data.index(before: end)] == 0x0A {
                end = data.index(before: end)
            }
            guard end > data.startIndex else { return nil }
            var start = end
            while start > data.startIndex, data[data.index(before: start)] != 0x0A {
                start = data.index(before: start)
            }
            let line = data[start..<end]
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let id = object["id"] as? String, !id.isEmpty {
                return id
            }
            end = start
        }
        return nil
    }

    /// pi 用 8 位十六进制做 id，并保证文件内不重复。我们在外部追加，拿不到它的 `byId`，
    /// 就在文件里找一遍——重复的 id 会让 pi 重建树时把两条记录认成同一条。
    private static func uniqueEntryID(in data: Data) -> String {
        for _ in 0..<100 {
            let candidate = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            let needle = Data("\"id\":\"\(candidate)\"".utf8)
            if data.range(of: needle) == nil { return candidate }
        }
        return UUID().uuidString.lowercased()
    }
}

/// pi 写的是 JS `toISOString()`：带毫秒的 Z 时间。改名是低频动作，
/// 现建一个 formatter 就好，不为复用去做非 Sendable 的全局量。
private func piTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
