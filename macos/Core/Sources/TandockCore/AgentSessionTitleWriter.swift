import Foundation
import Darwin

public enum TandockAgentSessionTitleWriter {
    public enum Outcome: Equatable, Sendable {
        case written
        case unsupported
        case missingFile
        case failed(String)
    }

    @discardableResult
    public static func write(title: String, introspect: String?, jsonlPath: String?,
                             sessionID: String? = nil, command: String = "codex",
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> Outcome {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unsupported }
        if introspect == "codex" {
            guard let sessionID else { return .missingFile }
            do {
                _ = try TandockCodexTitleClient.rename(command: command, sessionID: sessionID, name: trimmed, environment: environment)
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
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { return .failed("无法打开会话文件") }
        defer { Darwin.close(fd) }
        var payload = Data()
        payload.append(10)
        payload.append(line)
        payload.append(10)
        let count = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == payload.count else { return .failed("会话名称写入不完整") }
        return .written
    }

    private static func lastEntryID(in data: Data) -> String? {
        var end = data.endIndex
        while end > data.startIndex {
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

    private static func uniqueEntryID(in data: Data) -> String {
        for _ in 0..<100 {
            let candidate = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            let needle = Data("\"id\":\"\(candidate)\"".utf8)
            if data.range(of: needle) == nil { return candidate }
        }
        return UUID().uuidString.lowercased()
    }
}

private func piTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
