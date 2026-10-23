import Foundation
import TOMLKit

extension TandockAgentCustomizationService {
    public func setMCPEnabled(_ enabled: Bool, record: TandockMCPRecord, agent: TandockCustomizationAgent, project: URL?, environment: [String: String] = [:]) throws {
        guard hasSupportedConfigurationRoot(agent: agent, environment: environment) else { throw TandockCustomizationError.unsupportedConfigurationRoot }
        guard agent.supportsMCP else { throw TandockCustomizationError.unsupported }
        if agent == .claude {
            guard let project else { throw TandockCustomizationError.missingProject }
            let url = claudeStateURL(environment)
            let revision = try read(url)
            var root = try jsonRoot(revision)
            var projects = try jsonDictionary(root["projects"])
            var entry = try jsonDictionary(projects[project.path])
            let existing = entry["disabledMcpServers"]
            guard existing == nil || existing is [String] else { throw TandockCustomizationError.invalidConfiguration }
            var disabled = existing as? [String] ?? []
            disabled.removeAll { $0 == record.name }
            if !enabled { disabled.append(record.name) }
            entry["disabledMcpServers"] = disabled
            projects[project.path] = entry
            root["projects"] = projects
            try write(jsonData(root), to: url, expected: revision)
        } else {
            if agent == .grok {
                let userURL = configURL(agent: .grok, project: nil, environment: environment)
                let user = try read(userURL).map { try tomlObject(String(decoding: $0, as: UTF8.self)) } ?? [:]
                guard !(try stringArray(user["disabled_mcp_servers"])).contains(record.name) else {
                    throw TandockCustomizationError.disabledByGlobalConfiguration
                }
            }
            guard try read(record.source) == record.revision else { throw TandockCustomizationError.changedOnDisk }
            let raw = record.revision.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let updated = try TandockMCPTableEditor.settingEnabled(enabled, name: record.name, in: raw)
            try write(Data(updated.utf8), to: record.source, expected: record.revision)
        }
    }

    func servers(at url: URL, agent: TandockCustomizationAgent, scope: TandockCustomizationScope, project: URL?, environment: [String: String]) throws -> [TandockMCPRecord] {
        guard let data = try read(url) else { return [] }
        let format: TandockMCPDocumentFormat = agent == .claude ? .json : .toml
        let root = format == .json ? try object(data) : try tomlObject(String(decoding: data, as: UTF8.self))
        let entries: [String: JSONValue]
        if scope == .local, let project {
            let projects = try dictionary(root["projects"])
            entries = try dictionary(dictionary(projects[project.path])["mcpServers"])
        } else { entries = try dictionary(root[format == .json ? "mcpServers" : "mcp_servers"]) }
        var disabled: [String] = []
        var rejected: [String] = []
        var globallyDisabled: [String] = []
        if agent == .grok {
            let userURL = configURL(agent: .grok, project: nil, environment: environment)
            let user = try read(userURL).map { try tomlObject(String(decoding: $0, as: UTF8.self)) } ?? [:]
            globallyDisabled = try stringArray(user["disabled_mcp_servers"])
        }
        if agent == .claude, let project {
            let user = try read(claudeStateURL(environment)).map(object) ?? [:]
            disabled = try stringArray(dictionary(dictionary(user["projects"])[project.path])["disabledMcpServers"])
            let local = try read(project.appendingPathComponent(".claude/settings.local.json")).map(object) ?? [:]
            if scope == .project {
                rejected = try stringArray(local["disabledMcpjsonServers"])
                let shared = try read(project.appendingPathComponent(".claude/settings.json")).map(object) ?? [:]
                rejected += try stringArray(shared["disabledMcpjsonServers"])
                let settings = try read(configurationHome(agent: .claude, environment: environment).appendingPathComponent("settings.json")).map(object) ?? [:]
                rejected += try stringArray(settings["disabledMcpjsonServers"])
            }
        }
        return try entries.map { name, value in
            let server = try dictionary(value)
            let enabled = server["enabled"] != .bool(false) && !disabled.contains(name) && !rejected.contains(name) && !globallyDisabled.contains(name)
            let endpoint: String
            if case let .string(url)? = server["url"], let components = URLComponents(string: url) {
                endpoint = (components.scheme ?? "http") + "://" + (components.host ?? "") + (components.port.map { ":\($0)" } ?? "")
            } else if case let .string(command)? = server["command"] {
                endpoint = URL(fileURLWithPath: command).lastPathComponent
            } else { endpoint = "MCP" }
            var record = TandockMCPRecord(name: name, source: url, scope: scope, content: String(decoding: try encode(server), as: UTF8.self),
                                  format: format, endpoint: endpoint, enabled: enabled, revision: data)
            record.requiresApproval = rejected.contains(name)
            record.isDisabledByGlobalConfiguration = globallyDisabled.contains(name)
            return record
        }
    }

