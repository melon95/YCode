import CryptoKit
import Foundation

public enum LegacySchemaKind: String, Codable, Sendable {
    case initial
    case terminalFirst
    case current
}

public enum YCodeMigrationStage: String, Codable, Sendable {
    case databaseBackedUp
    case databaseNormalized
    case configurationValidated
    case beforeCommit
}

public enum YCodeMigrationError: Error, CustomStringConvertible, Equatable {
    case missingSource(String)
    case sqlite(String)
    case integrityCheckFailed(String)
    case unsupportedSchema(String)
    case futureSchema(Int)
    case configurationRootMustBeObject
    case destinationAlreadyContainsDifferentImport
    case injectedInterruption(YCodeMigrationStage)

    public var description: String {
        switch self {
        case let .missingSource(path): "missing source: \(path)"
        case let .sqlite(message): "sqlite: \(message)"
        case let .integrityCheckFailed(message): "integrity check failed: \(message)"
        case let .unsupportedSchema(message): "unsupported schema: \(message)"
        case let .futureSchema(version): "database migration version \(version) is newer than supported version 12"
        case .configurationRootMustBeObject: "configuration root must be a JSON object"
        case .destinationAlreadyContainsDifferentImport: "destination already contains a different import"
        case let .injectedInterruption(stage): "injected interruption after \(stage.rawValue)"
        }
    }
}

public struct LegacyDataSummary: Codable, Equatable, Sendable {
    public let schema: LegacySchemaKind
    public let migrationVersion: Int
    public let projects: Int
    public let sessions: Int
    public let archivedSessions: Int
    public let worktreeSessions: Int
    public let todos: Int
    public let lspInstallations: Int
    public let checkpoints: Int
}

public enum LegacyImportStatus: String, Codable, Sendable {
    case imported
    case alreadyImported
}

public struct LegacyImportOutcome: Codable, Equatable, Sendable {
    public let status: LegacyImportStatus
    public let summary: LegacyDataSummary
    public let destinationRoot: URL
    public let fingerprint: String
}

private struct ImportManifest: Codable {
    let formatVersion: Int
    let fingerprint: String
    let summary: LegacyDataSummary
}

public struct LegacyMigrationService {
    public static let currentMigrationVersion = 12

    public init() {}

    public func importLegacyData(
        database sourceDatabase: URL,
        configuration sourceConfiguration: URL,
        to destinationRoot: URL,
        interruptAfter: YCodeMigrationStage? = nil
    ) throws -> LegacyImportOutcome {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceDatabase.path) else {
            throw YCodeMigrationError.missingSource(sourceDatabase.path)
        }
        guard fileManager.fileExists(atPath: sourceConfiguration.path) else {
            throw YCodeMigrationError.missingSource(sourceConfiguration.path)
        }
        guard sourceDatabase.standardizedFileURL != destinationRoot.appendingPathComponent("ycode.db").standardizedFileURL else {
            throw YCodeMigrationError.destinationAlreadyContainsDifferentImport
        }

        let parent = destinationRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".ycode-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

        do {
            let sourceSnapshot = staging.appendingPathComponent("legacy-source.db")
            let source = try SQLiteConnection(path: sourceDatabase.path, readOnly: true)
            try source.backup(to: sourceSnapshot.path)
            // sqlite3_backup copies the source database header, including WAL
            // journal mode. The snapshot must be self-contained: normalize its
            // own copy to DELETE mode so later reads never depend on sidecars.
            do {
                let selfContainedSnapshot = try SQLiteConnection(path: sourceSnapshot.path)
                try selfContainedSnapshot.execute("PRAGMA journal_mode=DELETE")
            }
            try interruptIfRequested(.databaseBackedUp, requested: interruptAfter)

            let normalizedURL = staging.appendingPathComponent("ycode.db")
            let normalizedSummary: LegacyDataSummary = try {
                let snapshot = try SQLiteConnection(path: sourceSnapshot.path, readOnly: true)
                let sourceSummary = try inspect(snapshot)
                try normalize(snapshot: snapshot, sourceURL: sourceSnapshot, destinationURL: normalizedURL)
                let normalized = try SQLiteConnection(path: normalizedURL.path, readOnly: true)
                let inspectedNormalized = try inspect(normalized)
                guard inspectedNormalized.sessions == sourceSummary.sessions else {
                    throw YCodeMigrationError.integrityCheckFailed("session count changed during normalization")
                }
                return LegacyDataSummary(
                        schema: .current,
                        migrationVersion: sourceSummary.migrationVersion,
                        projects: inspectedNormalized.projects,
                        sessions: inspectedNormalized.sessions,
                        archivedSessions: inspectedNormalized.archivedSessions,
                        worktreeSessions: inspectedNormalized.worktreeSessions,
                        todos: inspectedNormalized.todos,
                        lspInstallations: inspectedNormalized.lspInstallations,
                        checkpoints: inspectedNormalized.checkpoints
                    )
            }()
            for databaseURL in [sourceSnapshot, normalizedURL] {
                for suffix in ["-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
                    if fileManager.fileExists(atPath: sidecar.path) {
                        try fileManager.removeItem(at: sidecar)
                    }
                }
            }
            try interruptIfRequested(.databaseNormalized, requested: interruptAfter)

            let configData = try Data(contentsOf: sourceConfiguration)
            _ = try PreservingJSONDocument(data: configData)
            try configData.write(to: staging.appendingPathComponent("config.json"), options: .atomic)
            try interruptIfRequested(.configurationValidated, requested: interruptAfter)

            let fingerprint = try fingerprint(database: sourceSnapshot, configuration: configData)
            let manifest = ImportManifest(
                formatVersion: 1,
                fingerprint: fingerprint,
                summary: normalizedSummary
            )
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: staging.appendingPathComponent("import-manifest.json"), options: .atomic)

