import Foundation
import Testing
@testable import YCodeCore

@Suite("Todo repository", .serialized)
struct TodoRepositoryTests {
    @Test("CRUD preserves status timestamps and manual order")
    func lifecycle() throws {
        let fixture = try TodoFixture()
        defer { fixture.remove() }
        let repository = try YCodeTodoRepository(databaseURL: fixture.databaseURL)

        let first = try repository.create(projectID: fixture.project.id, title: "  first  ")
        let second = try repository.create(projectID: fixture.project.id, title: "second")
        let third = try repository.create(projectID: fixture.project.id, title: "third")
        #expect(first.title == "first")
        #expect(repositoryList(repository, fixture.project.id).map(\.sortOrder) == [0, 1, 2])

        let doing = try repository.update(id: first.id, status: .doing)
        let started = try #require(doing.startedAtMilliseconds)
        #expect(doing.doneAtMilliseconds == nil)
        let done = try repository.update(id: first.id, title: "renamed", status: .done)
        #expect(done.startedAtMilliseconds == started)
        let doneAt = try #require(done.doneAtMilliseconds)
        let same = try repository.update(id: first.id, status: .done)
        #expect(same.doneAtMilliseconds == doneAt)
        let reopened = try repository.update(id: first.id, status: .todo)
        #expect(reopened.startedAtMilliseconds == started)
        #expect(reopened.doneAtMilliseconds == doneAt)

        try repository.reorder(projectID: fixture.project.id, orderedIDs: [third.id, first.id, second.id])
        #expect(repositoryList(repository, fixture.project.id).map(\.id) == [third.id, first.id, second.id])
        try repository.delete(id: second.id)
        #expect(repositoryList(repository, fixture.project.id).map(\.id) == [third.id, first.id])
    }

    @Test("invalid project status title and order do not change data")
    func validation() throws {
        let fixture = try TodoFixture()
        defer { fixture.remove() }
        let repository = try YCodeTodoRepository(databaseURL: fixture.databaseURL)
        let item = try repository.create(projectID: fixture.project.id, title: "valid")

        #expect(throws: YCodeTodoError.projectNotFound("missing")) {
            try repository.create(projectID: "missing", title: "x")
        }
        #expect(throws: YCodeTodoError.emptyTitle) {
            try repository.update(id: item.id, title: "  ")
        }
        #expect(throws: YCodeTodoError.invalidStatus("blocked")) {
            try repository.update(id: item.id, statusRaw: "blocked")
        }
        #expect(throws: YCodeTodoError.invalidOrder) {
            try repository.reorder(projectID: fixture.project.id, orderedIDs: [item.id, item.id])
        }
        let unchanged = try #require(repository.list(projectID: fixture.project.id).first)
        #expect(unchanged.title == "valid")
        #expect(unchanged.status == .todo)
        #expect(unchanged.sortOrder == 0)
    }

    @Test("terminal ID wins and cwd remains a safe fallback")
    func projectResolution() throws {
        let fixture = try TodoFixture()
        defer { fixture.remove() }
        let workspace = try ProjectWorkspaceRepository(databaseURL: fixture.databaseURL)
        let session = try workspace.createSession(
            projectID: fixture.project.id,
            title: "agent",
            agentProfile: "codex"
        )
        let repository = try YCodeTodoRepository(databaseURL: fixture.databaseURL)
        #expect(try repository.resolveProjectID(terminalID: session.id, cwd: nil) == fixture.project.id)
        #expect(try repository.resolveProjectID(terminalID: "stale", cwd: fixture.repositoryURL) == fixture.project.id)
        #expect(throws: YCodeTodoError.projectCannotBeResolved) {
            try repository.resolveProjectID(terminalID: "stale", cwd: fixture.root)
        }
    }

    @Test("concurrent creates serialize without duplicate ordering")
    func concurrentCreates() throws {
        let fixture = try TodoFixture()
        defer { fixture.remove() }
        let repositories = try (0..<12).map { _ in try YCodeTodoRepository(databaseURL: fixture.databaseURL) }
        let failures = FailureBox()
        DispatchQueue.concurrentPerform(iterations: repositories.count) { index in
            do { _ = try repositories[index].create(projectID: fixture.project.id, title: "item-\(index)") }
            catch { failures.append(error) }
        }
        #expect(failures.values.isEmpty)
        let items = try repositories[0].list(projectID: fixture.project.id)
        #expect(items.count == 12)
        #expect(Set(items.map(\.id)).count == 12)
        #expect(items.map(\.sortOrder) == Array(0..<12).map(Int64.init))
    }

    private func repositoryList(_ repository: YCodeTodoRepository, _ projectID: String) -> [YCodeTodo] {
        (try? repository.list(projectID: projectID)) ?? []
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []
    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}

private struct TodoFixture {
    let root: URL
    let databaseURL: URL
    let repositoryURL: URL
    let project: ProjectRecord

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-todo-\(UUID().uuidString)")
        databaseURL = root.appendingPathComponent("data/ycode.db")
        repositoryURL = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        project = try ProjectWorkspaceRepository(databaseURL: databaseURL).addProject(directory: repositoryURL)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
