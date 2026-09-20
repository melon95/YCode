import Foundation
import XCTest
@testable import YCodeCore

final class WorkspaceStateTests: XCTestCase {
    private let fileManager = FileManager.default

    func testLegacyLocalStorageAndWindowStateImportOnce() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("native/ycode.db")
        let repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
        let directories = (1...3).map { root.appendingPathComponent("project-\($0)", isDirectory: true) }
        for directory in directories { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        let first = try repository.addProject(directory: directories[0], name: "first")
        let second = try repository.addProject(directory: directories[1], name: "second")
        let third = try repository.addProject(directory: directories[2], name: "third")

        let localStorageURL = root.appendingPathComponent("legacy/localstorage.sqlite3")
        try fileManager.createDirectory(at: localStorageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let localStorage = try SQLiteConnection(path: localStorageURL.path)
        try localStorage.execute("CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB NOT NULL)")
        try insertLocalStorage("ycode-project-order", value: json([third.id, first.id, "stale"]), into: localStorage)
        try insertLocalStorage("ycode-active-project", value: first.id, into: localStorage)
        try insertLocalStorage("ycode-file-tree-width", value: "650", into: localStorage)
        try insertLocalStorage("ycode-instance-id", value: "legacy-instance", into: localStorage)

        let windowURL = root.appendingPathComponent("legacy/window-state.json")
        try Data("""
            {"main":{"x":40,"y":60,"width":1600,"height":1000,"fullscreen":false}}
            """.utf8).write(to: windowURL)

        let state = try NativeWorkspaceStateStore(databaseURL: databaseURL)
        let importer = LegacyUIStateImporter(projects: repository, state: state)
        let result = try importer.importIfNeeded(from: LegacyUIStateSource(
            localStorageDatabaseURL: localStorageURL,
            windowStateURL: windowURL
        ))
        XCTAssertEqual(result, .imported(LegacyUIStateImportSummary(
            orderedProjectCount: 2,
            selectedProjectImported: true,
            fileTreeWidthImported: true,
            instanceIDImported: true,
            windowFrameImported: true
        )))
        XCTAssertEqual(try repository.listProjects().map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(try repository.selectedProjectID(), first.id)
        XCTAssertEqual(try state.preferences(), NativeWorkspacePreferences(
            fileTreeWidth: 600,
            instanceID: "legacy-instance",
            windowFrame: NativeWindowFrame(x: 40, y: 60, width: 1600, height: 1000)
        ))
        XCTAssertEqual(try importer.importIfNeeded(from: LegacyUIStateSource(
            localStorageDatabaseURL: localStorageURL,
            windowStateURL: windowURL
        )), .alreadyImported)
    }

    func testMissingAndInvalidLegacyStateUseDefaultsWithoutBlocking() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("native/ycode.db")
        let repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
        let directory = root.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try repository.addProject(directory: directory)
        let state = try NativeWorkspaceStateStore(databaseURL: databaseURL)
        let importer = LegacyUIStateImporter(projects: repository, state: state)

        XCTAssertEqual(try importer.importIfNeeded(from: LegacyUIStateSource(
            localStorageDatabaseURL: nil,
            windowStateURL: nil
        )), .sourceUnavailable)
        XCTAssertEqual(try state.preferences().fileTreeWidth, 280)

        let corruptDB = root.appendingPathComponent("legacy/localstorage.sqlite3")
        try fileManager.createDirectory(at: corruptDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: corruptDB)
        let corruptWindow = root.appendingPathComponent("legacy/window.json")
        try Data("not json".utf8).write(to: corruptWindow)
        let result = try importer.importIfNeeded(from: LegacyUIStateSource(
            localStorageDatabaseURL: corruptDB,
            windowStateURL: corruptWindow
        ))
        XCTAssertEqual(result, .imported(LegacyUIStateImportSummary(
            orderedProjectCount: 0,
            selectedProjectImported: false,
            fileTreeWidthImported: false,
            instanceIDImported: false,
            windowFrameImported: false
        )))
        XCTAssertEqual(try state.preferences().fileTreeWidth, 280)
    }

    func testBasicSettingsSavePreservesUnknownFieldsAndCancelIsNoWrite() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let configurationURL = root.appendingPathComponent("config.json")
        let original = Data("""
            {"startup":"future-mode","future":{"nested":42},"theme":"snow","notifications":{"enabled":false,"only_when_unfocused":false,"future_mode":"quiet"}}
            """.utf8)
        try original.write(to: configurationURL)
        let store = YCodeConfigurationStore(configurationURL: configurationURL)

        let loaded = try store.loadBasicSettings()
        XCTAssertEqual(loaded.startupMode, .resume)
        XCTAssertEqual(loaded.notifications, YCodeNotificationSettings(enabled: false, onlyWhenUnfocused: false))
        XCTAssertEqual(try Data(contentsOf: configurationURL), original, "loading or cancelling must not write")
        try store.saveBasicSettings(YCodeBasicSettings(
            startupMode: .overview,
            notifications: YCodeNotificationSettings(enabled: true, onlyWhenUnfocused: true),
            appearance: loaded.appearance
        ))
        let saved = try PreservingJSONDocument(data: Data(contentsOf: configurationURL))
        XCTAssertEqual(saved["startup"], .string("overview"))
        XCTAssertEqual(saved["theme"], .string("snow"))
        XCTAssertEqual(saved["future"], .object(["nested": .number(42)]))
        XCTAssertEqual(saved["notifications"], .object([
            "enabled": .bool(true),
            "only_when_unfocused": .bool(true),
            "future_mode": .string("quiet")
        ]))
    }

