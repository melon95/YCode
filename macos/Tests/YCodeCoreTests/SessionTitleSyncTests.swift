import Foundation
import XCTest
@testable import YCodeCore

final class SessionTitleSyncTests: XCTestCase {
    func testMetadataAppendPartialRecordReplacementAndClear() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.jsonl")
        let reader = YCodeSessionTitleReader()
        try "{\"type\": \"custom-title\", \"customTitle\":\"First\"}\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(reader.title(url: file, agent: "claude"), "First")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"custom-title\",\"customTitle\":\"Second\"}".utf8))
        XCTAssertEqual(reader.title(url: file, agent: "claude"), "First", "partial trailing records must not replace the confirmed title")
        try handle.write(contentsOf: Data([10]))
        try handle.close()
        XCTAssertEqual(reader.title(url: file, agent: "claude"), "Second")
        try "{\"type\":\"custom-title\",\"customTitle\":\"Replacement\"}\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(reader.title(url: file, agent: "claude"), "Replacement")
        try "{\"type\":\"session_info\",\"name\":\"Old\"}\n{\"type\":\"session_info\",\"name\":\"\"}\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(reader.title(url: file, agent: "pi"))
    }

    func testClaudeRenameAppendsAndHistoryReadsTitleBeyondHead() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = home.appendingPathComponent("repo")
        let project = home.appendingPathComponent(".claude/projects/" + YCodeHistoryIndex.encodeClaudeWorkspace(workspace))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString, file = project.appendingPathComponent(id + ".jsonl")
        let original = String(repeating: "{\"type\":\"assistant\",\"message\":{}}\n", count: 100)
        try original.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(YCodeAgentSessionTitleWriter.write(title: "中文 renamed", introspect: "claude", jsonlPath: file.path, sessionID: id), .written)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix(original))
        let index = YCodeHistoryIndex()
        XCTAssertEqual(index.scanWorkspace(homeDirectory: home, workspace: workspace).first?.title, "中文 renamed")
    }

    func testPendingRenameSurvivesStaleScanThenAllowsCLIRenameAndBindsEmptySession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectWorkspaceRepository(databaseURL: root.appendingPathComponent("db.sqlite"))
        let project = try repo.addProject(directory: root)
        let row = try repo.createSession(projectID: project.id, title: "", agentProfile: "pi", agentSessionID: "native")
        func draft(_ title: String, profile: String = "pi") -> DiscoveredSessionDraft {
            .init(projectID: project.id, title: title, agentProfile: profile, agentSessionID: "native", jsonlPath: "/tmp/native.jsonl", updatedAtMilliseconds: 1, archivedAtMilliseconds: nil)
        }
        _ = try repo.syncDiscoveredSessions([draft("First")])
        XCTAssertEqual(try repo.session(id: row.id).title, "First")
        XCTAssertEqual(try repo.discoveredJsonlPath(sessionID: row.id), "/tmp/native.jsonl")
        _ = try repo.renameSession(id: row.id, title: "Local")
        _ = try repo.syncDiscoveredSessions([draft("Stale")])
        XCTAssertEqual(try repo.session(id: row.id).title, "Local")
        try repo.finishSessionTitleSync(id: row.id, requested: "Local", confirmed: nil, error: "offline")
        XCTAssertEqual(try repo.sessionTitleSyncError(id: row.id), "offline")
        _ = try repo.renameSession(id: row.id, title: "Newer")
        try repo.finishSessionTitleSync(id: row.id, requested: "Local", confirmed: "Local", error: nil)
        XCTAssertEqual(try repo.pendingSessionTitle(id: row.id), "Newer")
        try repo.finishSessionTitleSync(id: row.id, requested: "Newer", confirmed: "Newer", error: nil)
        _ = try repo.syncDiscoveredSessions([draft("CLI latest")])
        XCTAssertEqual(try repo.session(id: row.id).title, "CLI latest")
        XCTAssertNil(try repo.pendingSessionTitle(id: row.id))
        _ = try repo.syncDiscoveredSessions([draft("Other CLI", profile: "claude-code")])
        XCTAssertEqual(try repo.listSessions(projectID: project.id).count, 2, "IDs from different CLIs must not collide")
    }

    func testHookCarriesExactNativeSessionIdentity() throws {
        let id = UUID().uuidString.lowercased()
        let extra = String(decoding: try JSONSerialization.data(withJSONObject: ["thread-id": id]), as: UTF8.self)
        let event = try JSONSerialization.data(withJSONObject: ["terminal_id": "terminal", "source": "codex", "event": "stop", "extra": [extra]])
        XCTAssertEqual(YCodeAgentHookParser.parse(line: event)?.agentSessionID, id)
        let invalid = try JSONSerialization.data(withJSONObject: ["terminal_id": "terminal", "source": "codex", "extra": ["{\"thread-id\":\"guessed-name\"}"]])
        XCTAssertNil(YCodeAgentHookParser.parse(line: invalid)?.agentSessionID)
    }

    func testInstalledCodexRenameWithIsolatedHome() throws {
        guard let binary = ProcessInfo.processInfo.environment["YCODE_TEST_CODEX"] else { throw XCTSkip("Set YCODE_TEST_CODEX to run real CLI metadata verification") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-title-codex-" + UUID().uuidString)
        let dir = home.appendingPathComponent("sessions/2026/09/27")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased()
        let file = dir.appendingPathComponent("rollout-2026-09-27T00-00-00-" + id + ".jsonl")
        let meta: [String: Any] = ["timestamp": "2026-09-27T00:00:00Z", "type": "session_meta", "payload": ["id": id, "timestamp": "2026-09-27T00:00:00Z", "cwd": "/tmp", "originator": "codex_cli_rs", "cli_version": "0.154.0", "source": "cli", "model_provider": "openai"]]
        var original = try JSONSerialization.data(withJSONObject: meta); original.append(10)
        try original.write(to: file)
        var env = ProcessInfo.processInfo.environment; env["CODEX_HOME"] = home.path
        XCTAssertEqual(try YCodeCodexTitleClient.rename(command: binary, sessionID: id, name: "改名验证", environment: env), "改名验证")
        XCTAssertEqual(try Data(contentsOf: file), original, "Metadata renaming must leave the rollout untouched")
        XCTAssertEqual(YCodeSessionTitleReader().title(url: home.appendingPathComponent("session_index.jsonl"), agent: "codex", sessionID: id), "改名验证")
    }
}
