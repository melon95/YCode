import Foundation

public struct ProjectRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let repositoryURL: URL
    public let createdAtMilliseconds: Int64
    public let isolateSessions: Bool
    public let liveSessionCount: Int
    public let totalSessionCount: Int

    public var pathExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

public enum SessionRecoveryAvailability: String, Sendable {
    case available
    case unsupportedWorktree
}

public struct SessionMetadata: Identifiable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let title: String
    public let agentProfile: String
    public let agentSessionID: String?
    public let agentThreadName: String?
    public let lastExitCode: Int64?
    public let updatedAtMilliseconds: Int64
    public let archivedAtMilliseconds: Int64?
    public let worktreePath: String?
    public let branch: String?
    public let baseBranch: String?

    public var recoveryAvailability: SessionRecoveryAvailability {
        worktreePath == nil ? .available : .unsupportedWorktree
    }
}

public enum ProjectWorkspaceError: Error, Equatable, CustomStringConvertible {
    case invalidProjectDirectory(String)
    case duplicateProject(String)
    case projectNotFound(String)
    case invalidOrder
    case sessionNotFound(String)
    case sessionArchived(String)

    public var description: String {
        switch self {
        case let .invalidProjectDirectory(path): "invalid project directory: \(path)"
        case let .duplicateProject(path): "project already exists: \(path)"
        case let .projectNotFound(id): "project not found: \(id)"
        case .invalidOrder: "project order must contain every project exactly once"
        case let .sessionNotFound(id): "session not found: \(id)"
        case let .sessionArchived(id): "session is archived: \(id)"
        }
    }
}

public final class ProjectWorkspaceRepository {
    private let database: SQLiteConnection

    public init(databaseURL: URL) throws {
        try TandockNativeDatabase.prepare(at: databaseURL)
        database = try SQLiteConnection(path: databaseURL.path)
        try database.execute("PRAGMA foreign_keys=ON")
        try database.execute(Self.nativeMetadataSchema)
        if try !database.columns(in: "native_discovered_sessions").contains("jsonl_path") {
            try database.execute("ALTER TABLE native_discovered_sessions ADD COLUMN jsonl_path TEXT")
        }
        try reconcileProjectOrder()
    }

    public func listProjects() throws -> [ProjectRecord] {
        try database.query("""
            SELECT p.id, p.name, p.repo_path, p.created_at, p.isolate_sessions,
                   (SELECT COUNT(*) FROM sessions s WHERE s.project_id=p.id AND s.archived_at IS NULL),
                   (SELECT COUNT(*) FROM sessions s WHERE s.project_id=p.id)
            FROM projects p
            LEFT JOIN native_project_order o ON o.project_id=p.id
            ORDER BY CASE WHEN o.sort_order IS NULL THEN 1 ELSE 0 END,
                     o.sort_order, p.created_at DESC, p.id;
            """) { row in
                ProjectRecord(
                    id: sqliteString(row, column: 0) ?? "",
                    name: sqliteString(row, column: 1) ?? "",
                    repositoryURL: URL(fileURLWithPath: sqliteString(row, column: 2) ?? "", isDirectory: true),
                    createdAtMilliseconds: sqliteInt(row, column: 3) ?? 0,
                    isolateSessions: (sqliteInt(row, column: 4) ?? 0) != 0,
                    liveSessionCount: Int(sqliteInt(row, column: 5) ?? 0),
                    totalSessionCount: Int(sqliteInt(row, column: 6) ?? 0)
                )
            }
    }

    public func listSessions(projectID: String, includeArchived: Bool = false) throws -> [SessionMetadata] {
        let archivedClause = includeArchived ? "" : "AND archived_at IS NULL"
        return try database.query("""
            SELECT id, title, agent_profile, agent_session_id, agent_thread_name,
                   last_exit_code, updated_at, archived_at, worktree_path, branch, base_branch, project_id
            FROM sessions WHERE project_id=? \(archivedClause)
            ORDER BY archived_at IS NOT NULL, updated_at DESC, id;
            """, bindings: [.text(projectID)], map: Self.sessionMetadata)
    }

