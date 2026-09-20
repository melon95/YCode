import Foundation

public enum YCodeHookRegistrationStatus: Equatable, Sendable {
    case installed
    case notInstalled
    case conflictUserNotify(existing: [String])
}

public enum YCodeHookRegistrationError: LocalizedError, Equatable {
    case helperMissing(String)
    case invalidClaudeDocument
    case invalidClaudeHooks
    case invalidClaudeEvent(String)
    case invalidCodexNotify

    public var errorDescription: String? {
        switch self {
        case let .helperMissing(path): "找不到可执行的 ycode-notify：\(path)"
        case .invalidClaudeDocument: "Claude settings.json 顶层必须是对象。"
        case .invalidClaudeHooks: "Claude settings.json 的 hooks 必须是对象。"
        case let .invalidClaudeEvent(event): "Claude hooks.\(event) 必须是数组。"
        case .invalidCodexNotify: "Codex 的 notify 必须是字符串参数数组。"
        }
    }
}

/// Additive config patcher for Claude hooks and ownership-marked Codex
/// notify/PermissionRequest hooks. Uninstall removes only YCode's entries;
/// chained Codex notify commands are restored byte-for-value.
public actor YCodeHookRegistrationService {
    public static let claudeMarkerKey = "_ycode_managed"
    public static let codexNotifyMarker = "# ycode-managed (do not edit this line or the one below)"
    public static let codexHooksStart = "# ycode-managed-hooks (do not edit between this line and the matching end marker)"
    public static let codexHooksEnd = "# ycode-managed-hooks-end"

    private let claudeSettingsURL: URL
    private let codexConfigURL: URL
    private let helperURL: URL
    private let fileManager: FileManager

    public init(homeDirectory: URL, helperURL: URL, fileManager: FileManager = .default) {
        claudeSettingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        codexConfigURL = homeDirectory.appendingPathComponent(".codex/config.toml")
        self.helperURL = helperURL
        self.fileManager = fileManager
    }

    public func status(for agent: YCodeMCPAgent) throws -> YCodeHookRegistrationStatus {
        switch agent {
        case .claude: try claudeStatus()
        case .codex: try codexStatus()
        }
    }

    @discardableResult
    public func install(for agent: YCodeMCPAgent, chainExistingCodexNotify: Bool = false) throws -> YCodeHookRegistrationStatus {
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw YCodeHookRegistrationError.helperMissing(helperURL.path)
        }
        switch agent {
        case .claude:
            try installClaude()
            return .installed
        case .codex:
            return try installCodex(chainExisting: chainExistingCodexNotify)
        }
    }

    @discardableResult
    public func uninstall(for agent: YCodeMCPAgent) throws -> YCodeHookRegistrationStatus {
        switch agent {
        case .claude: try uninstallClaude()
        case .codex: try uninstallCodex()
        }
        return .notInstalled
    }

    private func claudeStatus() throws -> YCodeHookRegistrationStatus {
        guard fileManager.fileExists(atPath: claudeSettingsURL.path) else { return .notInstalled }
        let root = try claudeRoot()
        return hasClaudeEntry(root, event: "Stop") && hasClaudeEntry(root, event: "Notification")
            ? .installed : .notInstalled
    }

    private func installClaude() throws {
        try backupOnce(claudeSettingsURL)
        var root = try claudeRoot()
        let quotedHelper = shellQuote(helperURL.path)
        for (event, command, matcher) in [
            ("Stop", "\(quotedHelper) stop claude", ""),
            ("Notification", "\(quotedHelper) notification claude", "permission_prompt")
        ] {
            try removeClaudeEntries(&root, event: event)
            try appendClaudeEntry(&root, event: event, command: command, matcher: matcher)
        }
        try writeJSON(root, to: claudeSettingsURL)
    }

    private func uninstallClaude() throws {
        guard fileManager.fileExists(atPath: claudeSettingsURL.path) else { return }
        var root = try claudeRoot()
        try removeClaudeEntries(&root, event: "Stop")
        try removeClaudeEntries(&root, event: "Notification")
        if var hooks = root["hooks"] as? [String: Any] {
            hooks = hooks.filter { !($0.value as? [Any] ?? []).isEmpty }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        try writeJSON(root, to: claudeSettingsURL)
    }

    private func claudeRoot() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: claudeSettingsURL.path) else { return [:] }
        let data = try Data(contentsOf: claudeSettingsURL)
        guard !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YCodeHookRegistrationError.invalidClaudeDocument
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) {
            throw YCodeHookRegistrationError.invalidClaudeHooks
        }
        return root
    }

    private func hasClaudeEntry(_ root: [String: Any], event: String) -> Bool {
        let hooks = root["hooks"] as? [String: Any]
        let entries = hooks?[event] as? [[String: Any]]
        return entries?.contains { $0[Self.claudeMarkerKey] as? Bool == true } == true
    }

    private func removeClaudeEntries(_ root: inout [String: Any], event: String) throws {
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        guard let value = hooks[event] else { return }
        guard var entries = value as? [[String: Any]] else {
            throw YCodeHookRegistrationError.invalidClaudeEvent(event)
        }
        entries.removeAll { $0[Self.claudeMarkerKey] as? Bool == true }
        hooks[event] = entries
        root["hooks"] = hooks
    }

    private func appendClaudeEntry(
        _ root: inout [String: Any],
        event: String,
        command: String,
        matcher: String
    ) throws {
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if root["hooks"] != nil, !(root["hooks"] is [String: Any]) {
            throw YCodeHookRegistrationError.invalidClaudeHooks
        }
        var entries: [[String: Any]]
        if let value = hooks[event] {
            guard let existing = value as? [[String: Any]] else {
                throw YCodeHookRegistrationError.invalidClaudeEvent(event)
            }
            entries = existing
        } else {
            entries = []
        }
        entries.append([
            Self.claudeMarkerKey: true,
            "matcher": matcher,
            "hooks": [["type": "command", "command": command]]
        ])
        hooks[event] = entries
        root["hooks"] = hooks
    }

    private func codexStatus() throws -> YCodeHookRegistrationStatus {
        guard fileManager.fileExists(atPath: codexConfigURL.path) else { return .notInstalled }
        let raw = try String(contentsOf: codexConfigURL, encoding: .utf8)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notInstalled }
        let ownsNotify = raw.contains(Self.codexNotifyMarker)
        let ownsHooks = raw.contains(Self.codexHooksStart) && raw.contains(Self.codexHooksEnd)
        if let (_, value) = topLevelNotify(in: raw) {
            if !ownsNotify {
                guard let existing = parseTOMLStringArray(value) else {
                    throw YCodeHookRegistrationError.invalidCodexNotify
                }
                return .conflictUserNotify(existing: existing)
            }
            return ownsHooks ? .installed : .notInstalled
        }
        return .notInstalled
    }

    private func installCodex(chainExisting: Bool) throws -> YCodeHookRegistrationStatus {
        let current = try codexStatus()
        if case let .conflictUserNotify(existing) = current {
            guard chainExisting else { return current }
            try writeCodex(existingChain: existing)
            return .installed
        }
        try writeCodex(existingChain: nil)
        return .installed
    }

    private func writeCodex(existingChain: [String]?) throws {
        try backupOnce(codexConfigURL)
        var raw = fileManager.fileExists(atPath: codexConfigURL.path)
            ? try String(contentsOf: codexConfigURL, encoding: .utf8) : ""
        raw = stripCodexManagedNotify(raw)
        raw = stripCodexHooks(raw)
        if existingChain != nil, let (range, _) = topLevelNotify(in: raw) { raw.removeSubrange(range) }

        var arguments = [helperURL.path, "turn_complete", "codex"]
        if let existingChain {
            let data = try JSONSerialization.data(withJSONObject: existingChain)
            arguments += ["--next", String(decoding: data, as: UTF8.self)]
        }
        let notify = "\n\(Self.codexNotifyMarker)\nnotify = \(tomlArray(arguments))\n"
        raw = insertBeforeFirstTable(notify, in: raw)
        raw = appendCodexHooks(to: raw)
        try writeText(raw, to: codexConfigURL)
    }

    private func uninstallCodex() throws {
        guard fileManager.fileExists(atPath: codexConfigURL.path) else { return }
        var raw = try String(contentsOf: codexConfigURL, encoding: .utf8)
        guard raw.contains(Self.codexNotifyMarker) || raw.contains(Self.codexHooksStart) else { return }
        var restored: [String]?
        if let (_, value) = topLevelNotify(in: raw),
           let arguments = parseTOMLStringArray(value),
           let nextIndex = arguments.firstIndex(of: "--next"),
           arguments.indices.contains(nextIndex + 1),
           let data = arguments[nextIndex + 1].data(using: .utf8) {
            restored = try? JSONSerialization.jsonObject(with: data) as? [String]
        }
        raw = stripCodexManagedNotify(raw)
        raw = stripCodexHooks(raw)
        if let restored { raw = insertBeforeFirstTable("notify = \(tomlArray(restored))\n", in: raw) }
        try writeText(raw, to: codexConfigURL)
    }

    private func topLevelNotify(in raw: String) -> (Range<String.Index>, String)? {
        let firstTable = raw.range(of: #"(?m)^\s*\["#, options: .regularExpression)?.lowerBound ?? raw.endIndex
        let root = raw[..<firstTable]
        guard let range = root.range(
            of: #"(?m)^\s*notify\s*=\s*(\[[^\n]*\])\s*(?:#.*)?(?:\n|$)"#,
            options: .regularExpression
        ) else { return nil }
        let line = String(raw[range])
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return (range, String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseTOMLStringArray(_ raw: String) -> [String]? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = value.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return decoded
        }
        guard value.first == "[", let close = value.lastIndex(of: "]") else { return nil }
        var index = value.index(after: value.startIndex)
        var result: [String] = []
        while index < close {
            while index < close, value[index].isWhitespace || value[index] == "," { index = value.index(after: index) }
            guard index < close else { break }
            let quote = value[index]
            guard quote == "\"" || quote == "'" else { return nil }
            let start = index
            index = value.index(after: index)
            var escaped = false
            while index < close {
                let character = value[index]
                if quote == "\"", character == "\\", !escaped {
                    escaped = true
                    index = value.index(after: index)
                    continue
                }
                if character == quote, !escaped { break }
                escaped = false
                index = value.index(after: index)
            }
            guard index < close else { return nil }
            let token = String(value[start...index])
            if quote == "'" {
                result.append(String(token.dropFirst().dropLast()))
            } else {
                guard let data = token.data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data) as? String else { return nil }
                result.append(decoded)
            }
            index = value.index(after: index)
        }
        return result
    }

    private func stripCodexManagedNotify(_ raw: String) -> String {
        var output = ""
        var skipNext = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces) == Self.codexNotifyMarker {
                skipNext = true
                continue
            }
            if skipNext, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                skipNext = false
                continue
            }
            output += line + "\n"
        }
        return output
    }

    private func stripCodexHooks(_ raw: String) -> String {
        var output = ""
        var inside = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == Self.codexHooksStart { inside = true; continue }
            if inside {
                if trimmed == Self.codexHooksEnd { inside = false }
                continue
            }
            output += line + "\n"
        }
        return output
    }

    private func insertBeforeFirstTable(_ block: String, in raw: String) -> String {
        if let table = raw.range(of: #"(?m)^\s*\["#, options: .regularExpression) {
            var output = String(raw[..<table.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty { output += "\n" }
            output += block.trimmingCharacters(in: .newlines) + "\n\n"
            output += raw[table.lowerBound...]
            return output
        }
        var output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { output += "\n" }
        output += block.trimmingCharacters(in: .newlines) + "\n"
        return output
    }

    private func appendCodexHooks(to raw: String) -> String {
        let command = "\(shellQuote(helperURL.path)) permission_request codex"
        let block = """
        \(Self.codexHooksStart)
        [[hooks.PermissionRequest]]
        matcher = ".*"

        [[hooks.PermissionRequest.hooks]]
        type = "command"
        command = \(tomlString(command))
        timeout = 5
        \(Self.codexHooksEnd)
        """
        var output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { output += "\n\n" }
        return output + block + "\n"
    }

    private func tomlArray(_ values: [String]) -> String { "[\(values.map(tomlString).joined(separator: ", "))]" }

    private func tomlString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    private func shellQuote(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }

    private func backupOnce(_ url: URL) throws {
        let backup = URL(fileURLWithPath: url.path + ".ycode.bak")
        if fileManager.fileExists(atPath: url.path), !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: url, to: backup)
        }
    }

    private func writeJSON(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        try write(data, to: url)
    }

    private func writeText(_ value: String, to url: URL) throws { try write(Data(value.utf8), to: url) }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
