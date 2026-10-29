import Foundation

public enum TandockCustomizationAgent: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, grok, pi
    public var id: String { rawValue }
    public var supportsMCP: Bool { self != .pi }

    public static func resolve(_ profile: TandockAgentProfile) -> Self? {
        let name = URL(fileURLWithPath: profile.command).lastPathComponent
        return Self(rawValue: name)
    }
}

public enum TandockCustomizationScope: String, Sendable { case user, project, shared, local }

public struct TandockSkillRecord: Identifiable, Sendable {
    public var id: String { directory.path }
    public let directory: URL
    public let root: URL
    public let scope: TandockCustomizationScope
    public let name: String
    public let summary: String
    public let content: String
    public let revision: Data
    public var enabled: Bool? = true
    public var stateDetail: String = ""
    public var isLinked: Bool { directory.standardizedFileURL != directory.resolvingSymlinksInPath().standardizedFileURL }
}

public struct TandockMCPRecord: Identifiable, Sendable {
    public var id: String { source.path + "#" + scope.rawValue + "#" + name }
    public let name: String
    public let source: URL
    public let scope: TandockCustomizationScope
    public let content: String
    public let format: TandockMCPDocumentFormat
    public let endpoint: String
    public let enabled: Bool
    public let revision: Data?
    public var requiresApproval = false
    public var isShadowed = false
    public var isDisabledByGlobalConfiguration = false
}

public enum TandockMCPDocumentFormat: Sendable { case json, toml }

public enum TandockCustomizationError: Error, LocalizedError, Equatable {
    case invalidSkill, invalidConfiguration, changedOnDisk, unsupported, missingProject, unsupportedProjectSkills, disabledByGlobalConfiguration, unsupportedConfigurationRoot
    public var errorDescription: String? {
        switch self {
        case .invalidSkill: "无法读取 SKILL.md，请检查文件编码。"
        case .invalidConfiguration: "配置格式暂不支持安全修改，原文件未更改。"
        case .changedOnDisk: "文件已被其他程序修改，请刷新后重试。"
        case .unsupported: "此 CLI 没有可管理的原生 MCP 配置。"
        case .missingProject: "Claude Code 的 MCP 启停按项目保存，请先选择项目。"
        case .unsupportedProjectSkills: "Grok 不支持项目技能开关，请切换到全局范围。"
        case .disabledByGlobalConfiguration: "此 MCP 已在 Grok 的全局禁用名单中，请先在 CLI 配置中移除。"
        case .unsupportedConfigurationRoot: "自定义 CLI 配置目录需要使用绝对路径；当前配置无法安全管理。"
        }
    }
}

public struct TandockCustomizationSnapshot: Sendable {
    public var skills: [TandockSkillRecord] = []
    public var servers: [TandockMCPRecord] = []
    public var issues: [String] = []
    public var skillDestination: URL
    public var mcpDestination: URL
}

