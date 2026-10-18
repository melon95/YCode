import AppKit
import SwiftUI
import Testing
@testable import YCodeApp
import YCodeCore

@Suite("Integration settings switches", .serialized)
@MainActor
struct IntegrationSettingsTests {
    @Test("integration switches reflect successful writes and keep conflicts unchanged")
    func stateTransitions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-integration-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        let command = root.appendingPathComponent("bin/ycode")
        let codex = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let original = "notify = [\"user-notify\", \"--flag\"]\nmodel = \"preserved\"\n"
        try Data(original.utf8).write(to: codex)
        try Data("user command".utf8).write(to: command)
        let model = MCPIntegrationSettingsModel(
            service: YCodeMCPRegistrationService(homeDirectory: root, helperURL: helper),
            hookService: YCodeHookRegistrationService(homeDirectory: root, helperURL: helper),
            cliService: YCodeCLIInstallationService(helperURL: helper, installURL: command)
        )
        await model.refresh(YCodeMCPAgent.allCases)
        #expect(model.hookStatuses[.claude] == .notInstalled)
        #expect(model.hookStatuses[.codex] == .conflictUserNotify(existing: ["user-notify", "--flag"]))
        await model.setHookInstalled(true, for: .codex)
        #expect(try String(contentsOf: codex, encoding: .utf8) == original)
        await model.setInstalled(true, for: .claude)
        await model.setHookInstalled(true, for: .claude)
        #expect(model.statuses[.claude] == .installed)
        #expect(model.hookStatuses[.claude] == .installed)
        await model.setCLIInstalled(true)
        #expect(model.errorMessage != nil)
        #expect(try String(contentsOf: command, encoding: .utf8) == "user command")
        #expect(!model.cliBusy)
        model.errorMessage = nil

        // Render installed, off, and conflict states without touching user CLI configuration.
        _ = NSApplication.shared
        for locale in [YCodeLocale.zh, .en] {
            for dark in [false, true] {
                try await snapshot(MCPIntegrationSettingsView(model: model, agents: YCodeMCPAgent.allCases),
                                   name: "integrations", locale: locale, dark: dark)
                try await snapshot(NotificationsSettingsView(settings: .constant(.init()), permissionReader: { "Allowed" }),
                                   name: "notifications", locale: locale, dark: dark)
            }
        }

        #expect(try String(contentsOf: codex, encoding: .utf8) == original)
        await model.setHookInstalled(true, for: .codex, chainExisting: true)
        #expect(model.hookStatuses[.codex] == .installed)
        let chained = try String(contentsOf: codex, encoding: .utf8)
        #expect(chained.contains("--next"), "\(chained)")
        await model.setHookInstalled(false, for: .codex)
        let restored = try String(contentsOf: codex, encoding: .utf8)
        #expect(restored.contains("user-notify"), "\(restored)")
        #expect(model.hookStatuses[.codex] == .conflictUserNotify(existing: ["user-notify", "--flag"]))
        await model.setInstalled(false, for: .claude)
        await model.setHookInstalled(false, for: .claude)
        #expect(model.statuses[.claude] == .notInstalled)
        #expect(model.hookStatuses[.claude] == .notInstalled)
        try FileManager.default.removeItem(at: command)
        await model.refreshCLIStatus()
        #expect(model.cliStatus == .notInstalled)
        await model.setCLIInstalled(true)
        guard case .installed = model.cliStatus else { Issue.record("CLI switch should reflect installation"); return }
        await model.setCLIInstalled(false)
        #expect(model.cliStatus == .notInstalled)
        #expect(model.errorMessage == nil)
        #expect(model.busyAgents.isEmpty && model.hookBusyAgents.isEmpty && !model.cliBusy)
    }

    private func snapshot<Content: View>(_ view: Content, name: String, locale: YCodeLocale, dark: Bool) async throws {
        let host = NSHostingView(rootView: view
            .environment(\.ycodeL10n, YCodeLocalization(locale: locale))
            .tint(Color.ycodeAccent).frame(width: 584, height: 820))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 584, height: 820), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let destination = ProcessInfo.processInfo.environment["YCODE_SETTINGS_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-\(locale == .zh ? "zh" : "en")-\(dark ? "dark" : "light").png"))
        }
    }
}
