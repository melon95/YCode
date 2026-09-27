import XCTest
@testable import YCodeCore

/// 在 ycode 里改名，pi 的会话文件里也要能看到同一个名字（`pi --resume` 的列表读的就是它）。
final class AgentSessionTitleWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ycode-title-writer-\(UUID().uuidString)", isDirectory: true)
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

    /// 追加的是 pi 自己定义的 `session_info` 条目，而且挂在文件最后一条下面。
    func testAppendsPiSessionInfoEntry() throws {
        let url = try writePiSession([Self.header, Self.firstUser])
        let before = try Data(contentsOf: url)

        let outcome = YCodeAgentSessionTitleWriter.write(title: "登录接口排查", introspect: "pi", jsonlPath: url.path)
        XCTAssertEqual(outcome, .written)

        let after = try Data(contentsOf: url)
        // 只许追加：原有内容一个字节都不能动，不然正在跑的 CLI 会把记录写丢。
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

    /// 写进去的名字，ycode 自己的历史扫描也要认——否则下一轮扫描又把标题推回首条消息。
    func testHistoryScanPrefersWrittenName() throws {
        let url = try writePiSession([Self.header, Self.firstUser])
        XCTAssertEqual(YCodeAgentSessionTitleWriter.write(title: "登录接口排查", introspect: "pi", jsonlPath: url.path), .written)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(YCodeHistoryIndex.piSessionInfoNameForTesting(data), "登录接口排查")

        // 再改一次：取最后一条，不是第一条。
        XCTAssertEqual(YCodeAgentSessionTitleWriter.write(title: "改完了", introspect: "pi", jsonlPath: url.path), .written)
        XCTAssertEqual(
            YCodeHistoryIndex.piSessionInfoNameForTesting(try Data(contentsOf: url)),
            "改完了"
        )
    }

    /// 上一次写入没以换行收尾（CLI 被强杀）时，不能把两条记录粘成一行。
    func testRepairsMissingTrailingNewline() throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try (Self.header + "\n" + Self.firstUser).write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(YCodeAgentSessionTitleWriter.write(title: "补一行", introspect: "pi", jsonlPath: url.path), .written)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(lines[2].utf8)))
    }

    /// 缺少原生会话 ID 时不能猜目标，也不能写错会话。
    func testUnsupportedAgentsLeaveTheFileAlone() throws {
        let url = try writePiSession([Self.header, Self.firstUser])
        let before = try Data(contentsOf: url)

        XCTAssertEqual(YCodeAgentSessionTitleWriter.write(title: "名字", introspect: "claude", jsonlPath: url.path), .missingFile)
        XCTAssertEqual(YCodeAgentSessionTitleWriter.write(title: "名字", introspect: "codex", jsonlPath: url.path), .missingFile)
        XCTAssertEqual(YCodeAgentSessionTitleWriter.write(title: "名字", introspect: nil, jsonlPath: url.path), .unsupported)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    /// 库里还没记下文件路径（刚建、CLI 没落盘）时是 `.missingFile`，不是错误。
    func testMissingFileIsReported() {
        XCTAssertEqual(YCodeAgentSessionTitleWriter.write(title: "名字", introspect: "pi", jsonlPath: nil), .missingFile)
        XCTAssertEqual(
            YCodeAgentSessionTitleWriter.write(
                title: "名字",
                introspect: "pi",
                jsonlPath: directory.appendingPathComponent("nope.jsonl").path
            ),
            .missingFile
        )
    }
}
