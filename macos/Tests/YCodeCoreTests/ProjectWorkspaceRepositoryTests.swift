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

    func testArchiveRoundTripHidesAndRestoresTheSessionWithoutTouchingOthers() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let directory = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("data/ycode.db")
        let repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
        let project = try repository.addProject(directory: directory)
        let db = try SQLiteConnection(path: databaseURL.path)
        for (id, title) in [("keep", "留着的"), ("gone", "归档的")] {
            try db.execute("""
                INSERT INTO sessions VALUES (
                    ?, ?, 'codex', ?, NULL, 1, 10, NULL,
                    'native-id', '线程', NULL, NULL, NULL
                );
                """, bindings: [.text(id), .text(title), .text(project.id)])
        }

        try repository.archiveSession(id: "gone")
        XCTAssertEqual(try repository.listSessions(projectID: project.id).map(\.id), ["keep"])
        XCTAssertEqual(try repository.listSessions(projectID: project.id, includeArchived: true).count, 2)
        XCTAssertNotNil(try repository.session(id: "gone").archivedAtMilliseconds)
        // 重复归档是幂等的，不该把时间戳改掉或者报错。
        let firstStamp = try repository.session(id: "gone").archivedAtMilliseconds
        try repository.archiveSession(id: "gone")
        XCTAssertEqual(try repository.session(id: "gone").archivedAtMilliseconds, firstStamp)

        try repository.unarchiveSession(id: "gone")
        XCTAssertNil(try repository.session(id: "gone").archivedAtMilliseconds)
        XCTAssertEqual(Set(try repository.listSessions(projectID: project.id).map(\.id)), ["keep", "gone"])
        XCTAssertEqual(try repository.listProjects().first?.liveSessionCount, 2)
        // 没归档过的那条再取消归档也是空操作。
        XCTAssertNoThrow(try repository.unarchiveSession(id: "keep"))
        XCTAssertNil(try repository.session(id: "keep").archivedAtMilliseconds)
    }

    func testIdleSessionsArchiveAfterFourteenDaysExceptRunningOnesAndKeepTheirLastActivity() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let directory = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("data/ycode.db")
        let repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
        let project = try repository.addProject(directory: directory)
        let db = try SQLiteConnection(path: databaseURL.path)

        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let day: Int64 = 24 * 60 * 60 * 1_000
        let stale = now - 15 * day
        // "fresh" 刚用过，"stale" 和 "running" 都超过 14 天没动静。
        for (id, updated) in [("fresh", now - 3 * day), ("stale", stale), ("running", now - 20 * day)] {
            try db.execute("""
                INSERT INTO sessions VALUES (
                    ?, ?, 'codex', ?, NULL, 1, ?, NULL,
                    'native-id', '线程', NULL, NULL, NULL
                );
                """, bindings: [.text(id), .text(id), .text(project.id), .integer(updated)])
        }

        let cutoff = now - 14 * day
        let archived = try repository.archiveSessionsIdle(before: cutoff, keeping: ["running"])

        XCTAssertEqual(archived.map(\.id), ["stale"])
        XCTAssertEqual(Set(try repository.listSessions(projectID: project.id).map(\.id)), ["fresh", "running"])
        XCTAssertNotNil(try repository.session(id: "stale").archivedAtMilliseconds)
        // 自动归档不能把「最后一次有动静」改成现在，否则归档区按时间排序就全乱了。
        XCTAssertEqual(try repository.session(id: "stale").updatedAtMilliseconds, stale)
        // 再扫一遍是空操作。
        XCTAssertTrue(try repository.archiveSessionsIdle(before: cutoff, keeping: ["running"]).isEmpty)
    }

    func testDiscoveredSessionsFollowTheirJsonlUnlessTheUserRenamedThem() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let directory = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try ProjectWorkspaceRepository(databaseURL: root.appendingPathComponent("data/ycode.db"))
        let project = try repository.addProject(directory: directory)

        let day: Int64 = 24 * 60 * 60 * 1_000
        let firstScan: Int64 = 1_000 * day
        func draft(_ agentSessionID: String, _ title: String, _ updated: Int64, archived: Int64? = nil) -> DiscoveredSessionDraft {
            DiscoveredSessionDraft(
                projectID: project.id,
                title: title,
                agentProfile: "claude-code",
                agentSessionID: agentSessionID,
                jsonlPath: "/tmp/\(agentSessionID).jsonl",
                updatedAtMilliseconds: updated,
                archivedAtMilliseconds: archived
            )
        }

        let imported = try repository.syncDiscoveredSessions([
            draft("followed", "初次标题", firstScan),
            draft("renamed", "也是初次标题", firstScan),
            draft("revived", "老会话", firstScan - 30 * day, archived: firstScan)
        ])
        XCTAssertEqual(imported.count, 3)
        let followedID = try XCTUnwrap(imported.first { $0.agentSessionID == "followed" }).id
        let renamedID = try XCTUnwrap(imported.first { $0.agentSessionID == "renamed" }).id
        let revivedID = try XCTUnwrap(imported.first { $0.agentSessionID == "revived" }).id
        XCTAssertNotNil(try repository.session(id: revivedID).archivedAtMilliseconds)

        // 用户给其中一条起了自己的名字。
        try repository.renameSession(id: renamedID, title: "我自己起的名字")
        let renamedStamp = try repository.session(id: renamedID).updatedAtMilliseconds

        // 第二轮扫描：jsonl 改了标题，并且那条老会话又被用了。
        let touched = try repository.syncDiscoveredSessions([
            draft("followed", "CLI 改过的标题", firstScan + day),
            draft("renamed", "CLI 改过的标题", firstScan + day),
            draft("revived", "老会话", firstScan + day)
        ])

        // 改过名的那条这一轮压根没被动：renameSession 已经把 updated_at 推到了现在，
        // 比 jsonl 的时间还新，标题又是用户自己的——两样都没得可改。
        XCTAssertEqual(Set(touched.map(\.id)), [followedID, revivedID])
        XCTAssertEqual(try repository.session(id: followedID).title, "CLI 改过的标题")
        XCTAssertEqual(try repository.session(id: renamedID).title, "我自己起的名字")
        XCTAssertEqual(try repository.session(id: renamedID).updatedAtMilliseconds, renamedStamp)
        // jsonl 又有动静了，归档的那条要回到活跃列表。
        XCTAssertNil(try repository.session(id: revivedID).archivedAtMilliseconds)

        // 同一批再对一次就没有变化了。
        XCTAssertTrue(try repository.syncDiscoveredSessions([
            draft("followed", "CLI 改过的标题", firstScan + day)
        ]).isEmpty)
        XCTAssertEqual(try repository.listSessions(projectID: project.id, includeArchived: true).count, 3)

        // 删除会话时要能问出 jsonl 在哪，否则文件删不掉、下次扫描又把它导回来。
        XCTAssertEqual(try repository.discoveredJsonlPath(sessionID: followedID), "/tmp/followed.jsonl")
        try repository.deleteSession(id: followedID)
        XCTAssertEqual(try repository.listSessions(projectID: project.id, includeArchived: true).count, 2)
        XCTAssertNil(try repository.discoveredJsonlPath(sessionID: followedID))
        XCTAssertThrowsError(try repository.deleteSession(id: followedID))
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