    public func session(id: String) throws -> SessionMetadata {
        let rows = try database.query("""
            SELECT id, title, agent_profile, agent_session_id, agent_thread_name,
                   last_exit_code, updated_at, archived_at, worktree_path, branch, base_branch, project_id
            FROM sessions WHERE id=?;
            """, bindings: [.text(id)], map: Self.sessionMetadata)
        guard let row = rows.first else { throw ProjectWorkspaceError.sessionNotFound(id) }
        return row
    }

    @discardableResult
    public func createSession(
        id: String = UUID().uuidString.lowercased(),
        projectID: String,
        title: String,
        agentProfile: String,
        agentSessionID: String? = nil,
        agentThreadName: String? = nil
    ) throws -> SessionMetadata {
        guard try database.scalarInt("SELECT COUNT(*) FROM projects WHERE id=\(sqlLiteral(projectID))") == 1 else {
            throw ProjectWorkspaceError.projectNotFound(projectID)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try database.execute("""
            INSERT INTO sessions (
                id,title,agent_profile,project_id,last_exit_code,created_at,updated_at,archived_at,
                agent_session_id,agent_thread_name,worktree_path,branch,base_branch
            ) VALUES (?,?,?,?,NULL,?,?,NULL,?,?,NULL,NULL,NULL)
            """, bindings: [
                .text(id), .text(title), .text(agentProfile), .text(projectID),
                .integer(now), .integer(now),
                agentSessionID.map(SQLiteBinding.text) ?? .null,
                agentThreadName.map(SQLiteBinding.text) ?? .null
            ])
        return try session(id: id)
    }

    @discardableResult
    public func syncDiscoveredSessions(_ drafts: [DiscoveredSessionDraft]) throws -> [SessionMetadata] {
        guard !drafts.isEmpty else { return [] }
        var touched: [String] = []
        try transaction {
            for draft in drafts {
                let existing = try database.query("""
                    SELECT id, title, agent_profile, agent_session_id, agent_thread_name,
                           last_exit_code, updated_at, archived_at, worktree_path, branch, base_branch, project_id
                    FROM sessions WHERE project_id=? AND agent_session_id=? AND agent_profile=?;
                    """, bindings: [.text(draft.projectID), .text(draft.agentSessionID), .text(draft.agentProfile)], map: Self.sessionMetadata)
                guard let row = existing.first else {
                    let id = UUID().uuidString.lowercased()
                    try database.execute("""
                        INSERT INTO sessions (
                            id,title,agent_profile,project_id,last_exit_code,created_at,updated_at,archived_at,
                            agent_session_id,agent_thread_name,worktree_path,branch,base_branch
                        ) VALUES (?,?,?,?,NULL,?,?,?,?,NULL,NULL,NULL,NULL)
                        """, bindings: [
                            .text(id), .text(draft.title), .text(draft.agentProfile), .text(draft.projectID),
                            .integer(draft.updatedAtMilliseconds), .integer(draft.updatedAtMilliseconds),
                            draft.archivedAtMilliseconds.map(SQLiteBinding.integer) ?? .null,
                            .text(draft.agentSessionID)
                        ])
                    try recordDiscovered(sessionID: id, title: draft.title, jsonlPath: draft.jsonlPath)
                    touched.append(id)
                    continue
                }
                let recorded = try discoveredTitle(sessionID: row.id)
                let pending = try pendingSessionTitle(id: row.id)
                var changed = false
                if pending == nil, row.title.isEmpty || row.title == recorded || (recorded != nil && recorded != draft.title) {
                    if row.title != draft.title {
                        try database.execute("UPDATE sessions SET title=? WHERE id=?",
                                             bindings: [.text(draft.title), .text(row.id)])
                        changed = true
                    }
                }
                try recordDiscovered(sessionID: row.id, title: draft.title, jsonlPath: draft.jsonlPath)
                if draft.updatedAtMilliseconds > row.updatedAtMilliseconds {
                    try database.execute(
                        "UPDATE sessions SET updated_at=? WHERE id=?",
                        bindings: [.integer(draft.updatedAtMilliseconds), .text(row.id)]
                    )
                    changed = true
                    if draft.archivedAtMilliseconds == nil, row.archivedAtMilliseconds != nil {
                        try database.execute(
                            "UPDATE sessions SET archived_at=NULL WHERE id=?",
                            bindings: [.text(row.id)]
                        )
                    }
                }
                if changed { touched.append(row.id) }
            }
        }
        return try touched.compactMap { try? session(id: $0) }
    }

    private func discoveredTitle(sessionID: String) throws -> String? {
        try database.query(
            "SELECT discovered_title FROM native_discovered_sessions WHERE session_id=?",
            bindings: [.text(sessionID)]
        ) { sqliteString($0, column: 0) }.first ?? nil
    }

    private func recordDiscovered(sessionID: String, title: String, jsonlPath: String) throws {
        try database.execute("""
            INSERT INTO native_discovered_sessions (session_id,discovered_title,jsonl_path) VALUES (?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET
                discovered_title=excluded.discovered_title,
                jsonl_path=excluded.jsonl_path
            """, bindings: [.text(sessionID), .text(title), .text(jsonlPath)])
    }

    public func discoveredJsonlPath(sessionID: String) throws -> String? {
        try database.query(
            "SELECT jsonl_path FROM native_discovered_sessions WHERE session_id=?",
            bindings: [.text(sessionID)]
        ) { sqliteString($0, column: 0) }.first ?? nil
    }

    public func deleteSession(id: String) throws {
        guard try database.execute("DELETE FROM sessions WHERE id=?", bindings: [.text(id)]) == 1 else {
            throw ProjectWorkspaceError.sessionNotFound(id)
        }
    }

    @discardableResult
    public func renameSession(id: String, title: String) throws -> SessionMetadata {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try transaction {
            guard try database.execute(
                "UPDATE sessions SET title=?,updated_at=? WHERE id=?",
                bindings: [.text(title), .integer(now), .text(id)]
            ) == 1 else { throw ProjectWorkspaceError.sessionNotFound(id) }
            try database.execute("""
                INSERT INTO native_session_title_sync (session_id,pending_title,last_error) VALUES (?,?,NULL)
                ON CONFLICT(session_id) DO UPDATE SET pending_title=excluded.pending_title,last_error=NULL
                """, bindings: [.text(id), .text(title)])
        }
        return try session(id: id)
    }

    public func sessionTitleSyncError(id: String) throws -> String? {
        try database.query("SELECT last_error FROM native_session_title_sync WHERE session_id=?",
                           bindings: [.text(id)]) { sqliteString($0, column: 0) }.first ?? nil
    }

    public func pendingSessionTitle(id: String) throws -> String? {
        try database.query("SELECT pending_title FROM native_session_title_sync WHERE session_id=?",
                           bindings: [.text(id)]) { sqliteString($0, column: 0) }.first ?? nil
    }

    public func finishSessionTitleSync(id: String, requested: String, confirmed: String?, error: String?) throws {
        try transaction {
            guard try pendingSessionTitle(id: id) == requested else { return }
            if let confirmed {
                try database.execute("UPDATE sessions SET title=? WHERE id=?", bindings: [.text(confirmed), .text(id)])
                try recordDiscovered(sessionID: id, title: confirmed, jsonlPath: try discoveredJsonlPath(sessionID: id) ?? "")
                try database.execute("DELETE FROM native_session_title_sync WHERE session_id=?", bindings: [.text(id)])
            } else {
                try database.execute("UPDATE native_session_title_sync SET last_error=? WHERE session_id=?",
                                     bindings: [error.map(SQLiteBinding.text) ?? .null, .text(id)])
            }
        }
    }

    public func setSessionExitCode(id: String, exitCode: Int32?) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard try database.execute(
            "UPDATE sessions SET last_exit_code=?,updated_at=? WHERE id=?",
            bindings: [exitCode.map { .integer(Int64($0)) } ?? .null, .integer(now), .text(id)]
        ) == 1 else { throw ProjectWorkspaceError.sessionNotFound(id) }
    }

