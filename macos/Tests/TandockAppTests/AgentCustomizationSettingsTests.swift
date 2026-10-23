import AppKit
import SwiftUI
import Testing
@testable import TandockApp
import TandockCore

@Suite("Skills and MCP settings UI", .serialized)
@MainActor
struct AgentCustomizationSettingsTests {
    @Test("native lists render in both languages and appearances, using temporary CLI configurations")
    func settingsLayouts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-customization-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let projectSkill = project.appendingPathComponent(".agents/skills/project-only")
        let projectConfig = project.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: projectSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: project-only\ndescription: Never shown in global settings\n---\n".write(to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let projectConfigText = "[mcp_servers.documentation]\ncommand = 'project-only-server'\n"
        try projectConfigText.write(to: projectConfig, atomically: true, encoding: .utf8)
        let names = [
            ("review-changes", "review-changes", "检查修改和测试结果，在提交前列出需要处理的问题。"),
            ("design-taste-frontend", "design-taste-frontend", "Design interface components with deliberate hierarchy, clear type and useful interactions, while retaining all project conventions and accessibility requirements."),
            ("synced/8f8b492c-ff60-4fb8-967f-4f6b13fa0793/design-taste-frontend", "design-taste-frontend", "A separate source with the same skill name; its path remains visible and its complete description is available on hover.")
        ]
        for (path, name, description) in names {
            let folder = home.appendingPathComponent(".agents/skills/\(path)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: \(description)\n---\n# Instructions\n".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let codexDir = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try "[mcp_servers.documentation]\nurl = 'https://docs.example.com/mcp'\n\n[mcp_servers.local-files]\ncommand = 'file-server'\nenabled = false\n\n[mcp_servers.project-todos]\ncommand = 'tandock-mcp'\n".write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let service = TandockAgentCustomizationService(homeDirectory: home)
        let model = AgentCustomizationSettingsModel(service: service)
        model.selectedAgentID = "codex"
        let profile = try #require(TandockAgentCatalog.defaults.first { $0.id == "codex" })
        await model.refresh(profile: profile)
        #expect(model.snapshot?.skills.count == 3)
        #expect(model.snapshot?.servers.count == 3)
        #expect(model.snapshot?.skills.allSatisfy { $0.scope == .user || $0.scope == .shared } == true)
        #expect(model.snapshot?.servers.allSatisfy { $0.scope == .user } == true)
        #expect(model.snapshot?.skills.contains { $0.name == "project-only" } == false)
        let skill = try #require(model.snapshot?.skills.first)
        await model.setSkill(skill, enabled: false, profile: profile)
        #expect(model.snapshot?.skills.first { $0.id == skill.id }?.enabled == false)
        #expect(model.errorMessage == nil)
        let server = try #require(model.snapshot?.servers.first { $0.name == "documentation" })
        await model.setMCP(server, enabled: false, profile: profile)
        #expect(model.snapshot?.servers.first { $0.name == server.name }?.enabled == false)
        #expect(try String(contentsOf: projectConfig, encoding: .utf8) == projectConfigText)
        model.selectedAgentID = "claude-code"
        #expect(model.snapshot == nil)
        let claude = try #require(TandockAgentCatalog.defaults.first { $0.id == "claude-code" })
        await model.setSkill(skill, enabled: false, profile: claude)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
        model.selectedAgentID = "codex"
        await model.refresh(profile: profile)

        _ = NSApplication.shared
        for locale in [TandockLocale.zh, .en] {
            for dark in [false, true] {
                for page in [TandockCustomizationPage.skills, .mcp] {
                    let content = AgentCustomizationSettingsView(model: model, agents: TandockAgentCatalog.defaults, page: page)
                        .environment(\.tandockL10n, TandockLocalization(locale: locale))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .frame(width: 584, height: 496)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 584, height: 496), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let host = NSHostingView(rootView: content)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(40))
                    window.displayIfNeeded()
                    #expect(host.frame.width == 584)
                    #expect(host.frame.height == 496)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                    if let destination = ProcessInfo.processInfo.environment["YCODE_CUSTOMIZATION_SNAPSHOT_DIR"] {
                        let folder = URL(fileURLWithPath: destination)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let name = "\(page == .skills ? "skills" : "mcp")-\(locale == .zh ? "zh" : "en")-\(dark ? "dark" : "light").png"
                        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
                    }
                    window.close()
                }
            }
        }
    }
}
