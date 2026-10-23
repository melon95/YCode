import Foundation
import Testing
@testable import TandockCore

@Suite("MCP registration", .serialized)
struct MCPRegistrationTests {
    @Test("Claude install is idempotent and uninstall preserves user servers")
    func claudeRoundTrip() async throws {
        let fixture = try MCPRegistrationFixture()
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".claude.json")
        try Data(#"{"model":"opus","mcpServers":{"other":{"command":"x"}}}"#.utf8).write(to: path)

        #expect(try await fixture.service.status(for: .claude) == .notInstalled)
        #expect(try await fixture.service.install(for: .claude) == .installed)
        #expect(try await fixture.service.install(for: .claude) == .installed)
        #expect(try await fixture.service.status(for: .claude) == .installed)
        let installed = try json(at: path)
        #expect(installed["model"] as? String == "opus")
        let servers = try #require(installed["mcpServers"] as? [String: Any])
        #expect((servers["other"] as? [String: Any])?["command"] as? String == "x")
        #expect((servers["ycode-todos"] as? [String: Any])?["command"] as? String == fixture.helper.path)
        #expect(FileManager.default.fileExists(atPath: path.path + ".ycode.bak"))

        #expect(try await fixture.service.uninstall(for: .claude) == .notInstalled)
        #expect(try await fixture.service.status(for: .claude) == .notInstalled)
        let uninstalled = try json(at: path)
        let remaining = try #require(uninstalled["mcpServers"] as? [String: Any])
        #expect(remaining["ycode-todos"] == nil)
        #expect((remaining["other"] as? [String: Any])?["command"] as? String == "x")
    }

    @Test("Codex install replaces only its table and preserves surrounding config")
    func codexRoundTrip() async throws {
        let fixture = try MCPRegistrationFixture(helperName: "quoted \"helper\"")
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt-6\"\n\n[providers.openai]\napi_key = \"kept\"\n".utf8).write(to: path)

        #expect(try await fixture.service.install(for: .codex) == .installed)
        #expect(try await fixture.service.install(for: .codex) == .installed)
        #expect(try await fixture.service.status(for: .codex) == .installed)
        let installed = try String(contentsOf: path, encoding: .utf8)
        #expect(installed.contains("model = \"gpt-6\""))
        #expect(installed.contains("api_key = \"kept\""))
        #expect(installed.components(separatedBy: "[mcp_servers.ycode-todos]").count == 2)
        #expect(installed.contains("quoted \\\"helper\\\""))
        #expect(FileManager.default.fileExists(atPath: path.path + ".ycode.bak"))