    func testAppearanceSettingsRoundTripPreservesUnknownFieldsAndClampsFontSizes() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let configurationURL = root.appendingPathComponent("config.json")
        try Data("""
            {
              "theme":"future-theme",
              "locale":"en",
              "font_sizes":{"ui":7,"editor":17,"terminal":99,"future_lane":21},
              "future_top_level":true
            }
            """.utf8).write(to: configurationURL)
        let store = YCodeConfigurationStore(configurationURL: configurationURL)

        let loaded = try store.loadBasicSettings()
        XCTAssertEqual(loaded.appearance.theme, "future-theme")
        XCTAssertEqual(loaded.appearance.locale, .en)
        XCTAssertEqual(loaded.appearance.fontSizes, YCodeFontSizes(ui: 8, editor: 17, terminal: 32))

        var changed = loaded
        changed.appearance.theme = "glacier"
        changed.appearance.locale = .zh
        changed.appearance.fontSizes = YCodeFontSizes(ui: 15, editor: 16, terminal: 12)
        try store.saveBasicSettings(changed)

        let saved = try PreservingJSONDocument(data: Data(contentsOf: configurationURL))
        XCTAssertEqual(saved["theme"], .string("glacier"))
        XCTAssertEqual(saved["locale"], .string("zh"))
        XCTAssertEqual(saved["future_top_level"], .bool(true))
        XCTAssertEqual(saved["font_sizes"], .object([
            "ui": .number(15),
            "editor": .number(16),
            "terminal": .number(12),
            "future_lane": .number(21)
        ]))
    }

    func testStartupModesResolveOverviewResumeAndBlank() {
        let projects = [
            ProjectRecord(id: "quiet", name: "quiet", repositoryURL: URL(fileURLWithPath: "/tmp/quiet"), createdAtMilliseconds: 1, isolateSessions: false, liveSessionCount: 0, totalSessionCount: 3),
            ProjectRecord(id: "live", name: "live", repositoryURL: URL(fileURLWithPath: "/tmp/live"), createdAtMilliseconds: 2, isolateSessions: false, liveSessionCount: 2, totalSessionCount: 4)
        ]
        XCTAssertNil(initialProjectID(mode: .overview, recentProjectID: "live", projects: projects))
        XCTAssertNil(initialProjectID(mode: .resume, recentProjectID: "quiet", projects: projects))
        XCTAssertEqual(initialProjectID(mode: .resume, recentProjectID: "live", projects: projects), "live")
        XCTAssertEqual(initialProjectID(mode: .blank, recentProjectID: "quiet", projects: projects), "quiet")
        XCTAssertEqual(initialProjectID(mode: .blank, recentProjectID: "missing", projects: projects), "quiet")
    }

    func testLegacySourceLocatorFindsNestedWebKitDatabase() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent(
            "Library/WebKit/dev.ycode.app/WebsiteData/Default/a/b/LocalStorage/localstorage.sqlite3"
        )
        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: databaseURL)
        let windowURL = root.appendingPathComponent("Library/Application Support/dev.ycode.app/.window-state.json")
        try fileManager.createDirectory(at: windowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: windowURL)

        let located = LegacyUIStateSourceLocator.locate(homeDirectory: root)
        XCTAssertEqual(located.localStorageDatabaseURL?.resolvingSymlinksInPath(), databaseURL.resolvingSymlinksInPath())
        XCTAssertEqual(located.windowStateURL?.resolvingSymlinksInPath(), windowURL.resolvingSymlinksInPath())
    }

    private func insertLocalStorage(_ key: String, value: String, into database: SQLiteConnection) throws {
        try database.execute(
            "INSERT INTO ItemTable (key,value) VALUES (?,?)",
            bindings: [.text(key), .blob(try XCTUnwrap(value.data(using: .utf16LittleEndian)))]
        )
    }

    private func json(_ value: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func makeTemporaryRoot() -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent("ycode-m14-tests-\(UUID().uuidString)", isDirectory: true)
        try! fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
