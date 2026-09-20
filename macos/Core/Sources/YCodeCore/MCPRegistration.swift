import Foundation

public enum YCodeMCPAgent: String, CaseIterable, Identifiable, Sendable {
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

public enum YCodeMCPRegistrationStatus: String, Sendable {
    case installed
    case notInstalled
}

public enum YCodeMCPRegistrationError: LocalizedError, Equatable {
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
            "找不到可执行的 ycode-mcp：\(path)"
        }
    }
}

/// Installs only YCode's `ycode-todos` entry and preserves all unrelated
/// Claude/Codex configuration. Calls are serialized so two settings actions
/// cannot race while replacing the same file.
public actor YCodeMCPRegistrationService {
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

    public func status(for agent: YCodeMCPAgent) throws -> YCodeMCPRegistrationStatus {
        switch agent {
        case .claude: try claudeStatus()
        case .codex: try codexStatus()
        }
    }

    @discardableResult
    public func install(for agent: YCodeMCPAgent) throws -> YCodeMCPRegistrationStatus {
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw YCodeMCPRegistrationError.helperMissing(helperURL.path)
        }
        switch agent {
        case .claude: try installClaude()
        case .codex: try installCodex()
        }
        return .installed
    }

    @discardableResult
    public func uninstall(for agent: YCodeMCPAgent) throws -> YCodeMCPRegistrationStatus {
        switch agent {
        case .claude: try uninstallClaude()
        case .codex: try uninstallCodex()
        }
        return .notInstalled
    }

    private func claudeStatus() throws -> YCodeMCPRegistrationStatus {
        guard fileManager.fileExists(atPath: claudeConfigURL.path) else { return .notInstalled }
        let data = try Data(contentsOf: claudeConfigURL)
        guard !data.isEmpty else { return .notInstalled }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YCodeMCPRegistrationError.invalidClaudeDocument
        }
        guard let servers = root["mcpServers"] else { return .notInstalled }
        guard let servers = servers as? [String: Any] else {
            throw YCodeMCPRegistrationError.invalidClaudeServers
        }
        return servers[Self.serverName] == nil ? .notInstalled : .installed
    }

    private func installClaude() throws {
        try backupOnce(claudeConfigURL)
        var root = try claudeRoot()
        var servers: [String: Any]
        if let value = root["mcpServers"] {
            guard let dictionary = value as? [String: Any] else {
                throw YCodeMCPRegistrationError.invalidClaudeServers
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
            throw YCodeMCPRegistrationError.invalidClaudeDocument
        }
        guard let value = root["mcpServers"] else { return }
        guard var servers = value as? [String: Any] else {
            throw YCodeMCPRegistrationError.invalidClaudeServers
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
            throw YCodeMCPRegistrationError.invalidClaudeDocument
        }
        return root
    }

    private func writeJSON(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(data + Data("\n".utf8), to: url)
    }

    private func codexStatus() throws -> YCodeMCPRegistrationStatus {
        guard fileManager.fileExists(atPath: codexConfigURL.path) else { return .notInstalled }
        let raw = try String(contentsOf: codexConfigURL, encoding: .utf8)
        return codexBlockRange(in: raw) == nil ? .notInstalled : .installed
    }

    private func installCodex() throws {
        try backupOnce(codexConfigURL)
        var raw = fileManager.fileExists(atPath: codexConfigURL.path)
            ? try String(contentsOf: codexConfigURL, encoding: .utf8)
            : ""
        if raw.range(of: #"(?m)^\s*mcp_servers\s*="#, options: .regularExpression) != nil {
            throw YCodeMCPRegistrationError.unsupportedCodexServers
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
