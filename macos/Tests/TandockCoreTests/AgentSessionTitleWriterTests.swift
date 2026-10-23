import XCTest
@testable import TandockCore

final class AgentSessionTitleWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tandock-title-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writePiSession(_ lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent("session.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let header = #"{"type":"session","version":3,"id":"01a0d13b","timestamp":"2026-09-24T02:25:06.047Z","cwd":"/tmp"}"#
    private static let firstUser = #"{"type":"message","id":"aaaa1111","parentId":null,"timestamp":"2026-09-24T02:25:07.000Z","message":{"role":"user","content":"帮我看下登录接口"}}"#

    func testAppendsPiSessionInfoEntry() throws {
        let url = try writePiSession([Self.header, Self.firstUser])
        let before = try Data(contentsOf: url)

        let outcome = TandockAgentSessionTitleWriter.write(title: "登录接口排查", introspect: "pi", jsonlPath: url.path)
        XCTAssertEqual(outcome, .written)

        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.prefix(before.count), before)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        let entry = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any]
        )
        XCTAssertEqual(entry["type"] as? String, "session_info")
        XCTAssertEqual(entry["name"] as? String, "登录接口排查")
        XCTAssertEqual(entry["parentId"] as? String, "aaaa1111")
        XCTAssertEqual((entry["id"] as? String)?.count, 8)
        XCTAssertNotEqual(entry["id"] as? String, "aaaa1111")
    }

    func testHistoryScanPrefersWrittenName() throws {
        let url = try writePiSession([Self.header, Self.firstUser])
        XCTAssertEqual(TandockAgentSessionTitleWriter.write(title: "登录接口排查", introspect: "pi", jsonlPath: url.path), .written)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(TandockHistoryIndex.piSessionInfoNameForTesting(data), "登录接口排查")

        XCTAssertEqual(TandockAgentSessionTitleWriter.write(title: "改完了", introspect: "pi", jsonlPath: url.path), .written)
        XCTAssertEqual(
            TandockHistoryIndex.piSessionInfoNameForTesting(try Data(contentsOf: url)),
            "改完了"
        )
    }

    func testRepairsMissingTrailingNewline() throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try (Self.header + "\n" + Self.firstUser).write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(TandockAgentSessionTitleWriter.write(title: "补一行", introspect: "pi", jsonlPath: url.path), .written)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(lines[2].utf8)))
    }

    func testUnsupportedAgentsLeaveTheFileAlone() throws {
        let url = try writePiSession([Self.header, Self.firstUser])
        let before = try Data(contentsOf: url)

        XCTAssertEqual(TandockAgentSessionTitleWriter.write(title: "名字", introspect: "claude", jsonlPath: url.path), .missingFile)
        XCTAssertEqual(TandockAgentSessionTitleWriter.write(title: "名字", introspect: "codex", jsonlPath: url.path), .missingFile)
        XCTAssertEqual(TandockAgentSessionTitleWriter.write(title: "名字", introspect: nil, jsonlPath: url.path), .unsupported)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testMissingFileIsReported() {
        XCTAssertEqual(TandockAgentSessionTitleWriter.write(title: "名字", introspect: "pi", jsonlPath: nil), .missingFile)
        XCTAssertEqual(
            TandockAgentSessionTitleWriter.write(
                title: "名字",
                introspect: "pi",
                jsonlPath: directory.appendingPathComponent("nope.jsonl").path
            ),
            .missingFile
        )
    }
}
