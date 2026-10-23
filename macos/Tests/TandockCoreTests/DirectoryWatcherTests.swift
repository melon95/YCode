import Foundation
import Testing
@testable import TandockCore

@Suite("Directory watcher", .serialized)
struct DirectoryWatcherTests {
    @Test("reports the touched path relative to the root", .timeLimit(.minutes(1)))
    func reportsChanges() async throws {
        let fixture = try WatcherFixture()
        defer { fixture.remove() }
        try fixture.directory("嵌套 目录")

        let collector = PathCollector()
        let watcher = TandockDirectoryWatcher(root: fixture.root, latency: 0.05) { paths in
            collector.append(paths)
        }
        watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(300))
        try fixture.file("嵌套 目录/新文件.swift", contents: "print(1)")

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !collector.paths.contains("嵌套 目录/新文件.swift") {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(collector.paths.contains("嵌套 目录/新文件.swift"))
        #expect(!collector.paths.contains(where: { $0.hasPrefix("/") }))
    }

    @Test("goes quiet after stop", .timeLimit(.minutes(1)))
    func stopsReporting() async throws {
        let fixture = try WatcherFixture()
        defer { fixture.remove() }

        let collector = PathCollector()
        let watcher = TandockDirectoryWatcher(root: fixture.root, latency: 0.05) { paths in
            collector.append(paths)
        }
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        watcher.stop()

        collector.reset()
        try fixture.file("停了之后.txt", contents: "quiet")
        try await Task.sleep(for: .milliseconds(500))
        #expect(collector.paths.isEmpty)
    }
}

private struct WatcherFixture {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tandock-watcher-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func file(_ relativePath: String, contents: String) throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ values: [String]) {
        lock.lock()
        storage.append(contentsOf: values)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}
