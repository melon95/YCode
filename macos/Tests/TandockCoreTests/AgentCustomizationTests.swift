import Foundation
import Testing
@testable import TandockCore

@Suite("CLI Skills and MCP switches", .serialized)
struct AgentCustomizationTests {
    private struct Fixture {
        let root: URL
        let home: URL
        let project: URL
        let service: TandockAgentCustomizationService
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-customizations-\(UUID().uuidString)")
            home = root.appendingPathComponent("home")
            project = root.appendingPathComponent("中文 project")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            service = TandockAgentCustomizationService(homeDirectory: home)
        }
        func write(_ content: String, _ relative: String, project scoped: Bool = false) throws {
            let url = (scoped ? project : home).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        func text(_ relative: String, project scoped: Bool = false) throws -> String {
            try String(contentsOf: (scoped ? project : home).appendingPathComponent(relative), encoding: .utf8)
        }
        func relativePath(_ url: URL) -> String? {
            let path = root.path
            let alternate = path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count))
                : path.hasPrefix("/var/") ? "/private" + path : path
            for prefix in [path + "/", alternate + "/"] where url.path.hasPrefix(prefix) {
                return String(url.path.dropFirst(prefix.count))
            }
            return nil
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        var skill: String { "---\nname: review\ndescription: >-\n  Review the current changes\n  before a commit.\n---\n\n# Review\nKeep supporting files.\n" }
    }

    @Test("Claude skill switches preserve instructions, assets and other settings")
    func claudeSkills() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write(f.skill, ".claude/skills/review/SKILL.md")
        try f.write("asset", ".claude/skills/review/references/check.txt")
        try f.write(#"{"theme":"dark","big":9007199254740993,"skillOverrides":{"other":"name-only"}}"#, ".claude/settings.json")
        var snapshot = await f.service.snapshot(agent: .claude)
        let skill = try #require(snapshot.skills.first)
        #expect(skill.summary == "Review the current changes before a commit.")
        try await f.service.setSkillEnabled(false, record: skill, agent: .claude, project: nil)
        snapshot = await f.service.snapshot(agent: .claude)
        #expect(snapshot.skills.first?.enabled == false)
        #expect(try f.text(".claude/skills/review/SKILL.md") == f.skill)
        #expect(try f.text(".claude/skills/review/references/check.txt") == "asset")
        #expect(try f.text(".claude/settings.json").contains("name-only"))
        #expect(try f.text(".claude/settings.json").contains("dark"))
        #expect(try f.text(".claude/settings.json").contains("9007199254740993"))

        try await f.service.setSkillEnabled(true, record: skill, agent: .claude, project: f.project)
        let scoped = await f.service.snapshot(agent: .claude, project: f.project)
        #expect(scoped.skills.first?.enabled == true)
        #expect((await f.service.snapshot(agent: .claude)).skills.first?.enabled == false)
        #expect(try f.text(".claude/settings.local.json", project: true).contains("on"))
        let backupRoot = f.home.appendingPathComponent("Library/Application Support/Tandock/config-backups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
        #expect(!backups.isEmpty)
        #expect(try backups.allSatisfy { ((try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o600 })
        #expect(!FileManager.default.fileExists(atPath: f.project.appendingPathComponent(".claude/.ycode-backups").path))
        #expect(!FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".claude/.ycode-backups").path))

        for index in 0..<8 {
            try await f.service.setSkillEnabled(index.isMultiple(of: 2), record: skill, agent: .claude, project: nil)
        }
        let userSettings = f.home.appendingPathComponent(".claude/settings.json").path.replacingOccurrences(of: "/", with: "%2F")
        let kept = try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).filter { $0.hasPrefix(userSettings + "#") }
        #expect(kept.count == TandockAgentCustomizationService.backupsKept)

        let backupsBefore = try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).filter { $0.hasPrefix(userSettings + "#") }
        let collider = backupRoot.appendingPathComponent(userSettings.replacingOccurrences(of: ".json", with: "") + "#20000101-000000.000-aaaaaaaa")
        try Data("other file".utf8).write(to: collider)
        try await f.service.setSkillEnabled(true, record: skill, agent: .claude, project: nil)
        #expect(FileManager.default.fileExists(atPath: collider.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).filter { $0.hasPrefix(userSettings + "#") }.count == backupsBefore.count)
    }

    @Test("shared symlink skills stay in place and CODEX_HOME is respected")
    func linkedSkillsAndCustomHome() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write(f.skill, ".agents/skills/review/SKILL.md")
        let customHome = f.home.appendingPathComponent("custom codex")
        let links = customHome.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let shared = f.home.appendingPathComponent(".agents/skills/review")
        let link = links.appendingPathComponent("review")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        let claudeSkills = f.home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claudeSkills.appendingPathComponent("linked-review"), withDestinationURL: shared)
        let claude = await f.service.snapshot(agent: .claude)
        #expect(claude.skills.count == 1)
        #expect(claude.skills.first?.isLinked == true)
        let sharedConfig = f.home.appendingPathComponent("shared-config.toml")
        try f.write("model = 'kept'\n", "shared-config.toml")
        try FileManager.default.createSymbolicLink(at: customHome.appendingPathComponent("config.toml"), withDestinationURL: sharedConfig)
        let environment = ["CODEX_HOME": customHome.path]
        let snapshot = await f.service.snapshot(agent: .codex, environment: environment)
        #expect(snapshot.skills.count == 1)
        let skill = try #require(snapshot.skills.first)
        try await f.service.setSkillEnabled(false, record: skill, agent: .codex, project: nil, environment: environment)
        #expect((await f.service.snapshot(agent: .codex, environment: environment)).skills.first?.enabled == false)
        #expect(FileManager.default.fileExists(atPath: customHome.appendingPathComponent("config.toml").path))
        #expect(!FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".codex/config.toml").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == shared.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: customHome.appendingPathComponent("config.toml").path) == sharedConfig.path)
        #expect(try f.text("shared-config.toml").contains("enabled = false"))
        #expect(try f.text(".agents/skills/review/SKILL.md") == f.skill)
    }

    @Test("Codex skills use SKILL.md paths, retain unknown config and switch back on")
    func codexSkills() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write(f.skill, ".agents/skills/review/SKILL.md")
        try f.write("# model choice\nmodel = 'kept'\n\n[skills]\nunknown = true\n\n[features]\nkeep = true\n", ".codex/config.toml")
        let initial = await f.service.snapshot(agent: .codex)
        let skill = try #require(initial.skills.first)
        try await f.service.setSkillEnabled(false, record: skill, agent: .codex, project: nil)
        let disabled = await f.service.snapshot(agent: .codex)
        #expect(disabled.issues.isEmpty)
        #expect(disabled.skills.first?.enabled == false)
        let config = try f.text(".codex/config.toml")
        #expect(config.contains("# model choice\nmodel = 'kept'"))
        #expect(config.contains("[features]\nkeep = true"))
        #expect(config.contains("unknown = true"))
        #expect(config.contains("SKILL.md"))
        try await f.service.setSkillEnabled(true, record: try #require(disabled.skills.first), agent: .codex, project: nil)
        #expect((await f.service.snapshot(agent: .codex)).skills.first?.enabled == true)
    }

    @Test("Grok and Pi switches use native filters without moving shared skills")
    func grokAndPiSkills() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write(f.skill, ".agents/skills/review/SKILL.md")
        try f.write("model = 'kept'\n[skills]\ndisabled = ['other']\npaths = ['~/team']\n", ".grok/config.toml")
        try f.write(#"{"skills":["!**","~/team"],"defaultTools":["read"]}"#, ".pi/agent/settings.json")
        let grok = try #require((await f.service.snapshot(agent: .grok)).skills.first)
        try await f.service.setSkillEnabled(false, record: grok, agent: .grok, project: nil)
        #expect((await f.service.snapshot(agent: .grok)).skills.first?.enabled == false)
        #expect(try f.text(".grok/config.toml").contains("other"))
        #expect(try f.text(".grok/config.toml").contains("~/team"))
        let pi = try #require((await f.service.snapshot(agent: .pi)).skills.first)
        #expect(pi.enabled == false)
        try await f.service.setSkillEnabled(true, record: pi, agent: .pi, project: nil)
        #expect((await f.service.snapshot(agent: .pi)).skills.first?.enabled == true)
        try await f.service.setSkillEnabled(false, record: pi, agent: .pi, project: nil)
        #expect((await f.service.snapshot(agent: .pi)).skills.first?.enabled == false)
        #expect(try f.text(".pi/agent/settings.json").contains("defaultTools"))
        #expect(try f.text(".agents/skills/review/SKILL.md") == f.skill)
    }

    @Test("TOML MCP switches preserve sibling servers, nested secrets and unrelated text")
    func tomlMCP() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let config = """
        # keep this comment
        model = "unchanged"

        [mcp_servers."docs.example"]
        url = "https://example.com/mcp?token=not-displayed"
        tool_timeout_sec = 99
        [mcp_servers."docs.example".http_headers]
        Authorization = "preserved-secret"

        [features]
        custom = true

        [mcp_servers.other]
        command = "other-server"
        args = ["--flag"]
        """
        try f.write(config, ".codex/config.toml")
        let before = await f.service.snapshot(agent: .codex)
        let server = try #require(before.servers.first { $0.name == "docs.example" })
        #expect(server.endpoint == "https://example.com")
        try await f.service.setMCPEnabled(false, record: server, agent: .codex, project: nil)
        let after = await f.service.snapshot(agent: .codex)
        #expect(after.issues.isEmpty)
        #expect(after.servers.first { $0.name == "docs.example" }?.enabled == false)
        #expect(after.servers.first { $0.name == "other" }?.enabled == true)
        let updated = try f.text(".codex/config.toml")
        #expect(updated.contains("# keep this comment\nmodel = \"unchanged\""))
        #expect(updated.contains("[features]\ncustom = true"))
        #expect(updated.contains("preserved-secret"))
        #expect(updated.contains("tool_timeout_sec = 99"))
        try await f.service.setMCPEnabled(true, record: try #require(after.servers.first { $0.name == "docs.example" }), agent: .codex, project: nil)
        #expect((await f.service.snapshot(agent: .codex)).servers.first { $0.name == "docs.example" }?.enabled == true)
    }

    @Test("Grok project skills use global state and reject ignored project writes")
    func grokProjectSkillsAreReadOnly() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write(f.skill, ".grok/skills/review/SKILL.md", project: true)
        try f.write("[skills]\ndisabled = ['review']\n", ".grok/config.toml")
        let projectConfig = "[skills]\ndisabled = []\n"
        try f.write(projectConfig, ".grok/config.toml", project: true)
        let skill = try #require((await f.service.snapshot(agent: .grok, project: f.project)).skills.first)
        #expect(skill.enabled == false)
        await #expect(throws: TandockCustomizationError.unsupportedProjectSkills) {
            try await f.service.setSkillEnabled(true, record: skill, agent: .grok, project: f.project)
        }
        #expect(try f.text(".grok/config.toml", project: true) == projectConfig)
        #expect(try f.text(".grok/config.toml") == "[skills]\ndisabled = ['review']\n")
    }

    @Test("Pi keeps independently enabled symlink discovery paths visible")
    func piSkillAliases() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write(f.skill, ".agents/skills/review/SKILL.md")
        let ownSkills = f.home.appendingPathComponent(".pi/agent/skills")
        try FileManager.default.createDirectory(at: ownSkills, withIntermediateDirectories: true)
        let alias = ownSkills.appendingPathComponent("review")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.home.appendingPathComponent(".agents/skills/review"))
        let before = await f.service.snapshot(agent: .pi)
        #expect(before.skills.count == 2)
        let linked = try #require(before.skills.first { f.relativePath($0.directory) == "home/.pi/agent/skills/review" })
        #expect(linked.isLinked)
        try await f.service.setSkillEnabled(false, record: linked, agent: .pi, project: nil)
        let after = await f.service.snapshot(agent: .pi)
        #expect(after.skills.first { f.relativePath($0.directory) == "home/.pi/agent/skills/review" }?.enabled == false)
        #expect(after.skills.first { $0.scope == .shared }?.enabled == true)
        let shared = try #require(after.skills.first { $0.scope == .shared })
        try await f.service.setSkillEnabled(false, record: shared, agent: .pi, project: nil)
        #expect((await f.service.snapshot(agent: .pi)).skills.allSatisfy { $0.enabled == false })
        try await f.service.setSkillEnabled(true, record: linked, agent: .pi, project: nil)
        let reenabled = await f.service.snapshot(agent: .pi)
        #expect(reenabled.skills.first { f.relativePath($0.directory) == "home/.pi/agent/skills/review" }?.enabled == true)
        #expect(reenabled.skills.first { $0.scope == .shared }?.enabled == false)
    }

    @Test("Grok MCP global disabled list prevents misleading table switches")
    func grokGlobalMCPDisabledList() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let userConfig = "disabled_mcp_servers = ['docs']\n[mcp_servers.docs]\ncommand = 'user-server'\nenabled = true\n"
        try f.write(userConfig, ".grok/config.toml")
        let projectConfig = "[mcp_servers.docs]\ncommand = 'project-server'\nenabled = true\n"
        try f.write(projectConfig, ".grok/config.toml", project: true)
        let snapshot = await f.service.snapshot(agent: .grok, project: f.project)
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.servers.count == 2)
        #expect(snapshot.servers.allSatisfy { !$0.enabled && $0.isDisabledByGlobalConfiguration })
        let server = try #require(snapshot.servers.first { $0.scope == .project })
        await #expect(throws: TandockCustomizationError.disabledByGlobalConfiguration) {
            try await f.service.setMCPEnabled(true, record: server, agent: .grok, project: f.project)
        }
        #expect(try f.text(".grok/config.toml") == userConfig)
        #expect(try f.text(".grok/config.toml", project: true) == projectConfig)
    }

    @Test("Claude MCP uses per-project state, preserves approvals and identifies shadowed sources")
    func claudeMCP() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write(#"{"mcpServers":{"docs":{"type":"http","url":"https://example.com/mcp"}},"unknown":"kept"}"#, ".claude.json")
        try f.write(#"{"mcpServers":{"docs":{"type":"http","url":"https://project.example.com/mcp"},"pending":{"command":"pending"}}}"#, ".mcp.json", project: true)
        try f.write(#"{"disabledMcpjsonServers":["pending"],"other":"kept"}"#, ".claude/settings.local.json", project: true)
        let before = await f.service.snapshot(agent: .claude, project: f.project)
        #expect(before.servers.first { $0.name == "docs" && $0.scope == .user }?.isShadowed == true)
        let pending = try #require(before.servers.first { $0.name == "pending" })
        #expect(pending.requiresApproval && !pending.enabled)
        let server = try #require(before.servers.first { $0.name == "docs" && $0.scope == .project })
        try await f.service.setMCPEnabled(false, record: server, agent: .claude, project: f.project)
        let after = await f.service.snapshot(agent: .claude, project: f.project)
        #expect(after.servers.filter { $0.name == "docs" }.allSatisfy { !$0.enabled })
        #expect(try f.text(".claude.json").contains("unknown"))
        #expect(try f.text(".claude/settings.local.json", project: true).contains("pending"))
        #expect((await f.service.snapshot(agent: .claude)).servers.first?.enabled == true)
        await #expect(throws: TandockCustomizationError.missingProject) {
            try await f.service.setMCPEnabled(true, record: server, agent: .claude, project: nil)
        }
    }

    @Test("external edits and unsupported inline tables cannot be overwritten")
    func conflictAndInvalidConfig() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write("[mcp_servers.docs]\ncommand = 'server'\n", ".grok/config.toml")
        let server = try #require((await f.service.snapshot(agent: .grok)).servers.first)
        try f.write("# externally changed\n[mcp_servers.docs]\ncommand = 'server'\n", ".grok/config.toml")
        await #expect(throws: TandockCustomizationError.changedOnDisk) {
            try await f.service.setMCPEnabled(false, record: server, agent: .grok, project: nil)
        }
        #expect(try f.text(".grok/config.toml").hasPrefix("# externally changed"))
        try f.write("mcp_servers = { docs = { command = 'server' } }\n", ".grok/config.toml")
        let inline = try #require((await f.service.snapshot(agent: .grok)).servers.first)
        await #expect(throws: TandockCustomizationError.invalidConfiguration) {
            try await f.service.setMCPEnabled(false, record: inline, agent: .grok, project: nil)
        }
        #expect(try f.text(".grok/config.toml") == "mcp_servers = { docs = { command = 'server' } }\n")
        try f.write("[invalid", ".codex/config.toml")
        #expect(!(await f.service.snapshot(agent: .codex)).issues.isEmpty)
    }

    @Test("Claude project MCP rejection honors the user settings file")
    func claudeUserMCPRejection() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write(#"{"disabledMcpjsonServers":["docs"]}"#, ".claude/settings.json")
        try f.write(#"{"mcpServers":{"docs":{"command":"docs-server"}}}"#, ".mcp.json", project: true)
        let snapshot = await f.service.snapshot(agent: .claude, project: f.project)
        #expect(snapshot.issues.isEmpty)
        let server = try #require(snapshot.servers.first)
        #expect(server.requiresApproval && !server.enabled)
    }

    @Test("Explicit CLI configuration roots isolate skill and MCP writes")
    func explicitConfigurationRoots() async throws {
        let roots: [(TandockCustomizationAgent, String)] = [(.claude, "CLAUDE_CONFIG_DIR"), (.codex, "CODEX_HOME"), (.grok, "GROK_HOME"), (.pi, "PI_CODING_AGENT_DIR")]
        for (agent, key) in roots {
            let f = try Fixture(); defer { f.cleanup() }
            let custom = f.home.appendingPathComponent("custom \(agent.rawValue)")
            let environment = [key: custom.path]
            try f.write(f.skill, "custom \(agent.rawValue)/skills/review/SKILL.md")
            if agent == .claude {
                try f.write(#"{"mcpServers":{"docs":{"command":"server"}}}"#, "custom claude/.claude.json")
            } else if agent.supportsMCP {
                try f.write("[mcp_servers.docs]\ncommand = 'server'\n", "custom \(agent.rawValue)/config.toml")
            }
            let before = await f.service.snapshot(agent: agent, environment: environment)
            #expect(before.issues.isEmpty)
            let skill = try #require(before.skills.first)
            #expect(f.relativePath(skill.directory) == "home/custom \(agent.rawValue)/skills/review")
            try await f.service.setSkillEnabled(false, record: skill, agent: agent, project: nil, environment: environment)
            let disabled = await f.service.snapshot(agent: agent, environment: environment)
            #expect(disabled.skills.first?.enabled == false)
            if agent.supportsMCP {
                let server = try #require(disabled.servers.first)
                #expect(server.source.path.hasPrefix(custom.path + "/"))
                let project: URL? = agent == .claude ? f.project : nil
                try await f.service.setMCPEnabled(false, record: server, agent: agent, project: project, environment: environment)
                #expect((await f.service.snapshot(agent: agent, project: project, environment: environment)).servers.first?.enabled == false)
            }
            for path in [".claude.json", ".claude/settings.json", ".codex/config.toml", ".grok/config.toml", ".pi/agent/settings.json"] {
                #expect(!FileManager.default.fileExists(atPath: f.home.appendingPathComponent(path).path))
            }
        }
    }

    @Test("Ambiguous CLI configuration roots cannot fall back to unrelated files")
    func ambiguousConfigurationRootsAreReadOnly() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write(f.skill, ".agents/skills/review/SKILL.md")
        let original = "[mcp_servers.docs]\ncommand = 'server'\n"
        try f.write(original, ".codex/config.toml")
        let existing = await f.service.snapshot(agent: .codex)
        let skill = try #require(existing.skills.first)
        let server = try #require(existing.servers.first)
        let roots: [(TandockCustomizationAgent, String)] = [(.claude, "CLAUDE_CONFIG_DIR"), (.codex, "CODEX_HOME"), (.grok, "GROK_HOME"), (.pi, "PI_CODING_AGENT_DIR")]
        for (agent, key) in roots {
            for root in ["relative config", "~/custom", ""] {
                let environment = [key: root]
                let snapshot = await f.service.snapshot(agent: agent, project: f.project, environment: environment)
                #expect(snapshot.skills.isEmpty && snapshot.servers.isEmpty)
                #expect(!snapshot.issues.isEmpty)
                await #expect(throws: TandockCustomizationError.unsupportedConfigurationRoot) {
                    try await f.service.setSkillEnabled(false, record: skill, agent: agent, project: f.project, environment: environment)
                }
                await #expect(throws: TandockCustomizationError.unsupportedConfigurationRoot) {
                    try await f.service.setMCPEnabled(false, record: server, agent: agent, project: f.project, environment: environment)
                }
            }
        }
        #expect(try f.text(".codex/config.toml") == original)
        #expect(try f.text(".agents/skills/review/SKILL.md") == f.skill)
    }
}