    public func setAgentSessionID(id: String, agentSessionID: String) throws {
        guard try database.execute(
            "UPDATE sessions SET agent_session_id=? WHERE id=?",
            bindings: [.text(agentSessionID), .text(id)]
        ) == 1 else { throw ProjectWorkspaceError.sessionNotFound(id) }
    }

    public func pinnedSessionIDs() throws -> Set<String> {
        Set(try database.query("SELECT session_id FROM native_session_pins") { sqliteString($0, column: 0) ?? "" })
    }

    public func setSessionPinned(id: String, pinned: Bool) throws {
        let row = try session(id: id)
        if pinned {
            guard row.archivedAtMilliseconds == nil else { throw ProjectWorkspaceError.sessionArchived(id) }
            try database.execute("INSERT OR IGNORE INTO native_session_pins (session_id) VALUES (?)", bindings: [.text(id)])
        } else {
            try database.execute("DELETE FROM native_session_pins WHERE session_id=?", bindings: [.text(id)])
        }
    }

    public func archiveSession(id: String) throws {
        let row = try session(id: id)
        if row.archivedAtMilliseconds != nil { return }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try transaction {
            guard try database.execute(
                "UPDATE sessions SET archived_at=?,updated_at=? WHERE id=? AND archived_at IS NULL",
                bindings: [.integer(now), .integer(now), .text(id)]
            ) == 1 else { throw ProjectWorkspaceError.sessionNotFound(id) }
            try database.execute("DELETE FROM native_session_pins WHERE session_id=?", bindings: [.text(id)])
        }
    }