            if fileManager.fileExists(atPath: destinationRoot.path) {
                let existingManifestURL = destinationRoot.appendingPathComponent("import-manifest.json")
                if let data = try? Data(contentsOf: existingManifestURL),
                   let existing = try? JSONDecoder().decode(ImportManifest.self, from: data),
                   existing.fingerprint == fingerprint {
                    try fileManager.removeItem(at: staging)
                    return LegacyImportOutcome(
                        status: .alreadyImported,
                        summary: existing.summary,
                        destinationRoot: destinationRoot,
                        fingerprint: fingerprint
                    )
                }
                throw YCodeMigrationError.destinationAlreadyContainsDifferentImport
            }

            try interruptIfRequested(.beforeCommit, requested: interruptAfter)
            try fileManager.moveItem(at: staging, to: destinationRoot)
            return LegacyImportOutcome(
                status: .imported,
                summary: normalizedSummary,
                destinationRoot: destinationRoot,
                fingerprint: fingerprint
            )
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        }
    }

    private func interruptIfRequested(_ stage: YCodeMigrationStage, requested: YCodeMigrationStage?) throws {
        if requested == stage { throw YCodeMigrationError.injectedInterruption(stage) }
    }

    private func inspect(_ database: SQLiteConnection) throws -> LegacyDataSummary {
        let integrity = try database.scalarString("PRAGMA integrity_check") ?? "missing result"
        guard integrity == "ok" else { throw YCodeMigrationError.integrityCheckFailed(integrity) }
        guard try database.tableExists("sessions") else {
            throw YCodeMigrationError.unsupportedSchema("sessions table is missing")
        }

        let version = try database.tableExists("_sqlx_migrations")
            ? database.scalarInt("SELECT COALESCE(MAX(version), 0) FROM _sqlx_migrations WHERE success = 1")
            : 0
        guard version <= Self.currentMigrationVersion else { throw YCodeMigrationError.futureSchema(version) }

        let sessionColumns = try database.columns(in: "sessions")
        let schema: LegacySchemaKind
        if sessionColumns.contains("agent_session_id") && sessionColumns.contains("base_branch") {
            schema = .current
        } else if sessionColumns.contains("project_id") {
            schema = .terminalFirst
        } else if sessionColumns.contains("repo_root") {
            schema = .initial
        } else {
            throw YCodeMigrationError.unsupportedSchema("sessions has no project_id or repo_root")
        }

        func count(_ table: String) throws -> Int {
            try database.tableExists(table) ? database.scalarInt("SELECT COUNT(*) FROM \(table)") : 0
        }
        let archived = sessionColumns.contains("archived_at")
            ? try database.scalarInt("SELECT COUNT(*) FROM sessions WHERE archived_at IS NOT NULL") : 0
        let worktrees = sessionColumns.contains("worktree_path")
            ? try database.scalarInt("SELECT COUNT(*) FROM sessions WHERE worktree_path IS NOT NULL") : 0
        return LegacyDataSummary(
            schema: schema,
            migrationVersion: version,
            projects: try count("projects"),
            sessions: try count("sessions"),
            archivedSessions: archived,
            worktreeSessions: worktrees,
            todos: try count("project_todos"),
            lspInstallations: try count("lsp_installations"),
            checkpoints: try count("session_checkpoints")
        )
    }

    private func normalize(snapshot: SQLiteConnection, sourceURL: URL, destinationURL: URL) throws {
        let destination = try SQLiteConnection(path: destinationURL.path)
        try destination.execute(Self.currentSchemaSQL)
        try destination.execute("ATTACH DATABASE \(sqlLiteral(sourceURL.path)) AS legacy")
        defer { try? destination.execute("DETACH DATABASE legacy") }

        let sessionColumns = try snapshot.columns(in: "sessions")
        let hasProjects = try snapshot.tableExists("projects")
        if hasProjects {
            let projectColumns = try snapshot.columns(in: "projects")
            let isolation = projectColumns.contains("isolate_sessions") ? "isolate_sessions" : "0"
            try destination.execute("""
                INSERT INTO projects (id, name, repo_path, created_at, isolate_sessions)
                SELECT id, name, repo_path, created_at, \(isolation) FROM legacy.projects;
                """)
        } else {
            guard sessionColumns.contains("repo_root") else {
                throw YCodeMigrationError.unsupportedSchema("projects table and sessions.repo_root are both missing")
            }
            try destination.execute("""
                INSERT INTO projects (id, name, repo_path, created_at, isolate_sessions)
                SELECT 'legacy-' || lower(hex(randomblob(8))), repo_root, repo_root, MIN(created_at), 0
                FROM legacy.sessions GROUP BY repo_root;
                """)
        }

        func expression(_ column: String, fallback: String = "NULL") -> String {
            sessionColumns.contains(column) ? "s.\(column)" : fallback
        }
        let projectID = sessionColumns.contains("project_id")
            ? "s.project_id"
            : "(SELECT p.id FROM projects p WHERE p.repo_path = s.repo_root LIMIT 1)"
        let baseBranch = sessionColumns.contains("base_branch")
            ? "s.base_branch"
            : expression("base_ref")
        try destination.execute("""
            INSERT INTO sessions (
                id, title, agent_profile, project_id, last_exit_code,
                created_at, updated_at, archived_at, agent_session_id,
                agent_thread_name, worktree_path, branch, base_branch
            )
            SELECT
                s.id, s.title, s.agent_profile, \(projectID), \(expression("last_exit_code")),
                s.created_at, s.updated_at, \(expression("archived_at")), \(expression("agent_session_id")),
                \(expression("agent_thread_name")), \(expression("worktree_path")), \(expression("branch")), \(baseBranch)
            FROM legacy.sessions s
            WHERE \(projectID) IS NOT NULL;
            """)

        if try snapshot.tableExists("project_todos") {
            let columns = try snapshot.columns(in: "project_todos")
            let started = columns.contains("started_at") ? "started_at" : "NULL"
            let done = columns.contains("done_at") ? "done_at" : "NULL"
            try destination.execute("""
                INSERT INTO project_todos (id, project_id, title, status, sort_order, created_at, updated_at, started_at, done_at)
                SELECT id, project_id, title, status, sort_order, created_at, updated_at, \(started), \(done)
                FROM legacy.project_todos;
                """)
        }
        if try snapshot.tableExists("lsp_installations") {
            try destination.execute("""
                INSERT INTO lsp_installations (id, version, binary_path, installed_at)
                SELECT id, version, binary_path, installed_at FROM legacy.lsp_installations;
                """)
        }
        if try snapshot.tableExists("session_checkpoints") {
            try destination.execute("""
                INSERT INTO session_checkpoints (
                    id, session_id, project_id, sequence, commit_sha, ref_name,
                    kind, source, event_kind, body_preview, created_at
                )
                SELECT id, session_id, project_id, sequence, commit_sha, ref_name,
                    kind, source, event_kind, body_preview, created_at
                FROM legacy.session_checkpoints;
                """)
        }
    }

    private func fingerprint(database: URL, configuration: Data) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: database))
        hasher.update(data: configuration)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static let currentSchemaSQL = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE projects (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, repo_path TEXT NOT NULL,
            created_at INTEGER NOT NULL, isolate_sessions INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, agent_profile TEXT NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            last_exit_code INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            archived_at INTEGER, agent_session_id TEXT, agent_thread_name TEXT,
            worktree_path TEXT, branch TEXT, base_branch TEXT
        );
        CREATE INDEX idx_sessions_archived ON sessions(archived_at);
        CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC);
        CREATE INDEX idx_sessions_project ON sessions(project_id);
        CREATE TABLE lsp_installations (
            id TEXT PRIMARY KEY, version TEXT NOT NULL, binary_path TEXT NOT NULL,
            installed_at INTEGER NOT NULL
        );
        CREATE TABLE project_todos (
            id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            title TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'todo', sort_order INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, started_at INTEGER, done_at INTEGER
        );
        CREATE INDEX idx_project_todos_project ON project_todos(project_id);
        CREATE TABLE session_checkpoints (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            sequence INTEGER NOT NULL, commit_sha TEXT NOT NULL, ref_name TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL CHECK (kind IN ('initial', 'turn')), source TEXT,
            event_kind TEXT, body_preview TEXT, created_at INTEGER NOT NULL,
            UNIQUE (session_id, sequence)
        );
        CREATE INDEX idx_session_checkpoints_project_created ON session_checkpoints(project_id, created_at DESC);
        CREATE INDEX idx_session_checkpoints_session_sequence ON session_checkpoints(session_id, sequence DESC);
        """
}
