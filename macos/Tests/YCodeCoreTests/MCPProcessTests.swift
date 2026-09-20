import Foundation
import Testing
@testable import YCodeCore

@Suite("Swift Todo MCP process", .serialized)
struct MCPProcessTests {
    @Test("stdio client discovers tools and performs validated CRUD")
    func protocolRoundTrip() throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        let requests: [[String: Any]] = [
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "tests", "version": "1"]]
            ],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]],
            [
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": ["name": "add_todo", "arguments": ["title": "from MCP"]]
            ]
        ]
        let first = try runMCP(requests: requests, fixture: fixture)
        #expect(first.count == 3)
        #expect(value(first[0], at: ["result", "serverInfo", "name"]) as? String == "ycode-todos")
        let tools = try #require(value(first[1], at: ["result", "tools"]) as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["list_todos", "add_todo", "update_todo", "delete_todo"])
        let addedContent = try #require(value(first[2], at: ["result", "content"]) as? [[String: Any]])
        let addedText = try #require(addedContent.first?["text"] as? String)
        let added = try #require(try JSONSerialization.jsonObject(with: Data(addedText.utf8)) as? [String: Any])
        let id = try #require(added["id"] as? String)

        let second = try runMCP(requests: [
            [
                "jsonrpc": "2.0", "id": 4, "method": "tools/call",
                "params": ["name": "update_todo", "arguments": ["id": id, "status": "blocked"]]
            ],
            [
                "jsonrpc": "2.0", "id": 5, "method": "tools/call",
                "params": ["name": "list_todos", "arguments": [:]]
            ],
            [
                "jsonrpc": "2.0", "id": 6, "method": "tools/call",
                "params": ["name": "delete_todo", "arguments": ["id": id]]
            ]
        ], fixture: fixture)
        #expect(value(second[0], at: ["result", "isError"]) as? Bool == true)
        let listContent = try #require(value(second[1], at: ["result", "content"]) as? [[String: Any]])
        let listText = try #require(listContent.first?["text"] as? String)
        let listed = try #require(try JSONSerialization.jsonObject(with: Data(listText.utf8)) as? [[String: Any]])
        #expect(listed.count == 1)
        #expect(listed[0]["status"] as? String == "todo")
        #expect(value(second[2], at: ["result", "isError"]) as? Bool == false)
        #expect(try YCodeTodoRepository(databaseURL: fixture.databaseURL).list(projectID: fixture.project.id).isEmpty)
    }

    private func runMCP(requests: [[String: Any]], fixture: MCPFixture) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = try mcpExecutable()
        process.currentDirectoryURL = fixture.repositoryURL
        var environment = ProcessInfo.processInfo.environment
        environment["YCODE_NATIVE_DATA_ROOT"] = fixture.databaseURL.deletingLastPathComponent().path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let payload = try requests.map { request in
            String(decoding: try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: stderr))
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
    }

    private func mcpExecutable() throws -> URL {
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ycode-mcp"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/ycode-mcp")
        ]
        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return executable
        }
        throw MCPTestError.missingExecutable(candidates.map(\.path))
    }

    private func value(_ object: [String: Any], at path: [String]) -> Any? {
        path.reduce(object as Any?) { partial, key in (partial as? [String: Any])?[key] }
    }
}

private enum MCPTestError: Error {
    case missingExecutable([String])
}

private struct MCPFixture {
    let root: URL
    let databaseURL: URL
    let repositoryURL: URL
    let project: ProjectRecord

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-mcp-\(UUID().uuidString)")
        databaseURL = root.appendingPathComponent("data/ycode.db")
        repositoryURL = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        project = try ProjectWorkspaceRepository(databaseURL: databaseURL).addProject(directory: repositoryURL)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