    @discardableResult
    public func archiveSessionsIdle(before cutoffMilliseconds: Int64, keeping keptIDs: Set<String> = []) throws -> [SessionMetadata] {
        let stale = try database.query("""
            SELECT id, title, agent_profile, agent_session_id, agent_thread_name,
                   last_exit_code, updated_at, archived_at, worktree_path, branch, base_branch, project_id
            FROM sessions WHERE archived_at IS NULL AND updated_at < ?
              AND id NOT IN (SELECT session_id FROM native_session_pins)
            ORDER BY updated_at, id;
            """, bindings: [.integer(cutoffMilliseconds)], map: Self.sessionMetadata)
            .filter { !keptIDs.contains($0.id) }
        guard !stale.isEmpty else { return [] }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try transaction {
            for row in stale {
                try database.execute(
                    "UPDATE sessions SET archived_at=? WHERE id=? AND archived_at IS NULL",
                    bindings: [.integer(now), .text(row.id)]
                )
            }
        }
        return stale
    }

    public func unarchiveSession(id: String) throws {
        let row = try session(id: id)
        if row.archivedAtMilliseconds == nil { return }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard try database.execute(
            "UPDATE sessions SET archived_at=NULL,updated_at=? WHERE id=? AND archived_at IS NOT NULL",
            bindings: [.integer(now), .text(id)]
        ) == 1 else { throw ProjectWorkspaceError.sessionNotFound(id) }
    }

    @discardableResult
    public func addProject(directory: URL, name: String? = nil) throws -> ProjectRecord {
        var isDirectory: ObjCBool = false
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectWorkspaceError.invalidProjectDirectory(directory.path)
        }
        if try database.scalarInt("SELECT COUNT(*) FROM projects WHERE repo_path=\(sqlLiteral(canonical.path))") > 0 {
            throw ProjectWorkspaceError.duplicateProject(canonical.path)
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.flatMap { $0.isEmpty ? nil : $0 } ?? canonical.lastPathComponent
        let id = UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)

