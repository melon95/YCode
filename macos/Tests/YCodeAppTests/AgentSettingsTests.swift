import AppKit
import SwiftUI
import Testing
@testable import YCodeApp
import YCodeCore

@Suite("Agent settings switches", .serialized)
@MainActor
struct AgentSettingsTests {
    @Test("switches retain custom configuration, persist across reopening, and filter only new sessions")
    func enablement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-agent-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YCodeConfigurationStore(configurationURL: root.appendingPathComponent("config.json"))
        let custom = YCodeAgentProfile(id: "custom", displayName: "Custom CLI", command: "/usr/bin/true", arguments: ["--custom"], environment: ["VALUE": "$PRESERVE"], icon: "terminal")
        try store.saveAgentSettings(.init(agents: [custom]))
        let settings = BasicSettingsModel(dataRoot: root, commandProbe: { _ in true })
        settings.setAgentEnabled(id: custom.id, enabled: false)
        settings.save()
        #expect(settings.errorMessage == nil)
        var disabled = custom
        disabled.enabled = false
        #expect(settings.agents == [disabled])
        let reopened = BasicSettingsModel(dataRoot: root, commandProbe: { _ in true })
        #expect(reopened.agents == [disabled])

        let workspace = WorkspaceModel(dataRootOverride: root)
        #expect(workspace.agentProfiles == [disabled])
        // The empty-availability fallback must never reintroduce disabled agents.
        #expect(workspace.availableAgentProfiles.isEmpty)
        reopened.setAgentEnabled(id: custom.id, enabled: true)
        reopened.save()
        workspace.reloadAgentProfiles()
        #expect(workspace.availableAgentProfiles == [custom])
        #expect(workspace.agentProfiles == [custom])

        let detected = try #require(YCodeAgentCatalog.suggestions.first)
        reopened.addSuggestion(detected)
        reopened.addSuggestion(detected)
        #expect(reopened.agents.filter { $0.command == detected.command }.count == 1)
        let added = try #require(reopened.agents.first { $0.command == detected.command })
        #expect(added.enabled)
        reopened.setAgentEnabled(id: added.id, enabled: false)
        reopened.save()
        #expect(try store.loadAgentSettings().agents.first { $0.id == added.id }?.enabled == false)
    }

    @Test("a slow probe from an earlier enablement state cannot hide a newly enabled agent")
    func staleAvailability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-agent-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YCodeConfigurationStore(configurationURL: root.appendingPathComponent("config.json"))
        let first = YCodeAgentProfile(id: "first", command: "/usr/bin/true")
        var second = YCodeAgentProfile(id: "second", command: "/usr/bin/false", enabled: false)
        try store.saveAgentSettings(.init(agents: [first, second]))
        let workspace = WorkspaceModel(dataRootOverride: root)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let older = workspace.refreshAgentAvailability { _ in
            _ = gate.wait(timeout: .now() + 5)
            return true
        }
        second.enabled = true
        try store.saveAgentSettings(.init(agents: [first, second]))
        workspace.reloadAgentProfiles()
        await workspace.refreshAgentAvailability { _ in true }.value
        #expect(workspace.availableAgentProfileIDs == [first.id, second.id])
        gate.signal()
        await older.value
        #expect(workspace.availableAgentProfileIDs == [first.id, second.id])
        #expect(workspace.availableAgentProfiles == [first, second])
    }

    @Test("agent icon controls and switches render in both languages and themes")
    func layouts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-agent-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YCodeConfigurationStore(configurationURL: root.appendingPathComponent("config.json"))
        try store.saveAgentSettings(.init())
        let model = BasicSettingsModel(dataRoot: root, commandProbe: { _ in true })
        for _ in 0..<100 {
            if model.commandAvailability["pi"] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.commandAvailability["pi"] == true)
        _ = NSApplication.shared
        for locale in [YCodeLocale.zh, .en] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: AgentSettingsView(model: model, onEdit: { _ in }, onAddCustom: {})
                    .environment(\.ycodeL10n, YCodeLocalization(locale: locale))
                    .tint(Color.ycodeAccent)
                    .frame(width: 584, height: 496))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 584, height: 496), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let destination = ProcessInfo.processInfo.environment["YCODE_AGENT_SNAPSHOT_DIR"] {
                    let folder = URL(fileURLWithPath: destination)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("agents-\(locale == .zh ? "zh" : "en")-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
