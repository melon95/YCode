import Foundation
import Testing
@testable import YCodeCore

@Suite("Git service", .serialized)
struct GitServiceTests {
    @Test("status diff stage unstage discard and commit match independent git queries")
    func workingTreeOperations() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.file("tracked.txt", "one\n")
        try fixture.git("add", "tracked.txt")
        try fixture.git("commit", "-m", "initial")

        try fixture.file("tracked.txt", "one\ntwo\n")
        try fixture.file("new.txt", "new\n")
        let service = YCodeGitService()
        let status = try service.status(root: fixture.root)
        #expect(status.changes.map(\.path) == ["new.txt", "tracked.txt"])
        #expect(status.changes.first(where: { $0.path == "new.txt" })?.kind == .untracked)

        let diff = try service.diff(root: fixture.root, path: "tracked.txt")
        #expect(diff.contains("+two"))
        try service.stage(root: fixture.root, path: "tracked.txt")
        #expect(try fixture.git("diff", "--cached", "--name-only").contains("tracked.txt"))
        try service.unstage(root: fixture.root, path: "tracked.txt")
        #expect(try fixture.git("diff", "--cached", "--name-only").isEmpty)

        try service.stage(root: fixture.root, path: "tracked.txt")
        _ = try service.commit(root: fixture.root, message: "modify tracked")
        #expect(try fixture.git("status", "--porcelain").contains("?? new.txt"))
        try service.discard(root: fixture.root, path: "new.txt")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("new.txt").path))
        #expect(try fixture.git("status", "--porcelain").isEmpty)
    }

    @Test("apply hunk affects only the supplied patch")
    func applyHunk() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.file("notes.txt", "a\nb\nc\n")
        try fixture.git("add", "notes.txt")
        try fixture.git("commit", "-m", "initial")
        try fixture.file("notes.txt", "a\nb changed\nc\n")

        let patch = try fixture.git("diff", "--", "notes.txt")
        try fixture.file("notes.txt", "a\nb\nc\n")
        try YCodeGitService().applyHunk(root: fixture.root, patch: patch)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("notes.txt"), encoding: .utf8) == "a\nb changed\nc\n")
    }

    @Test("branch and remote operations work against a local bare remote")
    func branchAndRemoteOperations() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.file("readme.md", "base\n")
        try fixture.git("add", "readme.md")
        try fixture.git("commit", "-m", "initial")

        let remote = fixture.container.appendingPathComponent("remote.git", isDirectory: true)
        try fixture.gitGlobal(remote.deletingLastPathComponent(), "init", "--bare", remote.path)
        try fixture.git("remote", "add", "origin", remote.path)
        try YCodeGitService().push(root: fixture.root)
        try fixture.git("checkout", "-b", "feature")
        try fixture.file("readme.md", "base\nfeature\n")
        try fixture.git("commit", "-am", "feature")
        let service = YCodeGitService()
        let branches = try service.branches(root: fixture.root)
        #expect(branches.contains(where: { $0.name == "feature" && $0.current }))
        try service.checkout(root: fixture.root, branch: "main")
        #expect(try fixture.git("branch", "--show-current").trimmingCharacters(in: .whitespacesAndNewlines) == "main")
        try service.fetch(root: fixture.root)
        try service.push(root: fixture.root)
    }

    @Test("renames and binary files are classified without losing paths")
    func renameAndBinaryStatus() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.file("old.txt", "old\n")
        try Data([0, 1, 2, 3]).write(to: fixture.root.appendingPathComponent("image.bin"))
        try fixture.git("add", ".")
        try fixture.git("commit", "-m", "initial")
        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("old.txt"), to: fixture.root.appendingPathComponent("new.txt"))
        try Data([0, 1, 9, 3]).write(to: fixture.root.appendingPathComponent("image.bin"))
        try fixture.git("add", "-A")

        let status = try YCodeGitService().status(root: fixture.root)
        let hasRename = status.changes.contains { change in
            change.path == "new.txt" && change.originalPath == "old.txt" && change.kind == .renamed
        }
        let hasBinary = status.changes.contains { change in
            change.path == "image.bin" && change.kind == .modified
        }
        #expect(hasRename)
        #expect(hasBinary)
    }
}

private struct GitFixture {
    let container: URL
    let root: URL

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-git-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try gitGlobal(root, "init", "-b", "main")
        try git("config", "user.name", "YCode Test")
        try git("config", "user.email", "ycode@example.test")
    }

    func file(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        try gitGlobal(root, args)
    }

    @discardableResult
    func gitGlobal(_ cwd: URL, _ args: String...) throws -> String {
        try gitGlobal(cwd, args)
    }

    @discardableResult
    func gitGlobal(_ cwd: URL, _ args: [String]) throws -> String {
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
