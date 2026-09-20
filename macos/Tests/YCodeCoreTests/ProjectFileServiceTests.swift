import Foundation
import Testing
@testable import YCodeCore

@Suite("Project file service", .serialized)
struct ProjectFileServiceTests {
    @Test("listing preserves hidden and ignored files while pruning heavy directories")
    func listing() throws {
        let fixture = try ProjectFileFixture()
        defer { fixture.remove() }
        try fixture.directory("中文 目录/嵌套")
        try fixture.file("中文 目录/嵌套/space file.swift", contents: "print(1)")
        try fixture.file(".env", contents: "TOKEN=test")
        try fixture.file("ignored.txt", contents: "visible")
        try fixture.file(".git/config", contents: "hidden")
        try fixture.file("node_modules/pkg/index.js", contents: "heavy")
        try fixture.file("Sources/target/debug.log", contents: "heavy")

        let entries = try YCodeProjectFileService().listFiles(root: fixture.root)
        let paths = entries.map(\.path)
        #expect(paths == paths.sorted())
        #expect(paths.contains(".env"))
        #expect(paths.contains("ignored.txt"))
        #expect(paths.contains("中文 目录"))
        #expect(paths.contains("中文 目录/嵌套/space file.swift"))
        #expect(!paths.contains(where: { $0 == ".git" || $0.hasPrefix(".git/") }))
        #expect(!paths.contains(where: { $0 == "node_modules" || $0.hasPrefix("node_modules/") }))
        #expect(!paths.contains(where: { $0 == "Sources/target" || $0.hasPrefix("Sources/target/") }))
    }

    @Test("create rename and delete change only the requested project paths")
    func mutations() throws {
        let fixture = try ProjectFileFixture()
        defer { fixture.remove() }
        let service = YCodeProjectFileService()

        try service.createPath(root: fixture.root, relativePath: "新 目录", isDirectory: true)
        try service.createPath(root: fixture.root, relativePath: "新 目录/草稿.txt", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: fixture.url("新 目录/草稿.txt").path))
        #expect(throws: YCodeProjectFileError.self) {
            try service.createPath(root: fixture.root, relativePath: "新 目录/草稿.txt", isDirectory: false)
        }

        try service.renamePath(root: fixture.root, from: "新 目录/草稿.txt", to: "新 目录/完成 文档.txt")
        #expect(!FileManager.default.fileExists(atPath: fixture.url("新 目录/草稿.txt").path))
        #expect(FileManager.default.fileExists(atPath: fixture.url("新 目录/完成 文档.txt").path))
        try fixture.file("占用.txt", contents: "keep")
        #expect(throws: YCodeProjectFileError.self) {
            try service.renamePath(root: fixture.root, from: "新 目录/完成 文档.txt", to: "占用.txt")
        }
        #expect(try String(contentsOf: fixture.url("占用.txt"), encoding: .utf8) == "keep")

        try service.deletePath(root: fixture.root, relativePath: "新 目录")
        #expect(!FileManager.default.fileExists(atPath: fixture.url("新 目录").path))
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test("absolute traversal and symlink escapes are rejected without touching outside data")
    func pathSafety() throws {
        let fixture = try ProjectFileFixture()
        defer { fixture.remove() }
        let outside = fixture.container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outsideFile)
        let escape = fixture.root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        let service = YCodeProjectFileService()

        for path in ["../outside/keep.txt", "/tmp/absolute", "nested/../../outside"] {
            #expect(throws: YCodeProjectFileError.self) {
                try service.createPath(root: fixture.root, relativePath: path, isDirectory: false)
            }
        }
        #expect(throws: YCodeProjectFileError.self) {
            try service.createPath(root: fixture.root, relativePath: "escape/new.txt", isDirectory: false)
        }
        #expect(throws: YCodeProjectFileError.self) {
            _ = try service.existingFileURL(root: fixture.root, relativePath: "escape/keep.txt")
        }

        try service.deletePath(root: fixture.root, relativePath: "escape")
        #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: escape.path))
    }

    @Test("two roots stay independent and file resolution returns the exact target")
    func independentRoots() throws {
        let fixture = try ProjectFileFixture()
        defer { fixture.remove() }
        let second = fixture.container.appendingPathComponent("second project", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try fixture.file("same.txt", contents: "first")
        try Data("second".utf8).write(to: second.appendingPathComponent("same.txt"))
        let service = YCodeProjectFileService()

        try service.renamePath(root: fixture.root, from: "same.txt", to: "first-only.txt")
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("same.txt").path))
        #expect(try service.existingFileURL(root: second, relativePath: "same.txt")
            == second.appendingPathComponent("same.txt").standardizedFileURL)
    }
}

private struct ProjectFileFixture {
    let container: URL
    let root: URL

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-project-files-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("项目 root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func directory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(at: url(relativePath), withIntermediateDirectories: true)
    }

    func file(_ relativePath: String, contents: String) throws {
        let target = url(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: target)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