public actor TandockAgentCustomizationService {
    let home: URL
    let fm: FileManager

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        home = homeDirectory
        fm = fileManager
    }

    public func snapshot(agent: TandockCustomizationAgent, project: URL? = nil, environment: [String: String] = [:]) -> TandockCustomizationSnapshot {
        guard hasSupportedConfigurationRoot(agent: agent, environment: environment) else {
            return TandockCustomizationSnapshot(issues: [TandockCustomizationError.unsupportedConfigurationRoot.localizedDescription],
                skillDestination: configurationHome(agent: agent, environment: [:]).appendingPathComponent("skills"),
                mcpDestination: configURL(agent: agent, project: project, environment: [:]))
        }
        let roots = skillRoots(agent: agent, project: project, environment: environment)
        var result = TandockCustomizationSnapshot(
            skillDestination: roots.first { $0.1 == (project == nil ? .user : .project) }!.0,
            mcpDestination: configURL(agent: agent, project: project, environment: environment)
        )
        var seen: Set<String> = []
        for (root, scope) in roots where fm.fileExists(atPath: root.path) {
            do {
                for directory in try skillDirectories(root: root) {
                    let identity = agent == .pi ? directory.path : directory.resolvingSymlinksInPath().path
                    guard seen.insert(identity).inserted else { continue }
                    do { result.skills.append(try skill(directory: directory, root: root, scope: scope)) }
                    catch { result.issues.append("\(directory.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch { result.issues.append("\(root.path): \(error.localizedDescription)") }
        }
        do { try applySkillStates(to: &result.skills, agent: agent, project: project, environment: environment) }
        catch {
            result.issues.append(error.localizedDescription)
            for index in result.skills.indices { result.skills[index].enabled = nil }
        }
        result.skills.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard agent.supportsMCP else { return result }
        var sources: [(URL, TandockCustomizationScope)] = [(configURL(agent: agent, project: nil, environment: environment), .user)]
        if let project {
            if agent == .claude { sources.append((sources[0].0, .local)) }
            sources.append((configURL(agent: agent, project: project, environment: environment), .project))
        }
        for (url, scope) in sources {
            do {
                result.servers += try servers(at: url, agent: agent, scope: scope, project: project, environment: environment)
            } catch { result.issues.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        let priority: [TandockCustomizationScope: Int] = [.user: 0, .shared: 0, .project: 1, .local: 2]
        for index in result.servers.indices {
            let record = result.servers[index]
            result.servers[index].isShadowed = result.servers.contains {
                $0.name == record.name && priority[$0.scope, default: 0] > priority[record.scope, default: 0]
            }
        }
        result.servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    func configURL(agent: TandockCustomizationAgent, project: URL?, environment: [String: String]) -> URL {
        switch agent {
        case .claude: project?.appendingPathComponent(".mcp.json") ?? claudeStateURL(environment)
        case .codex: project?.appendingPathComponent(".codex/config.toml") ?? codexHome(environment).appendingPathComponent("config.toml")
        case .grok: project?.appendingPathComponent(".grok/config.toml") ?? configurationHome(agent: agent, environment: environment).appendingPathComponent("config.toml")
        case .pi: project?.appendingPathComponent(".pi/settings.json") ?? configurationHome(agent: agent, environment: environment).appendingPathComponent("settings.json")
        }
    }

    func hasSupportedConfigurationRoot(agent: TandockCustomizationAgent, environment: [String: String]) -> Bool {
        let key: String
        switch agent {
        case .claude: key = "CLAUDE_CONFIG_DIR"
        case .codex: key = "CODEX_HOME"
        case .grok: key = "GROK_HOME"
        case .pi: key = "PI_CODING_AGENT_DIR"
        }
        return environment[key].map { $0.hasPrefix("/") } ?? true
    }

    func configurationHome(agent: TandockCustomizationAgent, environment: [String: String]) -> URL {
        let key: String, fallback: String
        switch agent {
        case .claude: (key, fallback) = ("CLAUDE_CONFIG_DIR", ".claude")
        case .codex: (key, fallback) = ("CODEX_HOME", ".codex")
        case .grok: (key, fallback) = ("GROK_HOME", ".grok")
        case .pi: (key, fallback) = ("PI_CODING_AGENT_DIR", ".pi/agent")
        }
        return environment[key].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(fallback)
    }

    func claudeStateURL(_ environment: [String: String]) -> URL {
        (environment["CLAUDE_CONFIG_DIR"] == nil ? home : configurationHome(agent: .claude, environment: environment))
            .appendingPathComponent(".claude.json")
    }

    private func codexHome(_ environment: [String: String]) -> URL {
        configurationHome(agent: .codex, environment: environment)
    }

    private func skillRoots(agent: TandockCustomizationAgent, project: URL?, environment: [String: String]) -> [(URL, TandockCustomizationScope)] {
        let own: String
        switch agent {
        case .claude: own = ".claude/skills"
        case .codex: own = ".agents/skills"
        case .grok: own = ".grok/skills"
        case .pi: own = ".pi/agent/skills"
        }
        var roots: [(URL, TandockCustomizationScope)] = []
        if let project {
            roots.append((project.appendingPathComponent(agent == .pi ? ".pi/skills" : own), .project))
            if agent != .claude && agent != .codex { roots.append((project.appendingPathComponent(".agents/skills"), .project)) }
        }
        roots.append((agent == .codex ? home.appendingPathComponent(own) : configurationHome(agent: agent, environment: environment).appendingPathComponent("skills"), .user))
        if agent == .codex { roots.append((codexHome(environment).appendingPathComponent("skills"), .user)) }
        if agent == .grok || agent == .pi { roots.append((home.appendingPathComponent(".agents/skills"), .shared)) }
        return roots
    }

    private func skillDirectories(root: URL) throws -> [URL] {
        var result: [URL] = []
        var visited: Set<String> = []
        func walk(_ directory: URL, depth: Int) throws {
            guard depth <= 8, visited.insert(directory.resolvingSymlinksInPath().path).inserted else { return }
            if fm.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path) {
                result.append(directory)
                return
            }
            for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    try walk(child, depth: depth + 1)
                }
            }
        }
        try walk(root, depth: 0)
        return result
    }

    private func skill(directory: URL, root: URL, scope: TandockCustomizationScope) throws -> TandockSkillRecord {
        let data = try Data(contentsOf: directory.appendingPathComponent("SKILL.md"))
        guard let content = String(data: data, encoding: .utf8) else { throw TandockCustomizationError.invalidSkill }
        let metadata = skillMetadata(content, fallbackName: directory.lastPathComponent)
        return TandockSkillRecord(directory: directory, root: root, scope: scope, name: metadata.0, summary: metadata.1, content: content, revision: data)
    }

    private func skillMetadata(_ content: String, fallbackName: String) -> (String, String) {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            return (fallbackName, lines.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? "")
        }
        func field(_ key: String) -> String {
            guard let index = (1..<end).first(where: { lines[$0].hasPrefix(key + ":") }) else { return "" }
            var value = String(lines[index].dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ">+", "|+"].contains(value) {
                value = lines[(index + 1)..<end].prefix { $0.isEmpty || $0.hasPrefix(" ") || $0.hasPrefix("\t") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            } else if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
            return value
        }
        let name = field("name"), summary = field("description")
        return (name.isEmpty ? fallbackName : name, summary)
    }

    func read(_ url: URL) throws -> Data? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL, expected: Data?) throws {
        guard try read(url) == expected else { throw TandockCustomizationError.changedOnDisk }
        let destination = url.resolvingSymlinksInPath()
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let expected { try backUp(expected, of: url) }
        let permissions = (try? fm.attributesOfItem(atPath: destination.path)[.posixPermissions]) ?? 0o600
        // Re-check right before the atomic replace: agents rewrite these files on their own, and the
        // backup above widened the window in which their edit would be overwritten.
        guard try read(url) == expected else { throw TandockCustomizationError.changedOnDisk }
        try data.write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
    }

    static let backupsKept = 5

    var backupDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Tandock/config-backups", isDirectory: true)
    }

    /// Backups live outside the edited folder so project-scope copies never land inside a repository,
    /// and only the newest few per file are kept because a copy of `~/.claude.json` can be megabytes.
    private func backUp(_ contents: Data, of url: URL) throws {
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // `#` never survives the escaping, so `config#` cannot be a prefix of `config.json#…`.
        let prefix = url.standardizedFileURL.path.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "#", with: "%23") + "#"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss.SSS"
        let backup = backupDirectory.appendingPathComponent(prefix + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8))
        try contents.write(to: backup, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        let siblings = try fm.contentsOfDirectory(atPath: backupDirectory.path).filter { $0.hasPrefix(prefix) }.sorted()
        for stale in siblings.dropLast(Self.backupsKept) {
            try? fm.removeItem(at: backupDirectory.appendingPathComponent(stale))
        }
    }
}
