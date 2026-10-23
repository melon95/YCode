import Foundation
import Testing
@testable import TandockCore

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
        #expect(stop.filter { $0[TandockHookRegistrationService.claudeMarkerKey] as? Bool == true }.count == 1)
        #expect(notification.count == 1)
        #expect(notification[0]["matcher"] as? String == "permission_prompt")
        #expect(FileManager.default.fileExists(atPath: path.path + ".ycode.bak"))

        #expect(try await fixture.service.uninstall(for: .claude) == .notInstalled)
        let uninstalled = try json(path)
        let remainingHooks = try #require(uninstalled["hooks"] as? [String: Any])
        #expect((remainingHooks["Stop"] as? [[String: Any]])?.count == 1)
        #expect(remainingHooks["Notification"] == nil)
    }

    @Test("Codex conflict is non-destructive and chain restores user notify", arguments: [false, true])
    func codexConflictChainRoundTrip(hasUserTable: Bool) async throws {
        let fixture = try HookRegistrationFixture()
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "notify = [\"user-notify\", \"--flag\"]\nmodel = \"gpt-6\"\n"
            + (hasUserTable ? "\n[provider.local]\nname = \"kept\"\n" : "")
        try Data(original.utf8).write(to: path)

        #expect(try await fixture.service.status(for: .codex) == .conflictUserNotify(existing: ["user-notify", "--flag"]))
        #expect(try await fixture.service.install(for: .codex) == .conflictUserNotify(existing: ["user-notify", "--flag"]))
        #expect(try String(contentsOf: path, encoding: .utf8) == original)

        #expect(try await fixture.service.install(for: .codex, chainExistingCodexNotify: true) == .installed)
        #expect(try await fixture.service.status(for: .codex) == .installed)
        let chained = try String(contentsOf: path, encoding: .utf8)
        #expect(chained.contains(TandockHookRegistrationService.codexNotifyMarker))
        #expect(chained.contains(TandockHookRegistrationService.codexHooksStart))
        #expect(chained.contains("permission_request codex"))
        #expect(chained.contains("--next"))
        if hasUserTable { #expect(chained.contains("name = \"kept\"")) }

        #expect(try await fixture.service.uninstall(for: .codex) == .notInstalled)
        let restored = try String(contentsOf: path, encoding: .utf8)
        #expect(restored.contains("notify = [\"user-notify\", \"--flag\"]"))
        #expect(restored.contains("model = \"gpt-6\""))
        if hasUserTable { #expect(restored.contains("name = \"kept\"")) }
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
        #expect(installed.components(separatedBy: TandockHookRegistrationService.codexNotifyMarker).count == 2)
        #expect(installed.components(separatedBy: TandockHookRegistrationService.codexHooksStart).count == 2)
        #expect(installed.contains("'" + fixture.helper.path + "' permission_request codex"))
        #expect(try await fixture.service.uninstall(for: .codex) == .notInstalled)
        #expect(try String(contentsOf: path, encoding: .utf8).contains("model = \"gpt-6\""))
    }

    @Test("Claude managed hooks on an old helper are stale; repair keeps arguments and user hooks")
    func claudeStaleRepair() async throws {
        let fixture = try HookRegistrationFixture(helperName: "it's notify")
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "/Applications/YCode.app/Contents/Resources/ycode-notify"
        try Data(#"""
        {"hooks":{
          "Stop":[{"matcher":"","hooks":[{"type":"command","command":"\#(old) stop user"}]},
                  {"_ycode_managed":true,"matcher":"","hooks":[{"type":"command","command":"'\#(old)' stop claude"}]}],
          "Notification":[{"_ycode_managed":true,"matcher":"permission_prompt","hooks":[{"type":"command","command":"'\#(old)' notification claude","timeout":5}]}]
        }}
        """#.utf8).write(to: path)

        #expect(try await fixture.service.status(for: .claude) == .stale(registered: old))
        #expect(try await fixture.service.repairStaleHelperPath(for: .claude))
        #expect(try await fixture.service.status(for: .claude) == .installed)
        let hooks = try #require(try json(path)["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let notification = try #require(hooks["Notification"] as? [[String: Any]])
        let quoted = "'" + fixture.helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        #expect((stop[0]["hooks"] as? [[String: Any]])?[0]["command"] as? String == "\(old) stop user")
        #expect((stop[1]["hooks"] as? [[String: Any]])?[0]["command"] as? String == quoted + " stop claude")
        let notificationHook = try #require((notification[0]["hooks"] as? [[String: Any]])?.first)
        #expect(notificationHook["command"] as? String == quoted + " notification claude")
        #expect(notificationHook["timeout"] as? Int == 5)
    }

    @Test("Codex repair keeps a wrapped notify chain and the agent's hook trust state")
    func codexWrappedStaleRepair() async throws {
        let fixture = try HookRegistrationFixture()
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "/Applications/YCode.app/Contents/Resources/ycode-notify"
        let escapedOld = old.replacingOccurrences(of: "/", with: "\\\\/")
        try Data("""
        model = "gpt-6"
        \(TandockHookRegistrationService.codexNotifyMarker)

        notify = ["/opt/computer-use/client", "turn-ended", "--previous-notify", "[\\"\(escapedOld)\\",\\"turn_complete\\",\\"codex\\"]"]

        [providers.openai]
        api_key = "kept"

        \(TandockHookRegistrationService.codexHooksStart)
        [[hooks.PermissionRequest]]
        matcher = ".*"

        [[hooks.PermissionRequest.hooks]]
        type = "command"
        command = "'\(old)' permission_request codex"
        timeout = 5

        [hooks.state."/home/.codex/config.toml:permission_request:0:0"]
        trusted_hash = "sha256:abc"
        \(TandockHookRegistrationService.codexHooksEnd)

        """.utf8).write(to: path)

        #expect(try await fixture.service.status(for: .codex) == .stale(registered: old))
        #expect(try await fixture.service.repairStaleHelperPath(for: .codex))
        #expect(try await fixture.service.status(for: .codex) == .installed)
        let repaired = try String(contentsOf: path, encoding: .utf8)
        #expect(!repaired.contains("ycode-notify"))
        let escapedNew = fixture.helper.path.replacingOccurrences(of: "/", with: "\\\\/")
        #expect(repaired.contains("notify = [\"/opt/computer-use/client\", \"turn-ended\", \"--previous-notify\", \"[\\\"\(escapedNew)\\\""))
        #expect(repaired.contains("command = \"'\(fixture.helper.path)' permission_request codex\""))
        #expect(repaired.contains("trusted_hash = \"sha256:abc\""))
        #expect(repaired.contains("api_key = \"kept\""))
    }

    @Test("Codex entries installed from another bundle location are repaired in place")
    func codexPlainStaleRepair() async throws {
        let fixture = try HookRegistrationFixture()
        defer { fixture.remove() }
        let oldHelper = fixture.root.appendingPathComponent("Old.app/ycode-notify")
        try FileManager.default.createDirectory(at: oldHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: oldHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldHelper.path)
        let previous = TandockHookRegistrationService(homeDirectory: fixture.root, helperURL: oldHelper)
        #expect(try await previous.install(for: .codex) == .installed)

        #expect(try await fixture.service.status(for: .codex) == .stale(registered: oldHelper.path))
        #expect(try await fixture.service.repairStaleHelperPath(for: .codex))
        #expect(try await fixture.service.status(for: .codex) == .installed)
        #expect(try await !fixture.service.repairStaleHelperPath(for: .codex))
        let repaired = try String(contentsOf: fixture.root.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        #expect(!repaired.contains(oldHelper.path))
        #expect(try await fixture.service.uninstall(for: .codex) == .notInstalled)
        #expect(!(try String(contentsOf: fixture.root.appendingPathComponent(".codex/config.toml"), encoding: .utf8)).contains("ycode-managed"))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

private struct HookRegistrationFixture {
    let root: URL
    let helper: URL
    let service: TandockHookRegistrationService

    init(helperName: String = "tandock-notify") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-hook-registration-\(UUID().uuidString)")
        helper = root.appendingPathComponent(helperName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        service = TandockHookRegistrationService(homeDirectory: root, helperURL: helper)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
