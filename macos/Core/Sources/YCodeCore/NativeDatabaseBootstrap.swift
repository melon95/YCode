import Foundation

public enum YCodeNativeDatabase {
    public static func prepare(at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isNew = !fileManager.fileExists(atPath: url.path)
        let database = try SQLiteConnection(path: url.path)
        if isNew {
            try database.execute(LegacyMigrationService.currentSchemaSQL)
        }
        guard try database.tableExists("projects"), try database.tableExists("sessions") else {
            throw YCodeMigrationError.unsupportedSchema("native database is missing projects or sessions")
        }
        try database.execute("PRAGMA foreign_keys=ON")
    }
}

public enum YCodeDataRootResolver {
    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallback: URL? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        if let index = arguments.firstIndex(of: "--data-root"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        }
        if let path = environment["YCODE_NATIVE_DATA_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        // Early migration builds and manual validation notes used this shorter
        // spelling. Honor it as a safety alias so a typo cannot silently fall
        // through to the user's live Application Support directory.
        if let path = environment["YCODE_DATA_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return (fallback ?? YCodeDataLocations.current.defaultRoot(bundleIdentifier: bundleIdentifier)).standardizedFileURL
    }
}
