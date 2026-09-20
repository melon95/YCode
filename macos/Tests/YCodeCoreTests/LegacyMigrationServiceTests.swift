import Foundation
import XCTest
@testable import YCodeCore

final class LegacyMigrationServiceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testCurrentSchemaImportPreservesAllRequiredDataAndUnknownConfig() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let sourceDB = root.appendingPathComponent("source.db")
        let sourceConfig = root.appendingPathComponent("config.json")
        let source = try makeCurrentDatabase(at: sourceDB, includeRows: true)
        try writeConfig(to: sourceConfig, marker: "one")

        let destination = root.appendingPathComponent("native", isDirectory: true)
        let outcome = try LegacyMigrationService().importLegacyData(
            database: sourceDB,
            configuration: sourceConfig,
            to: destination
        )

        XCTAssertEqual(outcome.status, .imported)
        XCTAssertEqual(outcome.summary.schema, .current)
        XCTAssertEqual(outcome.summary.migrationVersion, 12)
        XCTAssertEqual(outcome.summary.projects, 1)
        XCTAssertEqual(outcome.summary.sessions, 1)
        XCTAssertEqual(outcome.summary.archivedSessions, 1)
        XCTAssertEqual(outcome.summary.worktreeSessions, 1)
        XCTAssertEqual(outcome.summary.todos, 1)
        XCTAssertEqual(outcome.summary.lspInstallations, 1)
        XCTAssertEqual(outcome.summary.checkpoints, 1)

        let normalized = try SQLiteConnection(path: destination.appendingPathComponent("ycode.db").path, readOnly: true)
        XCTAssertEqual(try normalized.scalarString("SELECT agent_session_id FROM sessions WHERE id='s1'"), "agent-session-1")
        XCTAssertEqual(try normalized.scalarString("SELECT base_branch FROM sessions WHERE id='s1'"), "main")
        XCTAssertEqual(try normalized.scalarInt("SELECT isolate_sessions FROM projects WHERE id='p1'"), 1)
        XCTAssertEqual(try source.scalarInt("SELECT COUNT(*) FROM sessions"), 1, "source must remain readable and unchanged")

        let copiedConfig = try Data(contentsOf: destination.appendingPathComponent("config.json"))
        XCTAssertEqual(copiedConfig, try Data(contentsOf: sourceConfig), "initial import keeps config bytes exactly")
        var document = try PreservingJSONDocument(data: copiedConfig)
        let unknown = document["future_field"]
        document["theme"] = .string("foundry")
        let roundTrip = try PreservingJSONDocument(data: document.encodedData())
        XCTAssertEqual(roundTrip["future_field"], unknown)
    }

    func testInitialSchemaIsNormalizedWithoutDroppingWorktreeMetadata() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let sourceDB = root.appendingPathComponent("old.db")
        let sourceConfig = root.appendingPathComponent("config.json")
        try makeInitialDatabase(at: sourceDB)
        try writeConfig(to: sourceConfig, marker: "old")

        let destination = root.appendingPathComponent("native", isDirectory: true)
        let outcome = try LegacyMigrationService().importLegacyData(
            database: sourceDB,
            configuration: sourceConfig,
            to: destination
        )

        XCTAssertEqual(outcome.summary.projects, 1)
        XCTAssertEqual(outcome.summary.sessions, 1)
        XCTAssertEqual(outcome.summary.worktreeSessions, 1)
        let normalized = try SQLiteConnection(path: destination.appendingPathComponent("ycode.db").path, readOnly: true)
        XCTAssertEqual(try normalized.scalarString("SELECT repo_path FROM projects LIMIT 1"), "/tmp/旧 项目")
        XCTAssertEqual(try normalized.scalarString("SELECT worktree_path FROM sessions WHERE id='old-s1'"), "/tmp/worktree-old")
        XCTAssertEqual(try normalized.scalarString("SELECT branch FROM sessions WHERE id='old-s1'"), "ycode/old-s1")
        XCTAssertEqual(try normalized.scalarString("SELECT base_branch FROM sessions WHERE id='old-s1'"), "abc123")
    }

    func testOnlineBackupIncludesUncheckpointedWALRows() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let sourceDB = root.appendingPathComponent("wal.db")
        let sourceConfig = root.appendingPathComponent("config.json")
        let source = try makeCurrentDatabase(at: sourceDB, includeRows: false)
        try source.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try source.execute("INSERT INTO projects VALUES ('wal-p', 'WAL', '/tmp/wal', 1, 0);")
        try source.execute("INSERT INTO sessions VALUES ('wal-s', 'WAL session', 'codex', 'wal-p', NULL, 1, 1, NULL, NULL, NULL, NULL, NULL, NULL);")
        XCTAssertTrue(fileManager.fileExists(atPath: sourceDB.path + "-wal"))
        try writeConfig(to: sourceConfig, marker: "wal")

        let outcome = try LegacyMigrationService().importLegacyData(
            database: sourceDB,
            configuration: sourceConfig,
            to: root.appendingPathComponent("native", isDirectory: true)
        )
        XCTAssertEqual(outcome.summary.projects, 1)
        XCTAssertEqual(outcome.summary.sessions, 1)
    }

    func testEmptyCurrentDatabaseImportsAsEmpty() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let sourceDB = root.appendingPathComponent("empty.db")
        let sourceConfig = root.appendingPathComponent("config.json")
        _ = try makeCurrentDatabase(at: sourceDB, includeRows: false)
        try writeConfig(to: sourceConfig, marker: "empty")

        let outcome = try LegacyMigrationService().importLegacyData(
            database: sourceDB,
            configuration: sourceConfig,
            to: root.appendingPathComponent("native", isDirectory: true)
        )
        XCTAssertEqual(outcome.summary.projects, 0)
        XCTAssertEqual(outcome.summary.sessions, 0)
        XCTAssertEqual(outcome.summary.todos, 0)
    }

    func testRepeatedImportIsIdempotent() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let sourceDB = root.appendingPathComponent("source.db")
        let sourceConfig = root.appendingPathComponent("config.json")
        _ = try makeCurrentDatabase(at: sourceDB, includeRows: true)
        try writeConfig(to: sourceConfig, marker: "repeat")
        let destination = root.appendingPathComponent("native", isDirectory: true)
        let service = LegacyMigrationService()

        XCTAssertEqual(try service.importLegacyData(database: sourceDB, configuration: sourceConfig, to: destination).status, .imported)
        XCTAssertEqual(try service.importLegacyData(database: sourceDB, configuration: sourceConfig, to: destination).status, .alreadyImported)
        let normalized = try SQLiteConnection(path: destination.appendingPathComponent("ycode.db").path, readOnly: true)
        XCTAssertEqual(try normalized.scalarInt("SELECT COUNT(*) FROM sessions"), 1)
    }

    func testInterruptionAndCorruptionLeaveNoCommittedOrStagingData() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let sourceDB = root.appendingPathComponent("source.db")
        let sourceConfig = root.appendingPathComponent("config.json")
        _ = try makeCurrentDatabase(at: sourceDB, includeRows: true)
        try writeConfig(to: sourceConfig, marker: "interrupt")
        let destination = root.appendingPathComponent("native", isDirectory: true)

        XCTAssertThrowsError(try LegacyMigrationService().importLegacyData(
            database: sourceDB,
            configuration: sourceConfig,
            to: destination,
            interruptAfter: .beforeCommit
        )) { error in
            XCTAssertEqual(error as? YCodeMigrationError, .injectedInterruption(.beforeCommit))
        }
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".ycode-import-") })

        let corrupt = root.appendingPathComponent("corrupt.db")
        try Data("not sqlite".utf8).write(to: corrupt)
        XCTAssertThrowsError(try LegacyMigrationService().importLegacyData(
            database: corrupt,
            configuration: sourceConfig,
            to: destination
        ))
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".ycode-import-") })
    }

    func testFutureSchemaAndDifferentExistingImportAreRefused() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let sourceDB = root.appendingPathComponent("source.db")
        let sourceConfig = root.appendingPathComponent("config.json")
        let source = try makeCurrentDatabase(at: sourceDB, includeRows: true)
        try source.execute("INSERT INTO _sqlx_migrations VALUES (13, 1);")
        try writeConfig(to: sourceConfig, marker: "future")
        let destination = root.appendingPathComponent("native", isDirectory: true)

        XCTAssertThrowsError(try LegacyMigrationService().importLegacyData(
            database: sourceDB,
            configuration: sourceConfig,
            to: destination
        )) { error in
            XCTAssertEqual(error as? YCodeMigrationError, .futureSchema(13))
        }
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))

        try source.execute("DELETE FROM _sqlx_migrations WHERE version = 13;")
        _ = try LegacyMigrationService().importLegacyData(database: sourceDB, configuration: sourceConfig, to: destination)
        try writeConfig(to: sourceConfig, marker: "changed")
        XCTAssertThrowsError(try LegacyMigrationService().importLegacyData(
            database: sourceDB,
            configuration: sourceConfig,
            to: destination
        )) { error in
            XCTAssertEqual(error as? YCodeMigrationError, .destinationAlreadyContainsDifferentImport)
        }
    }

    private func makeTemporaryRoot() -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent("ycode-m12-tests-\(UUID().uuidString)", isDirectory: true)
        try! fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeConfig(to url: URL, marker: String) throws {
        try Data("""
            {
              "theme": "snow",
              "agents": [],
              "future_field": {"marker": "\(marker)", "nested": [1, true, null]}
            }
            """.utf8).write(to: url)
    }

    @discardableResult
    private func makeCurrentDatabase(at url: URL, includeRows: Bool) throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: url.path)
        try db.execute("""
            PRAGMA foreign_keys=ON;
            CREATE TABLE _sqlx_migrations (version INTEGER PRIMARY KEY, success INTEGER NOT NULL);
            INSERT INTO _sqlx_migrations VALUES (12, 1);
            CREATE TABLE projects (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, repo_path TEXT NOT NULL,
                created_at INTEGER NOT NULL, isolate_sessions INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, agent_profile TEXT NOT NULL,
                project_id TEXT NOT NULL REFERENCES projects(id), last_exit_code INTEGER,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, archived_at INTEGER,
                agent_session_id TEXT, agent_thread_name TEXT, worktree_path TEXT,
                branch TEXT, base_branch TEXT
            );
            CREATE TABLE project_todos (
                id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), title TEXT NOT NULL,
                status TEXT NOT NULL, sort_order INTEGER NOT NULL, created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL, started_at INTEGER, done_at INTEGER
            );
            CREATE TABLE lsp_installations (
                id TEXT PRIMARY KEY, version TEXT NOT NULL, binary_path TEXT NOT NULL, installed_at INTEGER NOT NULL
            );
            CREATE TABLE session_checkpoints (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id),
                project_id TEXT NOT NULL REFERENCES projects(id), sequence INTEGER NOT NULL,
                commit_sha TEXT NOT NULL, ref_name TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL, source TEXT, event_kind TEXT, body_preview TEXT,
                created_at INTEGER NOT NULL
            );
            """)
        if includeRows {
            try db.execute("""
                INSERT INTO projects VALUES ('p1', '项目一', '/tmp/项目 一', 100, 1);
                INSERT INTO sessions VALUES (
                    's1', '会话一', 'codex', 'p1', 0, 100, 200, 300,
                    'agent-session-1', '线程一', '/tmp/worktree', 'ycode/s1', 'main'
                );
                INSERT INTO project_todos VALUES ('t1', 'p1', '待办一', 'done', 0, 100, 200, 150, 200);
                INSERT INTO lsp_installations VALUES ('rust-analyzer', '1', '/tmp/ra', 100);
                INSERT INTO session_checkpoints VALUES (
                    'c1', 's1', 'p1', 0, 'abc', 'refs/ycode/c1', 'initial', NULL, NULL, NULL, 100
                );
                """)
        }
        return db
    }

    private func makeInitialDatabase(at url: URL) throws {
        let db = try SQLiteConnection(path: url.path)
        try db.execute("""
            CREATE TABLE _sqlx_migrations (version INTEGER PRIMARY KEY, success INTEGER NOT NULL);
            INSERT INTO _sqlx_migrations VALUES (1, 1);
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, agent_profile TEXT NOT NULL,
                repo_root TEXT NOT NULL, worktree_path TEXT NOT NULL, branch TEXT NOT NULL,
                base_ref TEXT NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL, archived_at INTEGER
            );
            INSERT INTO sessions VALUES (
                'old-s1', '旧会话', 'claude-code', '/tmp/旧 项目', '/tmp/worktree-old',
                'ycode/old-s1', 'abc123', '{}', 10, 20, NULL
            );
            """)
    }
}