        #expect(try await fixture.service.uninstall(for: .codex) == .notInstalled)
        #expect(try await fixture.service.status(for: .codex) == .notInstalled)
        let uninstalled = try String(contentsOf: path, encoding: .utf8)
        #expect(uninstalled.contains("[providers.openai]"))
        #expect(!uninstalled.contains("ycode-todos"))
    }

    @Test("invalid schemas and missing helper fail without replacing config")
    func invalidInputsRemainUnchanged() async throws {
        let fixture = try MCPRegistrationFixture()
        defer { fixture.remove() }
        let claude = fixture.root.appendingPathComponent(".claude.json")
        let invalidClaude = #"{"mcpServers":[]}"#
        try Data(invalidClaude.utf8).write(to: claude)
        do {
            _ = try await fixture.service.install(for: .claude)
            Issue.record("expected invalid Claude schema")
        } catch {
            #expect(error as? TandockMCPRegistrationError == .invalidClaudeServers)
        }
        #expect(try String(contentsOf: claude, encoding: .utf8) == invalidClaude)

        let codex = fixture.root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unsupportedCodex = "mcp_servers = { other = { command = \"x\" } }\n"
        try Data(unsupportedCodex.utf8).write(to: codex)
        do {
            _ = try await fixture.service.install(for: .codex)
            Issue.record("expected unsupported Codex schema")
        } catch {
            #expect(error as? TandockMCPRegistrationError == .unsupportedCodexServers)
        }
        #expect(try String(contentsOf: codex, encoding: .utf8) == unsupportedCodex)

        let missing = TandockMCPRegistrationService(
            homeDirectory: fixture.root,
            helperURL: fixture.root.appendingPathComponent("missing-helper")
        )
        do {
            _ = try await missing.install(for: .claude)
            Issue.record("expected missing helper")
        } catch {
            guard case .helperMissing = error as? TandockMCPRegistrationError else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Claude entry pointing at an old helper is stale and repair keeps the rest of the entry")
    func claudeStaleRepair() async throws {
        let fixture = try MCPRegistrationFixture()
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".claude.json")
        let old = "/Applications/YCode.app/Contents/Resources/ycode-mcp"
        try Data(#"{"model":"opus","mcpServers":{"other":{"command":"x"},"ycode-todos":{"type":"stdio","command":"\#(old)","args":[],"env":{"A":"1"}}}}"#.utf8).write(to: path)

        #expect(try await fixture.service.status(for: .claude) == .stale(registered: old))
        #expect(try await fixture.service.repairStaleHelperPath(for: .claude))
        #expect(try await fixture.service.status(for: .claude) == .installed)
        #expect(try await !fixture.service.repairStaleHelperPath(for: .claude))
        let repaired = try json(at: path)
        #expect(repaired["model"] as? String == "opus")
        let servers = try #require(repaired["mcpServers"] as? [String: Any])
        let entry = try #require(servers["ycode-todos"] as? [String: Any])
        #expect(entry["command"] as? String == fixture.helper.path)
        #expect((entry["env"] as? [String: Any])?["A"] as? String == "1")
        #expect((servers["other"] as? [String: Any])?["command"] as? String == "x")
    }

    @Test("Codex table pointing at an old helper is stale and repair rewrites only its command")
    func codexStaleRepair() async throws {
        let fixture = try MCPRegistrationFixture(helperName: "quoted \"helper\"")
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "/Applications/YCode.app/Contents/Resources/ycode-mcp"
        try Data("""
        model = "gpt-6"

        [mcp_servers.ycode-todos]
        command = "\(old)"
        env = { A = "1" }

        [providers.openai]
        api_key = "kept"

        """.utf8).write(to: path)

        #expect(try await fixture.service.status(for: .codex) == .stale(registered: old))
        #expect(try await fixture.service.repairStaleHelperPath(for: .codex))
        #expect(try await fixture.service.status(for: .codex) == .installed)
        let repaired = try String(contentsOf: path, encoding: .utf8)
        #expect(!repaired.contains(old))
        #expect(repaired.contains("quoted \\\"helper\\\""))
        #expect(repaired.contains("env = { A = \"1\" }"))
        #expect(repaired.contains("api_key = \"kept\""))
        #expect(repaired.contains("model = \"gpt-6\""))
    }

    @Test("repair without an executable helper fails and leaves the stale entry alone")
    func repairNeedsHelper() async throws {
        let fixture = try MCPRegistrationFixture()
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".claude.json")
        let original = #"{"mcpServers":{"ycode-todos":{"command":"/old/ycode-mcp"}}}"#
        try Data(original.utf8).write(to: path)
        let missing = TandockMCPRegistrationService(
            homeDirectory: fixture.root,
            helperURL: fixture.root.appendingPathComponent("missing-helper")
        )
        await #expect(throws: TandockMCPRegistrationError.self) { try await missing.repairStaleHelperPath(for: .claude) }
        #expect(try String(contentsOf: path, encoding: .utf8) == original)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

private struct MCPRegistrationFixture {
    let root: URL
    let helper: URL
    let service: TandockMCPRegistrationService

    init(helperName: String = "tandock-mcp") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-mcp-registration-\(UUID().uuidString)")
        helper = root.appendingPathComponent(helperName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        service = TandockMCPRegistrationService(homeDirectory: root, helperURL: helper)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