    func stringArray(_ value: JSONValue?) throws -> [String] {
        guard let value else { return [] }
        guard case let .array(values) = value else { throw TandockCustomizationError.invalidConfiguration }
        return try values.map { guard case let .string(string) = $0 else { throw TandockCustomizationError.invalidConfiguration }; return string }
    }

    func jsonRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        return try jsonDictionary(JSONSerialization.jsonObject(with: data))
    }

    func jsonDictionary(_ value: Any?) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let dictionary = value as? [String: Any] else { throw TandockCustomizationError.invalidConfiguration }
        return dictionary
    }

    func jsonData(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    func dictionary(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard let value else { return [:] }
        guard case let .object(values) = value else { throw TandockCustomizationError.invalidConfiguration }
        return values
    }

    func object(_ data: Data) throws -> [String: JSONValue] {
        do { return try dictionary(JSONDecoder().decode(JSONValue.self, from: data)) }
        catch { throw TandockCustomizationError.invalidConfiguration }
    }

    func encode(_ object: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(object) + Data("\n".utf8)
    }

    func tomlObject(_ raw: String) throws -> [String: JSONValue] {
        do { return try object(Data(TOMLTable(string: raw).convert(to: .json).utf8)) }
        catch { throw TandockCustomizationError.invalidConfiguration }
    }
}

enum TandockMCPTableEditor {
    static func settingEnabled(_ enabled: Bool, name: String, in raw: String) throws -> String {
        func parsed(_ text: String) throws -> [String: JSONValue] {
            do {
                let json = try TOMLTable(string: text).convert(to: .json)
                guard case let .object(root) = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { throw TandockCustomizationError.invalidConfiguration }
                return root
            } catch { throw TandockCustomizationError.invalidConfiguration }
        }
        var expected = try parsed(raw)
        guard case var .object(servers)? = expected["mcp_servers"], case var .object(server)? = servers[name] else { throw TandockCustomizationError.invalidConfiguration }
        server["enabled"] = .bool(enabled)
        servers[name] = .object(server)
        expected["mcp_servers"] = .object(servers)
        var lines = raw.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { headerPath($0) == ["mcp_servers", name] }) else { throw TandockCustomizationError.invalidConfiguration }
        let end = lines.indices.dropFirst(start + 1).first { headerPath(lines[$0]) != nil } ?? lines.count
        if let index = ((start + 1)..<end).first(where: { lines[$0].range(of: #"^\s*enabled\s*="#, options: .regularExpression) != nil }) {
            let regex = try NSRegularExpression(pattern: #"^(\s*enabled\s*=\s*)(?:true|false)"#)
            let line = lines[index]
            lines[index] = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1" + (enabled ? "true" : "false"))
        } else { lines.insert("enabled = " + (enabled ? "true" : "false"), at: start + 1) }
        let updated = lines.joined(separator: "\n")
        guard try parsed(updated) == expected else { throw TandockCustomizationError.invalidConfiguration }
        return updated
    }

    static func headerPath(_ raw: String) -> [String]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("[") else { return nil }
        if text.hasPrefix("[[") { text.removeFirst() }
        var parts: [String] = [], token = "", quote: Character?, escaped = false
        for character in text.dropFirst() {
            if let current = quote {
                if escaped { token.append(character); escaped = false }
                else if character == "\\" && current == "\"" { escaped = true }
                else if character == current { quote = nil }
                else { token.append(character) }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "." { parts.append(token.trimmingCharacters(in: .whitespaces)); token = "" }
            else if character == "]" { parts.append(token.trimmingCharacters(in: .whitespaces)); return parts }
            else { token.append(character) }
        }
        return nil
    }
}
