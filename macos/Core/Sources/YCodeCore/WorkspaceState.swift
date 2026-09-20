import Foundation

public struct NativeWindowFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width >= 640 && height >= 480
    }
}

public struct NativeWorkspacePreferences: Equatable, Sendable {
    public static let defaultFileTreeWidth = 280.0
    public let fileTreeWidth: Double
    public let instanceID: String?
    public let windowFrame: NativeWindowFrame?

    public init(fileTreeWidth: Double, instanceID: String?, windowFrame: NativeWindowFrame?) {
        self.fileTreeWidth = fileTreeWidth
        self.instanceID = instanceID
        self.windowFrame = windowFrame
    }
}

public final class NativeWorkspaceStateStore {
    private let database: SQLiteConnection

    public init(databaseURL: URL) throws {
        try YCodeNativeDatabase.prepare(at: databaseURL)
        database = try SQLiteConnection(path: databaseURL.path)
        try database.execute(Self.schema)
    }

    public func preferences() throws -> NativeWorkspacePreferences {
        let width = try value(for: "file_tree_width").flatMap(Double.init)
            .map(Self.clampFileTreeWidth) ?? NativeWorkspacePreferences.defaultFileTreeWidth
        let instanceID = try value(for: "instance_id").flatMap { $0.isEmpty ? nil : $0 }
        let frame = try value(for: "window_frame")
            .flatMap { try? JSONDecoder().decode(NativeWindowFrame.self, from: Data($0.utf8)) }
            .flatMap { $0.isValid ? $0 : nil }
        return NativeWorkspacePreferences(fileTreeWidth: width, instanceID: instanceID, windowFrame: frame)
    }

    public func setFileTreeWidth(_ width: Double) throws {
        try setValue(String(Self.clampFileTreeWidth(width)), for: "file_tree_width")
    }

    public func setInstanceID(_ id: String) throws {
        guard !id.isEmpty else { return }
        try setValue(id, for: "instance_id")
    }

    public func setWindowFrame(_ frame: NativeWindowFrame) throws {
        guard frame.isValid else { return }
        let data = try JSONEncoder().encode(frame)
        try setValue(String(decoding: data, as: UTF8.self), for: "window_frame")
    }

    public func legacyUIImportVersion() throws -> Int? {
        try value(for: "legacy_ui_import_version").flatMap(Int.init)
    }

    public func markLegacyUIImported(version: Int = 1) throws {
        try setValue(String(version), for: "legacy_ui_import_version")
    }

    private func value(for key: String) throws -> String? {
        try database.scalarString("SELECT value FROM native_workspace_state WHERE key=\(sqlLiteral(key))")
    }

    private func setValue(_ value: String, for key: String) throws {
        try database.execute(
            "INSERT INTO native_workspace_state (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            bindings: [.text(key), .text(value)]
        )
    }

    private static func clampFileTreeWidth(_ value: Double) -> Double {
        min(600, max(180, value))
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS native_workspace_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
}

public struct LegacyUIStateSource: Equatable, Sendable {
    public let localStorageDatabaseURL: URL?
    public let windowStateURL: URL?

    public init(localStorageDatabaseURL: URL?, windowStateURL: URL?) {
        self.localStorageDatabaseURL = localStorageDatabaseURL
        self.windowStateURL = windowStateURL
    }
}

public enum LegacyUIStateSourceLocator {
    public static func locate(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> LegacyUIStateSource {
        let webKitRoot = homeDirectory
            .appendingPathComponent("Library/WebKit/dev.ycode.app/WebsiteData/Default", isDirectory: true)
        let localStorage = newestLocalStorageDatabase(below: webKitRoot)
        let windowState = homeDirectory
            .appendingPathComponent("Library/Application Support/dev.ycode.app", isDirectory: true)
            .appendingPathComponent(".window-state.json")
        return LegacyUIStateSource(
            localStorageDatabaseURL: localStorage,
            windowStateURL: FileManager.default.fileExists(atPath: windowState.path) ? windowState : nil
        )
    }

    private static func newestLocalStorageDatabase(below root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent == "localstorage.sqlite3" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                candidates.append((url, values?.contentModificationDate ?? .distantPast))
            }
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }
}

public struct LegacyUIStateImportSummary: Equatable, Sendable {
    public let orderedProjectCount: Int
    public let selectedProjectImported: Bool
    public let fileTreeWidthImported: Bool
    public let instanceIDImported: Bool
    public let windowFrameImported: Bool
}

public enum LegacyUIStateImportResult: Equatable, Sendable {
    case sourceUnavailable
    case alreadyImported
    case imported(LegacyUIStateImportSummary)
}

public final class LegacyUIStateImporter {
    private let projects: ProjectWorkspaceRepository
    private let state: NativeWorkspaceStateStore

