import Foundation
import Testing
@testable import YCodeCore

@Suite("Agent catalog and launch environment")
struct AgentLaunchEnvironmentTests {
    @Test("defaults match the shipped Claude and Codex catalog")
    func defaults() {
        #expect(YCodeAgentCatalog.defaults.map(\.id) == ["claude-code", "codex"])
        #expect(YCodeAgentCatalog.suggestions.map(\.id) == ["grok-cli", "pi"])
        // Gemini CLI 已停更，不再主动建议 —— 但支持仍在（见
        // `geminiFromLoginShellPath` 与 `apiKeyHints`），手动加一个照样能跑。
        #expect(!YCodeAgentCatalog.suggestions.contains { $0.id == "gemini-cli" })
    }

    @Test("config save preserves unknown fields and unresolved secrets")
    func preservingSave() throws {
        let directory = try temporaryDirectory(named: "config preserve")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let source = """
        {
          "future_top_level": { "enabled": true },
          "agents": [{
            "id": "custom", "command": "echo", "env": { "TOKEN": "$SECRET_TOKEN" },
            "icon": "DeepSeek", "icon_variant": "mono", "color": "#123456",
            "future_agent_field": 42
          }],
          "proxy": { "mode": "system", "url": "", "no_proxy": "", "future_proxy_field": "kept" }
        }
        """
        try Data(source.utf8).write(to: url)
        let store = YCodeConfigurationStore(configurationURL: url)
        var settings = try store.loadAgentSettings()
        settings.proxy.mode = .manual
        try store.saveAgentSettings(settings)

        let saved = try PreservingJSONDocument(data: Data(contentsOf: url))
        #expect(saved["future_top_level"] == .object(["enabled": .bool(true)]))
        guard case let .object(proxy)? = saved["proxy"] else {
            Issue.record("proxy was not encoded")
            return
        }
        #expect(proxy["future_proxy_field"] == .string("kept"))
        guard case let .array(agents)? = saved["agents"],
              case let .object(agent) = agents[0] else {
            Issue.record("agents were not encoded")
            return
        }
        #expect(agent["future_agent_field"] == .number(42))
        #expect(agent["env"] == .object(["TOKEN": .string("$SECRET_TOKEN")]))
        #expect(agent["icon"] == .string("DeepSeek"))
        #expect(agent["icon_variant"] == .string("mono"))
        #expect(agent["color"] == .string("#123456"))
    }

