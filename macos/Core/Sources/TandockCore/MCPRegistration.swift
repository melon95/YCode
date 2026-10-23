import Foundation

public enum TandockMCPAgent: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

public enum TandockMCPRegistrationStatus: Equatable, Sendable {
    case installed
    case notInstalled
    /// Registered, but pointing at a helper other than this bundle's (an older
    /// install location or the pre-rename `ycode-mcp`).
    case stale(registered: String)
}

public enum TandockMCPRegistrationError: LocalizedError, Equatable {
    case invalidClaudeDocument
    case invalidClaudeServers
    case unsupportedCodexServers
    case helperMissing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidClaudeDocument:
            "Claude 配置的顶层必须是 JSON 对象。"
        case .invalidClaudeServers:
            "Claude 配置中的 mcpServers 必须是 JSON 对象。"
        case .unsupportedCodexServers:
            "Codex 配置使用了无法安全修改的 mcp_servers 行内值。"
        case let .helperMissing(path):
            "找不到可执行的 tandock-mcp：\(path)"
        }
    }
}

/// Installs only Tandock's `ycode-todos` entry and preserves all unrelated
/// Claude/Codex configuration. Calls are serialized so two settings actions
/// cannot race while replacing the same file.
public actor TandockMCPRegistrationService {
    // The registration key is a compatibility identifier, not the product name.
    public static let serverName = "ycode-todos"

    private let claudeConfigURL: URL
    private let codexConfigURL: URL
    private let helperURL: URL
    private let fileManager: FileManager

    public init(
        homeDirectory: URL,
        helperURL: URL,
        fileManager: FileManager = .default
    ) {
        claudeConfigURL = homeDirectory.appendingPathComponent(".claude.json")
        codexConfigURL = homeDirectory.appendingPathComponent(".codex/config.toml")
        self.helperURL = helperURL
        self.fileManager = fileManager
    }

    public func status(for agent: TandockMCPAgent) throws -> TandockMCPRegistrationStatus {
        switch agent {
        case .claude: try claudeStatus()
        case .codex: try codexStatus()
        }
    }

    @discardableResult
    public func install(for agent: TandockMCPAgent) throws -> TandockMCPRegistrationStatus {
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw TandockMCPRegistrationError.helperMissing(helperURL.path)
        }
        switch agent {
        case .claude: try installClaude()
        case .codex: try installCodex()
        }
        return .installed
    }

    /// Points an existing stale entry at this bundle's helper, changing nothing
    /// else in the entry. Returns whether a change was written.
    @discardableResult
    public func repairStaleHelperPath(for agent: TandockMCPAgent) throws -> Bool {
        guard case .stale = try status(for: agent) else { return false }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw TandockMCPRegistrationError.helperMissing(helperURL.path)
        }
        switch agent {
        case .claude: try repairClaude()
        case .codex: try repairCodex()
        }
        return true
    }

    @discardableResult
    public func uninstall(for agent: TandockMCPAgent) throws -> TandockMCPRegistrationStatus {
        switch agent {
        case .claude: try uninstallClaude()
        case .codex: try uninstallCodex()
        }
        return .notInstalled
    }

    private func claudeStatus() throws -> TandockMCPRegistrationStatus {
        guard fileManager.fileExists(atPath: claudeConfigURL.path) else { return .notInstalled }
        let data = try Data(contentsOf: claudeConfigURL)
        guard !data.isEmpty else { return .notInstalled }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TandockMCPRegistrationError.invalidClaudeDocument
        }
        guard let servers = root["mcpServers"] else { return .notInstalled }
        guard let servers = servers as? [String: Any] else {
            throw TandockMCPRegistrationError.invalidClaudeServers
        }
        guard let entry = servers[Self.serverName] else { return .notInstalled }
        let command = (entry as? [String: Any])?["command"] as? String ?? ""
        return command == helperURL.path ? .installed : .stale(registered: command)
    }

    private func repairClaude() throws {
        try backupOnce(claudeConfigURL)
        var root = try claudeRoot()
        guard var servers = root["mcpServers"] as? [String: Any],
              var entry = servers[Self.serverName] as? [String: Any] else { return }
        entry["command"] = helperURL.path
        servers[Self.serverName] = entry
        root["mcpServers"] = servers
        try writeJSON(root, to: claudeConfigURL)
    }

    private func installClaude() throws {
        try backupOnce(claudeConfigURL)
        var root = try claudeRoot()
        var servers: [String: Any]
        if let value = root["mcpServers"] {
            guard let dictionary = value as? [String: Any] else {
                throw TandockMCPRegistrationError.invalidClaudeServers
            }
            servers = dictionary
        } else {
            servers = [:]
        }
        servers[Self.serverName] = [
            "type": "stdio",
            "command": helperURL.path,
            "args": []
        ]
        root["mcpServers"] = servers
        try writeJSON(root, to: claudeConfigURL)
    }

    private func uninstallClaude() throws {
        guard fileManager.fileExists(atPath: claudeConfigURL.path) else { return }
        let data = try Data(contentsOf: claudeConfigURL)
        guard !data.isEmpty else { return }
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TandockMCPRegistrationError.invalidClaudeDocument
        }
        guard let value = root["mcpServers"] else { return }
        guard var servers = value as? [String: Any] else {
            throw TandockMCPRegistrationError.invalidClaudeServers
        }
        guard servers.removeValue(forKey: Self.serverName) != nil else { return }
        if servers.isEmpty {
            root.removeValue(forKey: "mcpServers")
        } else {
            root["mcpServers"] = servers
        }
        try writeJSON(root, to: claudeConfigURL)
    }

    private func claudeRoot() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: claudeConfigURL.path) else { return [:] }
        let data = try Data(contentsOf: claudeConfigURL)
        guard !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TandockMCPRegistrationError.invalidClaudeDocument
        }
        return root
    }

    private func writeJSON(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(data + Data("\n".utf8), to: url)
    }

    private func codexStatus() throws -> TandockMCPRegistrationStatus {
        guard fileManager.fileExists(atPath: codexConfigURL.path) else { return .notInstalled }
        let raw = try String(contentsOf: codexConfigURL, encoding: .utf8)
        guard let block = codexBlockRange(in: raw) else { return .notInstalled }
        let command = codexCommandLine(in: raw, block: block).flatMap {
            HelperPathText.parseTOMLString(String(raw[$0]))
        } ?? ""
        return command == helperURL.path ? .installed : .stale(registered: command)
    }

    private func repairCodex() throws {
        try backupOnce(codexConfigURL)
        var raw = try String(contentsOf: codexConfigURL, encoding: .utf8)
        guard let block = codexBlockRange(in: raw) else { return }
        let replacement = tomlString(helperURL.path)
        if let line = codexCommandLine(in: raw, block: block) {
            raw.replaceSubrange(line, with: replacement)
        } else {
            // A table without a command line: add one right under the header.
            let header = raw[block].firstIndex(of: "\n").map { raw.index(after: $0) } ?? block.upperBound
            raw.insert(contentsOf: "command = \(replacement)\n", at: header)
        }
        try writeAtomically(Data(raw.utf8), to: codexConfigURL)
    }

    /// Range of the value in the `command = …` line inside the managed table.
    private func codexCommandLine(in raw: String, block: Range<String.Index>) -> Range<String.Index>? {
        guard let line = raw.range(
            of: #"(?m)^[ \t]*command[ \t]*=[ \t]*[^\r\n]*"#,
            options: .regularExpression,
            range: block
        ) else { return nil }
        let text = raw[line]
        guard let equals = text.firstIndex(of: "=") else { return nil }
        var start = text.index(after: equals)
        while start < line.upperBound, raw[start] == " " || raw[start] == "\t" { start = raw.index(after: start) }
        var end = line.upperBound
        while end > start, raw[raw.index(before: end)] == " " || raw[raw.index(before: end)] == "\t" {
            end = raw.index(before: end)
        }
        return start..<end
    }

    private func installCodex() throws {
        try backupOnce(codexConfigURL)
        var raw = fileManager.fileExists(atPath: codexConfigURL.path)
            ? try String(contentsOf: codexConfigURL, encoding: .utf8)
            : ""
        if raw.range(of: #"(?m)^\s*mcp_servers\s*="#, options: .regularExpression) != nil {
            throw TandockMCPRegistrationError.unsupportedCodexServers
        }
        if let range = codexBlockRange(in: raw) { raw.removeSubrange(range) }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { raw += "\n\n" }
        raw += "[mcp_servers.\(Self.serverName)]\ncommand = \(tomlString(helperURL.path))\n"
        try writeAtomically(Data(raw.utf8), to: codexConfigURL)
    }

    private func uninstallCodex() throws {
        guard fileManager.fileExists(atPath: codexConfigURL.path) else { return }
        var raw = try String(contentsOf: codexConfigURL, encoding: .utf8)
        guard let range = codexBlockRange(in: raw) else { return }
        raw.removeSubrange(range)
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try writeAtomically(Data((normalized.isEmpty ? "" : normalized + "\n").utf8), to: codexConfigURL)
    }

    private func codexBlockRange(in raw: String) -> Range<String.Index>? {
        guard let header = raw.range(
            of: #"(?m)^\s*\[\s*mcp_servers\.ycode-todos\s*\]\s*(?:#.*)?(?:\n|$)"#,
            options: .regularExpression
        ) else { return nil }
        let remainder = raw[header.upperBound...]
        let nextHeader = remainder.range(of: #"(?m)^\s*\["#, options: .regularExpression)?.lowerBound
        return header.lowerBound..<(nextHeader ?? raw.endIndex)
    }

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

    private func backupOnce(_ url: URL) throws {
        let backupURL = URL(fileURLWithPath: url.path + ".ycode.bak")
        if fileManager.fileExists(atPath: url.path), !fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.copyItem(at: url, to: backupURL)
        }
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
