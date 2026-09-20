import Foundation
import Testing
@testable import YCodeCore

@Suite("Checkpoint service", .serialized)
struct CheckpointServiceTests {
    @Test("initial and turn checkpoints snapshot normal project directory without worktrees")
    func initialAndTurnCheckpoints() throws {
        let fixture = try CheckpointFixture()
        defer { fixture.remove() }
        try fixture.file("tracked.txt", "base\n")
        try fixture.git("add", "tracked.txt")
        try fixture.git("commit", "-m", "base")

        let project = try fixture.project()
        let session = try fixture.repository.createSession(projectID: project.id, title: "Run", agentProfile: "codex")
        let service = YCodeCheckpointService(repository: fixture.checkpoints, keepLimit: 50)
        let initial = try service.createInitial(session: session, project: project)
        #expect(initial.sequence == 0)
        #expect(initial.kind == "initial")
        #expect(try fixture.git("show-ref", "--verify", initial.refName).contains(initial.commitSHA))

        try fixture.file("tracked.txt", "base\nround1\n")
        try fixture.file("new file.txt", "new\n")
        let event1 = YCodeAgentHookEvent(
            terminalID: session.id,
            source: "codex",
            eventKind: "turn_complete",
            bodyPreview: "round one"
        )
        let firstTurn = try service.createTurn(session: session, project: project, event: event1)
        #expect(firstTurn.sequence == 1)
        let diff1 = try service.diff(root: project.repositoryURL, from: initial, to: firstTurn)
        #expect(diff1.contains("+round1"))
        #expect(diff1.contains("new file.txt"))

        try fixture.file("tracked.txt", "base\nround1\nround2\n")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("new file.txt"))
        let secondTurn = try service.createTurn(
            session: session,
            project: project,
            event: YCodeAgentHookEvent(terminalID: session.id, source: "codex", eventKind: "turn_complete", bodyPreview: "round two")
        )
        #expect(secondTurn.sequence == 2)
        let diff2 = try service.diff(root: project.repositoryURL, from: firstTurn, to: secondTurn)
        #expect(diff2.contains("+round2"))
        #expect(diff2.contains("deleted file mode") || diff2.contains("--- a/new file.txt"))
        #expect(try fixture.git("worktree", "list").split(separator: "\n").count == 1)
    }

    @Test("duplicate turn events are ignored and empty changes still create ordered snapshots")
    func duplicateAndEmptyEvents() throws {
        let fixture = try CheckpointFixture()
        defer { fixture.remove() }
        try fixture.file("tracked.txt", "base\n")
        try fixture.git("add", ".")
        try fixture.git("commit", "-m", "base")
        let project = try fixture.project()
        let session = try fixture.repository.createSession(projectID: project.id, title: "Run", agentProfile: "codex")
        let service = YCodeCheckpointService(repository: fixture.checkpoints, keepLimit: 50)
        _ = try service.createInitial(session: session, project: project)

        let event = YCodeAgentHookEvent(terminalID: session.id, source: "codex", eventKind: "turn_complete", bodyPreview: "same")
        let first = try service.createTurn(session: session, project: project, event: event)
        #expect(first.sequence == 1)
        #expect(throws: YCodeCheckpointError.self) {
            try service.createTurn(session: session, project: project, event: event)
        }
        let rows = try service.list(sessionID: session.id)
        #expect(rows.map(\.sequence) == [0, 1])
    }

    @Test("keep limit prunes old database rows and refs while preserving at least one checkpoint")
    func keepLimitPrunesRowsAndRefs() throws {
        let fixture = try CheckpointFixture()
        defer { fixture.remove() }
        try fixture.file("tracked.txt", "base\n")
        try fixture.git("add", ".")
        try fixture.git("commit", "-m", "base")
        let project = try fixture.project()
        let session = try fixture.repository.createSession(projectID: project.id, title: "Run", agentProfile: "codex")
        let service = YCodeCheckpointService(repository: fixture.checkpoints, keepLimit: 2)
        let initial = try service.createInitial(session: session, project: project)
        let prunedRef = initial.refName
        for index in 1...3 {
            try fixture.file("tracked.txt", "base\n\(index)\n")
            _ = try service.createTurn(
                session: session,
                project: project,
                event: YCodeAgentHookEvent(terminalID: session.id, source: "codex", eventKind: "turn_complete", bodyPreview: "round \(index)")
            )
        }
        let rows = try service.list(sessionID: session.id)
        #expect(rows.map(\.sequence) == [2, 3])
        #expect(throws: Error.self) {
            _ = try fixture.git("show-ref", "--verify", prunedRef)
        }
    }

    @Test("snapshot commit does not change the real index or staged state")
    func snapshotDoesNotMutateIndex() throws {
        let fixture = try CheckpointFixture()
        defer { fixture.remove() }
        try fixture.file("staged.txt", "base\n")
        try fixture.file("unstaged.txt", "base\n")
        try fixture.git("add", ".")
        try fixture.git("commit", "-m", "base")
        try fixture.file("staged.txt", "base\nstaged\n")
        try fixture.file("unstaged.txt", "base\nunstaged\n")
        try fixture.git("add", "staged.txt")
        let before = try fixture.git("status", "--porcelain=v1")

        let project = try fixture.project()
        let session = try fixture.repository.createSession(projectID: project.id, title: "Run", agentProfile: "codex")
        let service = YCodeCheckpointService(repository: fixture.checkpoints, keepLimit: 50)
        _ = try service.createInitial(session: session, project: project)
        let after = try fixture.git("status", "--porcelain=v1")
        #expect(after == before)
    }
}

private struct CheckpointFixture {
    let container: URL
    let root: URL
    let databaseURL: URL
    let repository: ProjectWorkspaceRepository
    let checkpoints: YCodeCheckpointRepository

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-checkpoints-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("repo", isDirectory: true)
        databaseURL = container.appendingPathComponent("data/ycode.db")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.git(root, "init", "-b", "main")
        try Self.git(root, "config", "user.name", "YCode Test")
        try Self.git(root, "config", "user.email", "ycode@example.test")
        repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
        checkpoints = try YCodeCheckpointRepository(databaseURL: databaseURL)
    }

    func project() throws -> ProjectRecord {
        try repository.addProject(directory: root, name: "Repo")
    }

    func file(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        try Self.git(root, args)
    }

    @discardableResult
    static func git(_ cwd: URL, _ args: String...) throws -> String {
        try git(cwd, args)
    }

    @discardableResult
    static func git(_ cwd: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }
        return stdout
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
