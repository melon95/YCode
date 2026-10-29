import AppKit
import Foundation
import Testing
@testable import TandockApp
import TandockCore

@Suite("Theme switching", .serialized)
@MainActor
struct ThemeSwitchTests {
    init() { _ = NSApplication.shared }

    private func save(theme: String, in dataRoot: URL) throws {
        let store = TandockConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
        var settings = try store.loadBasicSettings()
        settings.appearance.theme = theme
        try store.saveBasicSettings(settings)
    }

    @Test("terminal theme resolves against the new appearance in the same pass, including the return to system")
    func appearanceAppliesBeforeThemeResolves() throws {
        let original = NSApp.appearance
        defer { NSApp.appearance = original }
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandock-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        try save(theme: TandockThemeCatalog.dark.id, in: dataRoot)
        let model = WorkspaceModel(dataRootOverride: dataRoot)
        #expect(NSApp.appearance?.name == .darkAqua)
        #expect(model.activeTheme == TandockThemeCatalog.dark)

        try save(theme: TandockThemeCatalog.light.id, in: dataRoot)
        model.reloadAppearanceSettings()
        #expect(NSApp.appearance?.name == .aqua)
        #expect(model.activeTheme == TandockThemeCatalog.light)

        try save(theme: TandockThemeCatalog.systemID, in: dataRoot)
        model.reloadAppearanceSettings()
        #expect(NSApp.appearance == nil)
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #expect(model.activeTheme == (systemDark ? TandockThemeCatalog.dark : TandockThemeCatalog.light))
    }
}
