import Foundation
import XCTest
@testable import YCodeCore

final class ProjectWorkspaceRepositoryTests: XCTestCase {
    private let fileManager = FileManager.default

    func testThreeProjectCRUDOrderSelectionPersistAndDiskUntouched() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("data/ycode.db")
        let directories = ["项目 一", "project two", "nested/项目三"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var repository: ProjectWorkspaceRepository? = try ProjectWorkspaceRepository(databaseURL: databaseURL)
        let first = try repository!.addProject(directory: directories[0], name: "一")
        let second = try repository!.addProject(directory: directories[1], name: "二")
        let third = try repository!.addProject(directory: directories[2], name: "三")
        XCTAssertEqual(try repository!.listProjects().map(\.id), [first.id, second.id, third.id])

        try repository!.reorderProjects([third.id, first.id, second.id])
        try repository!.setSelectedProjectID(first.id)
        repository = nil

        repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
        XCTAssertEqual(try repository!.listProjects().map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(try repository!.selectedProjectID(), first.id)

        // A cancelled confirmation never calls this method; data is unchanged.
        XCTAssertEqual(try repository!.listProjects().count, 3)
        try repository!.deleteProject(id: first.id)
        XCTAssertEqual(try repository!.listProjects().map(\.id), [third.id, second.id])
        XCTAssertTrue(fileManager.fileExists(atPath: directories[0].path), "deleting a YCode record must not delete the project directory")
        XCTAssertEqual(try repository!.selectedProjectID(), third.id)
    }

    func testSharedAndWorktreeSessionMetadataStayDistinct() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let directory = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("data/ycode.db")
        let repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
        let project = try repository.addProject(directory: directory)
        let db = try SQLiteConnection(path: databaseURL.path)
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("""
            INSERT INTO sessions VALUES (
                'shared', '普通会话', 'codex', ?, NULL, 1, 10, NULL,
                'native-id', '普通线程', NULL, NULL, NULL
            );
            """, bindings: [.text(project.id)])
        try db.execute("""
            INSERT INTO sessions VALUES (
                'isolated', '隔离会话', 'claude-code', ?, NULL, 1, 20, NULL,
                'claude-id', '隔离线程', '/tmp/wt', 'ycode/isolated', 'main'
            );
            """, bindings: [.text(project.id)])

        let sessions = try repository.listSessions(projectID: project.id)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first { $0.id == "shared" }?.recoveryAvailability, .available)
        let isolated = try XCTUnwrap(sessions.first { $0.id == "isolated" })
        XCTAssertEqual(isolated.recoveryAvailability, .unsupportedWorktree)
        XCTAssertEqual(isolated.worktreePath, "/tmp/wt")
        XCTAssertEqual(isolated.branch, "ycode/isolated")
        XCTAssertEqual(isolated.baseBranch, "main")
        XCTAssertEqual(isolated.agentSessionID, "claude-id")
    }

    func testInvalidDuplicateAndInvalidOrderAreRejected() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let repository = try ProjectWorkspaceRepository(databaseURL: root.appendingPathComponent("data/ycode.db"))
        let missing = root.appendingPathComponent("missing")
        XCTAssertThrowsError(try repository.addProject(directory: missing)) { error in
            XCTAssertEqual(error as? ProjectWorkspaceError, .invalidProjectDirectory(missing.path))
        }

        let directory = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = try repository.addProject(directory: directory)
        XCTAssertThrowsError(try repository.addProject(directory: directory)) { error in
            XCTAssertEqual(error as? ProjectWorkspaceError, .duplicateProject(directory.path))
        }
        XCTAssertThrowsError(try repository.reorderProjects([project.id, project.id])) { error in
            XCTAssertEqual(error as? ProjectWorkspaceError, .invalidOrder)
        }
    }

    func testMissingProjectPathRemainsVisible() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let directory = root.appendingPathComponent("gone", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try ProjectWorkspaceRepository(databaseURL: root.appendingPathComponent("data/ycode.db"))
        _ = try repository.addProject(directory: directory, name: "仍显示")
        try fileManager.removeItem(at: directory)

        let project = try XCTUnwrap(repository.listProjects().first)
        XCTAssertEqual(project.name, "仍显示")
        XCTAssertFalse(project.pathExists)
    }

    func testDataRootResolverPrefersArgumentThenNativeEnvironmentThenSafetyAlias() {
        let fallback = URL(fileURLWithPath: "/fallback", isDirectory: true)
        XCTAssertEqual(
            YCodeDataRootResolver.resolve(arguments: ["app", "--data-root", "/argument"], environment: ["YCODE_NATIVE_DATA_ROOT": "/environment"], fallback: fallback).path,
            "/argument"
        )
        XCTAssertEqual(
            YCodeDataRootResolver.resolve(arguments: ["app"], environment: ["YCODE_NATIVE_DATA_ROOT": "/environment"], fallback: fallback).path,
            "/environment"
        )
        XCTAssertEqual(
            YCodeDataRootResolver.resolve(
                arguments: ["app"],
                environment: ["YCODE_NATIVE_DATA_ROOT": "/native", "YCODE_DATA_ROOT": "/alias"],
                fallback: fallback
            ).path,
            "/native"
        )
        XCTAssertEqual(
            YCodeDataRootResolver.resolve(arguments: ["app"], environment: ["YCODE_DATA_ROOT": "/safe-alias"], fallback: fallback).path,
            "/safe-alias"
        )
        XCTAssertEqual(YCodeDataRootResolver.resolve(arguments: ["app"], environment: [:], fallback: fallback).path, "/fallback")
    }

    private func makeTemporaryRoot() -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent("ycode-m13-tests-\(UUID().uuidString)", isDirectory: true)
        try! fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
