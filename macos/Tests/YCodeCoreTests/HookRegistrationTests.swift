import Foundation
import Testing
@testable import YCodeCore

@Suite("Hook registration", .serialized)
struct HookRegistrationTests {
    @Test("Claude install and uninstall preserve user hooks")
    func claudeRoundTrip() async throws {
        let fixture = try HookRegistrationFixture()
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"user-hook"}]}]}}"#.utf8).write(to: path)

        #expect(try await fixture.service.install(for: .claude) == .installed)
        #expect(try await fixture.service.install(for: .claude) == .installed)
        #expect(try await fixture.service.status(for: .claude) == .installed)
        let installed = try json(path)
        #expect(installed["theme"] as? String == "dark")
        let hooks = try #require(installed["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let notification = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(stop.filter { $0[YCodeHookRegistrationService.claudeMarkerKey] as? Bool == true }.count == 1)
        #expect(notification.count == 1)
        #expect(notification[0]["matcher"] as? String == "permission_prompt")
        #expect(FileManager.default.fileExists(atPath: path.path + ".ycode.bak"))

        #expect(try await fixture.service.uninstall(for: .claude) == .notInstalled)
        let uninstalled = try json(path)
        let remainingHooks = try #require(uninstalled["hooks"] as? [String: Any])
        #expect((remainingHooks["Stop"] as? [[String: Any]])?.count == 1)
        #expect(remainingHooks["Notification"] == nil)
    }

    @Test("Codex conflict is non-destructive and chain restores user notify")
    func codexConflictChainRoundTrip() async throws {
        let fixture = try HookRegistrationFixture()
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "notify = [\"user-notify\", \"--flag\"]\nmodel = \"gpt-6\"\n\n[provider.local]\nname = \"kept\"\n"
        try Data(original.utf8).write(to: path)

        #expect(try await fixture.service.status(for: .codex) == .conflictUserNotify(existing: ["user-notify", "--flag"]))
        #expect(try await fixture.service.install(for: .codex) == .conflictUserNotify(existing: ["user-notify", "--flag"]))
        #expect(try String(contentsOf: path, encoding: .utf8) == original)

        #expect(try await fixture.service.install(for: .codex, chainExistingCodexNotify: true) == .installed)
        #expect(try await fixture.service.status(for: .codex) == .installed)
        let chained = try String(contentsOf: path, encoding: .utf8)
        #expect(chained.contains(YCodeHookRegistrationService.codexNotifyMarker))
        #expect(chained.contains(YCodeHookRegistrationService.codexHooksStart))
        #expect(chained.contains("permission_request codex"))
        #expect(chained.contains("--next"))
        #expect(chained.contains("name = \"kept\""))

        #expect(try await fixture.service.uninstall(for: .codex) == .notInstalled)
        let restored = try String(contentsOf: path, encoding: .utf8)
        #expect(restored.contains("notify = [\"user-notify\", \"--flag\"]"))
        #expect(restored.contains("model = \"gpt-6\""))
        #expect(restored.contains("name = \"kept\""))
        #expect(!restored.contains("ycode-managed"))
    }

    @Test("Codex plain install is idempotent and removes only managed blocks")
    func codexPlainRoundTrip() async throws {
        let fixture = try HookRegistrationFixture(helperName: "notify helper")
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt-6\"\n".utf8).write(to: path)
        #expect(try await fixture.service.install(for: .codex) == .installed)
        #expect(try await fixture.service.install(for: .codex) == .installed)
        let installed = try String(contentsOf: path, encoding: .utf8)
        #expect(installed.components(separatedBy: YCodeHookRegistrationService.codexNotifyMarker).count == 2)
        #expect(installed.components(separatedBy: YCodeHookRegistrationService.codexHooksStart).count == 2)
        #expect(installed.contains("'" + fixture.helper.path + "' permission_request codex"))
        #expect(try await fixture.service.uninstall(for: .codex) == .notInstalled)
        #expect(try String(contentsOf: path, encoding: .utf8).contains("model = \"gpt-6\""))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

private struct HookRegistrationFixture {
    let root: URL
    let helper: URL
    let service: YCodeHookRegistrationService

    init(helperName: String = "ycode-notify") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-hook-registration-\(UUID().uuidString)")
        helper = root.appendingPathComponent(helperName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        service = YCodeHookRegistrationService(homeDirectory: root, helperURL: helper)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