    public init(projects: ProjectWorkspaceRepository, state: NativeWorkspaceStateStore) {
        self.projects = projects
        self.state = state
    }

    public func importIfNeeded(from source: LegacyUIStateSource) throws -> LegacyUIStateImportResult {
        if try state.legacyUIImportVersion() != nil { return .alreadyImported }
        let fileManager = FileManager.default
        let localExists = source.localStorageDatabaseURL.map { fileManager.fileExists(atPath: $0.path) } == true
        let windowExists = source.windowStateURL.map { fileManager.fileExists(atPath: $0.path) } == true
        guard localExists || windowExists else { return .sourceUnavailable }

        let values = source.localStorageDatabaseURL.flatMap(readLocalStorage) ?? [:]
        let knownProjects = try projects.listProjects()
        let knownIDs = Set(knownProjects.map(\.id))
        var orderedProjectCount = 0
        if let raw = values["ycode-project-order"],
           let data = raw.data(using: .utf8),
           let imported = try? JSONDecoder().decode([String].self, from: data) {
            var seen = Set<String>()
            var reconciled = imported.filter { knownIDs.contains($0) && seen.insert($0).inserted }
            reconciled.append(contentsOf: knownProjects.map(\.id).filter { seen.insert($0).inserted })
            if reconciled.count == knownProjects.count {
                try projects.reorderProjects(reconciled)
                orderedProjectCount = imported.filter { knownIDs.contains($0) }.count
            }
        }

        var selectedImported = false
        if let selected = values["ycode-active-project"], knownIDs.contains(selected) {
            try projects.setSelectedProjectID(selected)
            selectedImported = true
        }

        var widthImported = false
        if let raw = values["ycode-file-tree-width"], let width = Double(raw), width.isFinite {
            try state.setFileTreeWidth(width)
            widthImported = true
        }

        var instanceImported = false
        if let instanceID = values["ycode-instance-id"], !instanceID.isEmpty {
            try state.setInstanceID(instanceID)
            instanceImported = true
        }

        var frameImported = false
        if let url = source.windowStateURL, let frame = readWindowFrame(url), frame.isValid {
            try state.setWindowFrame(frame)
            frameImported = true
        }

        try state.markLegacyUIImported()
        return .imported(LegacyUIStateImportSummary(
            orderedProjectCount: orderedProjectCount,
            selectedProjectImported: selectedImported,
            fileTreeWidthImported: widthImported,
            instanceIDImported: instanceImported,
            windowFrameImported: frameImported
        ))
    }

    private func readLocalStorage(_ url: URL) -> [String: String]? {
        guard let database = try? SQLiteConnection(path: url.path, readOnly: true) else { return nil }
        let rows = try? database.query("SELECT key,value FROM ItemTable") { row -> (String, String)? in
            guard let key = sqliteString(row, column: 0), let data = sqliteData(row, column: 1) else { return nil }
            let value = String(data: data, encoding: .utf16LittleEndian)
                ?? String(data: data, encoding: .utf8)
            return value.map { (key, $0) }
        }
        return rows?.compactMap { $0 }.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    private func readWindowFrame(_ url: URL) -> NativeWindowFrame? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let main = object["main"] as? [String: Any],
              let x = (main["x"] as? NSNumber)?.doubleValue,
              let y = (main["y"] as? NSNumber)?.doubleValue,
              let width = (main["width"] as? NSNumber)?.doubleValue,
              let height = (main["height"] as? NSNumber)?.doubleValue else { return nil }
        return NativeWindowFrame(x: x, y: y, width: width, height: height)
    }
}