    @Test("duplicate IDs fail without writing")
    func duplicateIDs() throws {
        let directory = try temporaryDirectory(named: "duplicate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = YCodeConfigurationStore(configurationURL: url)
        let settings = YCodeAgentSettings(agents: [
            .init(id: "same", command: "one"),
            .init(id: "same", command: "two")
        ])
        #expect(throws: YCodeAgentSettingsError.duplicateAgentID("same")) {
            try store.saveAgentSettings(settings)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("manual and system proxy precedence matches the legacy app")
    func proxyPrecedence() throws {
        let profile = YCodeAgentProfile(
            id: "echo", command: "/bin/echo",
            environment: [
                "HTTPS_PROXY": "agent-proxy", "NO_COLOR": "1",
                "YCODE_TERMINAL_ID": "spoofed", "YCODE_NATIVE_DATA_ROOT": "/spoofed"
            ]
        )
        let detected = YCodeSystemProxy(http: "http://system:80", https: "http://system:443")
        let systemPlan = try YCodeAgentLauncher.makePlan(
            profile: profile,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            terminalID: "real-id",
            dataRoot: URL(fileURLWithPath: "/native/data", isDirectory: true),
            proxy: .init(mode: .system),
            detectedSystemProxy: detected,
            hostEnvironment: ["SHELL": "/bin/sh"]
        )
        #expect(systemPlan.environment["HTTPS_PROXY"] == "agent-proxy")
        #expect(systemPlan.environment["HTTP_PROXY"] == "http://system:80")
        #expect(systemPlan.environment["NO_COLOR"] == nil)
        #expect(systemPlan.environment["YCODE_TERMINAL_ID"] == "real-id")
        #expect(systemPlan.environment["YCODE_NATIVE_DATA_ROOT"] == "/native/data")
        #expect(systemPlan.environment["TERM"] == "xterm-256color")

        let manualPlan = try YCodeAgentLauncher.makePlan(
            profile: profile,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            terminalID: "real-id",
            proxy: .init(mode: .manual, url: "127.0.0.1:7897", noProxy: "localhost"),
            hostEnvironment: ["SHELL": "/bin/sh"]
        )
        #expect(manualPlan.environment["HTTPS_PROXY"] == "http://127.0.0.1:7897")
        #expect(manualPlan.environment["https_proxy"] == "http://127.0.0.1:7897")
        #expect(manualPlan.environment["NO_PROXY"] == "localhost")
    }

    @Test("scutil parser ignores disabled endpoints and reports PAC")
    func scutilParser() {
        let source = """
        <dictionary> {
          ExceptionsList : <array> {
            0 : localhost
            1 : <local>
          }
          HTTPEnable : 0
          HTTPProxy : stale
          HTTPPort : 80
          HTTPSEnable : 1
          HTTPSProxy : 127.0.0.1
          HTTPSPort : 7897
          ProxyAutoConfigEnable : 1
          ProxyAutoConfigURLString : http://wpad/proxy.pac
        }
        """
        let result = YCodeSystemProxyDetector.parse(source)
        #expect(result.http == nil)
        #expect(result.https == "http://127.0.0.1:7897")
        #expect(result.exceptions == ["localhost"])
        #expect(result.pacURL == "http://wpad/proxy.pac")
    }

    @Test("login shell launch preserves path and argument boundaries")
    func realEchoLaunch() throws {
        let directory = try temporaryDirectory(named: "agent path with spaces and 'quote")
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("echo agent")
        let body = """
        #!/bin/sh
        printf 'arg=<%s>\\n' "$@"
        printf 'cwd=<%s>\\n' "$PWD"
        printf 'token=<%s>\\n' "$TEST_TOKEN"
        printf 'terminal=<%s>\\n' "$YCODE_TERMINAL_ID"
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let profile = YCodeAgentProfile(
            id: "echo", command: script.path,
            arguments: ["two words", "it's literal", "$(not executed)"],
            environment: ["TEST_TOKEN": "$HOST_SECRET"]
        )
        let plan = try YCodeAgentLauncher.makePlan(
            profile: profile,
            workingDirectory: directory,
            terminalID: "terminal-42",
            proxy: .init(mode: .off),
            hostEnvironment: ["SHELL": "/bin/sh", "HOST_SECRET": "resolved-only-at-launch"]
        )
        #expect(plan.arguments == [
            "-l", "-i", "-c",
            "exec \(YCodeAgentLauncher.shellQuote(script.path)) 'two words' 'it'\\''s literal' '$(not executed)'"
        ])
        let result = try YCodeAgentLauncher.run(plan)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("arg=<two words>"))
        #expect(result.standardOutput.contains("arg=<it's literal>"))
        #expect(result.standardOutput.contains("arg=<$(not executed)>"))
        let canonicalPath = directory.path.hasPrefix("/var/") ? "/private\(directory.path)" : directory.path
        #expect(result.standardOutput.contains("cwd=<\(canonicalPath)>") )
        #expect(result.standardOutput.contains("token=<resolved-only-at-launch>"))
        #expect(result.standardOutput.contains("terminal=<terminal-42>"))
    }

    @Test("missing commands return an explicit error but remain saveable")
    func missingCommand() throws {
        let profile = YCodeAgentProfile(id: "later", command: "definitely-not-installed-ycode-test")
        #expect(throws: YCodeAgentSettingsError.missingProgram(profile.command)) {
            try YCodeAgentLauncher.makePlan(
                profile: profile,
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                terminalID: "id",
                hostEnvironment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
            )
        }
        let directory = try temporaryDirectory(named: "missing command config")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try YCodeConfigurationStore(configurationURL: url).saveAgentSettings(.init(agents: [profile]))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Gemini profile resolves through the interactive login shell PATH")
    func geminiFromLoginShellPath() throws {
        let directory = try temporaryDirectory(named: "gemini login path")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("custom bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = bin.appendingPathComponent("gemini")
        try Data("#!/bin/sh\nprintf 'gemini=<%s>\\n' \"$1\"\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        try Data("export PATH=\"$CUSTOM_AGENT_BIN:$PATH\"\n".utf8)
            .write(to: directory.appendingPathComponent(".zshrc"))

        let profile = YCodeAgentProfile(id: "gemini-cli", command: "gemini", arguments: ["space argument"])
        let plan = try YCodeAgentLauncher.makePlan(
            profile: profile,
            workingDirectory: directory,
            terminalID: "gemini-test",
            proxy: .init(mode: .off),
            hostEnvironment: [
                "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin",
                "ZDOTDIR": directory.path, "CUSTOM_AGENT_BIN": bin.path
            ]
        )
        let result = try YCodeAgentLauncher.run(plan)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "gemini=<space argument>\n")
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