        try transaction {
            try database.execute(
                "INSERT INTO projects (id,name,repo_path,created_at,isolate_sessions) VALUES (?,?,?,?,0)",
                bindings: [.text(id), .text(displayName), .text(canonical.path), .integer(now)]
            )
            let next = try database.scalarInt("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM native_project_order")
            try database.execute(
                "INSERT INTO native_project_order (project_id,sort_order) VALUES (?,?)",
                bindings: [.text(id), .integer(Int64(next))]
            )
            if try selectedProjectID() == nil {
                try setSelectedProjectID(id)
            }
        }
        return try listProjects().first { $0.id == id }!
    }

    public func reorderProjects(_ orderedIDs: [String]) throws {
        let existing = try Set(listProjects().map(\.id))
        guard orderedIDs.count == existing.count, Set(orderedIDs) == existing else {
            throw ProjectWorkspaceError.invalidOrder
        }
        try transaction {
            try database.execute("DELETE FROM native_project_order")
            for (index, id) in orderedIDs.enumerated() {
                try database.execute(
                    "INSERT INTO native_project_order (project_id,sort_order) VALUES (?,?)",
                    bindings: [.text(id), .integer(Int64(index))]
                )
            }
        }
    }

    public func selectedProjectID() throws -> String? {
        try database.scalarString("SELECT value FROM native_workspace_state WHERE key='selected_project_id'")
    }

    public func setSelectedProjectID(_ id: String?) throws {
        if let id {
            guard try database.scalarInt("SELECT COUNT(*) FROM projects WHERE id=\(sqlLiteral(id))") == 1 else {
                throw ProjectWorkspaceError.projectNotFound(id)
            }
            try database.execute(
                "INSERT INTO native_workspace_state (key,value) VALUES ('selected_project_id',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                bindings: [.text(id)]
            )
        } else {
            try database.execute("DELETE FROM native_workspace_state WHERE key='selected_project_id'")
        }
    }

    public func deleteProject(id: String) throws {
        guard let project = try listProjects().first(where: { $0.id == id }) else {
            throw ProjectWorkspaceError.projectNotFound(id)
        }
        let repositoryPath = project.repositoryURL.path
        try transaction {
            let changed = try database.execute("DELETE FROM projects WHERE id=?", bindings: [.text(id)])
            guard changed == 1 else { throw ProjectWorkspaceError.projectNotFound(id) }
            if try selectedProjectID() == id {
                try setSelectedProjectID(try listProjects().first?.id)
            }
            try reconcileProjectOrder()
        }
        _ = FileManager.default.fileExists(atPath: repositoryPath)
    }

    private func reconcileProjectOrder() throws {
        let projectIDs = try database.query("SELECT id FROM projects ORDER BY created_at DESC, id") {
            sqliteString($0, column: 0) ?? ""
        }
        let existing = try database.query("""
            SELECT o.project_id FROM native_project_order o
            JOIN projects p ON p.id=o.project_id ORDER BY o.sort_order, o.project_id
            """) { sqliteString($0, column: 0) ?? "" }
        var seen = Set<String>()
        let projectSet = Set(projectIDs)
        var reconciled = existing.filter { projectSet.contains($0) && seen.insert($0).inserted }
        reconciled.append(contentsOf: projectIDs.filter { seen.insert($0).inserted })
        if reconciled != existing {
            try transaction {
                try database.execute("DELETE FROM native_project_order")
                for (index, id) in reconciled.enumerated() {
                    try database.execute(
                        "INSERT INTO native_project_order (project_id,sort_order) VALUES (?,?)",
                        bindings: [.text(id), .integer(Int64(index))]
                    )
                }
            }
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try body()
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private static func sessionMetadata(_ row: OpaquePointer) -> SessionMetadata {
        SessionMetadata(
            id: sqliteString(row, column: 0) ?? "",
            projectID: sqliteString(row, column: 11) ?? "",
            title: sqliteString(row, column: 1) ?? "",
            agentProfile: sqliteString(row, column: 2) ?? "",
            agentSessionID: sqliteString(row, column: 3),
            agentThreadName: sqliteString(row, column: 4),
            lastExitCode: sqliteInt(row, column: 5),
            updatedAtMilliseconds: sqliteInt(row, column: 6) ?? 0,
            archivedAtMilliseconds: sqliteInt(row, column: 7),
            worktreePath: sqliteString(row, column: 8),
            branch: sqliteString(row, column: 9),
            baseBranch: sqliteString(row, column: 10)
        )
    }

    private static let nativeMetadataSchema = """
        CREATE TABLE IF NOT EXISTS native_project_order (
            project_id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
            sort_order INTEGER NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS native_workspace_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS native_session_pins (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS native_session_title_sync (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
            pending_title TEXT,
            last_error TEXT
        );
        CREATE TABLE IF NOT EXISTS native_discovered_sessions (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
            discovered_title TEXT NOT NULL,
            jsonl_path TEXT
        );
        """
}
