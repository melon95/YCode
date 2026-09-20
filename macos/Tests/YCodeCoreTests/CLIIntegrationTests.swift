import Foundation
import Testing
@testable import YCodeCore

@Suite("CLI and deep links", .serialized)
struct CLIIntegrationTests {
    @Test("arguments preserve Chinese and spaced paths and files use the git root")
    func argumentResolution() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let project = fixture.root.appendingPathComponent("中文 project", isDirectory: true)
        let nested = project.appendingPathComponent("Sources/子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("main file.swift")
        try Data().write(to: file)

        #expect(try YCodeCLIArguments.parse([]) == .open(nil))
        #expect(try YCodeCLIArguments.parse(["--", "-folder"]) == .open("-folder"))
        #expect(throws: YCodeCLIError.self) { try YCodeCLIArguments.parse(["--bad"]) }
        #expect(throws: YCodeCLIError.self) { try YCodeCLIArguments.parse(["a", "b"]) }

        let request = try YCodeCLIArguments.request(
            rawPath: "Sources/子目录/main file.swift",
            currentDirectory: project
        )
        #expect(request.path == project.path)
        #expect(request.file == file.path)
        #expect(throws: YCodeCLIError.self) {
            try YCodeCLIArguments.request(rawPath: "missing", currentDirectory: project)
        }
    }

    @Test("project resolution reuses the deepest registered ancestor and validates files")
    func projectResolution() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let parent = fixture.root.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        let nested = child.appendingPathComponent("nested", isDirectory: true)
        let second = fixture.root.appendingPathComponent("second", isDirectory: true)
        for directory in [nested, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let repository = try ProjectWorkspaceRepository(databaseURL: fixture.databaseURL)
        _ = try repository.addProject(directory: parent)
        let childProject = try repository.addProject(directory: child)
        let service = YCodeProjectOpenService(databaseURL: fixture.databaseURL)

        let resolved = try service.resolve(YCodeCLIOpenRequest(path: nested.path))
        #expect(resolved.project.id == childProject.id)
        let added = try service.resolve(YCodeCLIOpenRequest(path: second.path))
        #expect(added.project.repositoryURL.path == second.path)
        #expect(try repository.listProjects().count == 3)

        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data().write(to: outside)
        #expect(throws: YCodeCLIError.self) {
            try service.resolve(YCodeCLIOpenRequest(path: child.path, file: outside.path))
        }
    }

    @Test("deep links decode paths and activation links need no project")
    func deepLinks() throws {
        #expect(try YCodeDeepLinkParser.request(from: #require(URL(string: "ycode://activate"))) == nil)
        let url = try #require(URL(string: "ycode://open?path=%2Ftmp%2F%E4%B8%AD%E6%96%87%20project&file=%2Ftmp%2F%E4%B8%AD%E6%96%87%20project%2Fa.swift"))
        let parsed = try YCodeDeepLinkParser.request(from: url)
        let request = try #require(parsed)
        #expect(request.path == "/tmp/中文 project")
        #expect(request.file == "/tmp/中文 project/a.swift")
        #expect(throws: YCodeCLIError.self) {
            try YCodeDeepLinkParser.request(from: #require(URL(string: "https://example.com")))
        }
    }

    @Test("real listener and bundled Swift CLI exchange one validated request")
    func realProcessRoundTrip() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let project = fixture.root.appendingPathComponent("CLI 中文 project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let service = YCodeProjectOpenService(databaseURL: fixture.databaseURL)
        let listener = YCodeCLIListener(socketURL: fixture.socketURL) { try service.resolve($0) }
        defer { listener.stop() }
        try listener.start()

        let result = try runCLI(
            executable: try cliExecutable(),
            arguments: [project.path],
            environment: ["YCODE_CLI_SOCK": fixture.socketURL.path]
        )
        #expect(result.status == 0)
        #expect(result.error.isEmpty)
        let projects = try ProjectWorkspaceRepository(databaseURL: fixture.databaseURL).listProjects()
        #expect(projects.map(\.repositoryURL.path) == [project.path])

        let invalid = try runCLI(
            executable: try cliExecutable(),
            arguments: [fixture.root.appendingPathComponent("missing").path],
            environment: ["YCODE_CLI_SOCK": fixture.socketURL.path]
        )
        #expect(invalid.status == 1)
        #expect(invalid.error.contains("路径不存在"))
        #expect(try ProjectWorkspaceRepository(databaseURL: fixture.databaseURL).listProjects().count == 1)
    }

    @Test("listener rejects malformed actions without changing the database")
    func listenerRejectsInvalidAction() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let service = YCodeProjectOpenService(databaseURL: fixture.databaseURL)
        let listener = YCodeCLIListener(socketURL: fixture.socketURL) { try service.resolve($0) }
        defer { listener.stop() }
        try listener.start()
        #expect(throws: YCodeCLITransportError.self) {
            try YCodeCLITransport.send(
                YCodeCLIOpenRequest(action: "delete", path: fixture.root.path),
                to: fixture.socketURL
            )
        }
        #expect(try ProjectWorkspaceRepository(databaseURL: fixture.databaseURL).listProjects().isEmpty)
    }

    @Test("CLI installation is idempotent and never replaces unrelated files")
    func installationSafety() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let newBundle = fixture.root.appendingPathComponent("New YCode.app/Contents/Resources", isDirectory: true)
        let oldBundle = fixture.root.appendingPathComponent("Old YCode.app/Contents/Resources/binaries", isDirectory: true)
        try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldBundle, withIntermediateDirectories: true)
        let helper = newBundle.appendingPathComponent("ycode")
        let oldHelper = oldBundle.appendingPathComponent("ycode-cli")
        for url in [helper, oldHelper] {
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let link = fixture.root.appendingPathComponent("bin/ycode")
        let installer = YCodeCLIInstallationService(helperURL: helper, installURL: link)

        #expect(await installer.status() == .notInstalled)
        let installed = try await installer.install(allowElevation: false)
        guard case .installed = installed else { Issue.record("expected installed"); return }
        guard case .installed = try await installer.install(allowElevation: false) else {
            Issue.record("second install should remain installed"); return
        }

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: oldHelper)
        guard case .stale = await installer.status() else { Issue.record("expected stale"); return }
        guard case .installed = try await installer.install(allowElevation: false) else {
            Issue.record("repair should install current target"); return
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == helper.path)
        #expect(try await installer.uninstall(allowElevation: false) == .notInstalled)
        #expect(try await installer.uninstall(allowElevation: false) == .notInstalled)

        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user-owned".utf8).write(to: link)
        guard case .conflict = await installer.status() else { Issue.record("expected conflict"); return }
        await #expect(throws: YCodeCLIInstallationError.self) {
            try await installer.install(allowElevation: false)
        }
        await #expect(throws: YCodeCLIInstallationError.self) {
            try await installer.uninstall(allowElevation: false)
        }
        #expect(try String(contentsOf: link, encoding: .utf8) == "user-owned")
    }

    private func cliExecutable() throws -> URL {
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ycode"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/ycode")
        ]
        return try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private func runCLI(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

private struct CLIFixture {
    let root: URL
    let databaseURL: URL
    let socketURL: URL

    init() throws {
        root = URL(fileURLWithPath: "/tmp/ycode-cli-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        databaseURL = root.appendingPathComponent("data/ycode.db")
        socketURL = root.appendingPathComponent("cli.sock")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
