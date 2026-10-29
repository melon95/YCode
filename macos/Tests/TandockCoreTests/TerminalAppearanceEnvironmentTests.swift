import Foundation
import Testing
@testable import TandockCore

@Suite("Terminal appearance environment")
@MainActor
struct TerminalAppearanceEnvironmentTests {
    private func home(grokConfig: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
        if let grokConfig { try Data(grokConfig.utf8).write(to: home.appendingPathComponent(".grok/config.toml")) }
        return home
    }

    @Test func lightTerminalPicksGrokDayAndLightColorHint() throws {
        let home = try home(grokConfig: "[ui]\nyolo = false\n")
        var environment = ["HOME": home.path]
        TandockAgentLauncher.applyTerminalAppearance(.light, to: &environment)
        #expect(environment["GROK_THEME"] == "grokday")
        #expect(environment["COLORFGBG"] == "0;15")
    }

    @Test func darkShellPaneGetsGrokNight() throws {
        let home = try home(grokConfig: nil)
        let plan = TandockProjectShellPool.makeLaunchPlan(
            workingDirectory: home, shell: "/bin/sh", environment: ["HOME": home.path], terminalAppearance: .dark
        )
        #expect(plan.environment["GROK_THEME"] == "groknight")
        #expect(plan.environment["COLORFGBG"] == "15;0")
    }

    @Test func systemFollowingTerminalLetsGrokTrackTheMacAppearance() throws {
        var environment = ["HOME": try home(grokConfig: nil).path]
        TandockAgentLauncher.applyTerminalAppearance(.followingSystem(dark: true), to: &environment)
        #expect(environment["GROK_THEME"] == "auto")
        #expect(environment["COLORFGBG"] == "15;0")
    }

    @Test func userChosenGrokThemeWins() throws {
        let configured = try home(grokConfig: "[ui]\ntheme = \"tokyonight\"\n")
        var fromConfig = ["HOME": configured.path]
        TandockAgentLauncher.applyTerminalAppearance(.light, to: &fromConfig)
        #expect(fromConfig["GROK_THEME"] == nil)

        var fromEnvironment = ["HOME": try home(grokConfig: nil).path, "GROK_THEME": "auto"]
        TandockAgentLauncher.applyTerminalAppearance(.light, to: &fromEnvironment)
        #expect(fromEnvironment["GROK_THEME"] == "auto")
    }
}

@Suite("Terminal color level")
@MainActor
struct TerminalColorLevelTests {
    @Test("agents and shell panes advertise truecolor, keeping a user-chosen FORCE_COLOR")
    func forceColorAdvertisesTruecolor() throws {
        let directory = FileManager.default.temporaryDirectory
        let shell = TandockProjectShellPool.makeLaunchPlan(workingDirectory: directory, shell: "/bin/sh", environment: [:])
        #expect(shell.environment["FORCE_COLOR"] == "3")
        let kept = TandockProjectShellPool.makeLaunchPlan(workingDirectory: directory, shell: "/bin/sh", environment: ["FORCE_COLOR": "0"])
        #expect(kept.environment["FORCE_COLOR"] == "0")

        let agent = try TandockAgentLauncher.makePlan(
            profile: .init(id: "echo", command: "/bin/echo", arguments: []),
            workingDirectory: directory, terminalID: "color-level",
            hostEnvironment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
        )
        #expect(agent.environment["FORCE_COLOR"] == "3")
    }

    @Test("light theme keeps ANSI white and bright white light enough to serve as backgrounds")
    func lightWhitesStayLight() {
        let palette = TandockThemeCatalog.light.terminal.ansi
        #expect(palette[7] == "#d9d7e3")
        #expect(palette[15] == "#f3f2f8")
    }
}
