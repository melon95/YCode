import Foundation
import Testing
@testable import YCodeCore

@Suite(.serialized)
struct HistoryIntrospectionTests {
    @Test func scansAndNormalizesClaudeAndCodexWithoutTouchingSource() throws {
        let fixture = try HistoryFixture()
        let index = YCodeHistoryIndex()
        let beforeClaude = try Data(contentsOf: fixture.claudeFile)
        let beforeCodex = try Data(contentsOf: fixture.codexFile)

        let sessions = index.scanWorkspace(homeDirectory: fixture.home, workspace: fixture.workspace)
        #expect(sessions.count == 2)
        #expect(Set(sessions.map(\.agent)) == [.codex, .claude])
        #expect(sessions.first(where: { $0.agent == .claude })?.title == "整理迁移计划")
        #expect(sessions.first(where: { $0.agent == .codex })?.title == "继续原生迁移")

        let claude = try #require(sessions.first { $0.agent == .claude })
        let claudeEvents = try index.events(for: claude)
        #expect(claudeEvents.count == 4)
        #expect(claudeEvents.map(\.sequence) == [0, 2, 3, 4])
        #expect(claudeEvents[0].preview == "整理迁移计划")
        #expect(claudeEvents[1].preview == "[tool: Read]")
        #expect(claudeEvents[3].preview == "先思考")

        let codex = try #require(sessions.first { $0.agent == .codex })
        let codexEvents = try index.events(for: codex)
        #expect(codexEvents.count == 4)
        #expect(codexEvents.map(\.sequence) == [1, 2, 3, 4])
        #expect(codexEvents[2].preview == "完成原生历史")
        #expect(codexEvents[3].preview == "[tool: shell]")

        #expect(try Data(contentsOf: fixture.claudeFile) == beforeClaude)
        #expect(try Data(contentsOf: fixture.codexFile) == beforeCodex)
    }

    @Test func searchIsStableAndSkipsMalformedLines() throws {
        let fixture = try HistoryFixture()
        let index = YCodeHistoryIndex()
        let first = try index.search(homeDirectory: fixture.home, workspace: fixture.workspace, query: "迁移")
        let second = try index.search(homeDirectory: fixture.home, workspace: fixture.workspace, query: "迁移")
        #expect(first.count == 2)
        #expect(second.map(\.id) == first.map(\.id))
        #expect(Set(first.map(\.event.agent)) == [.claude, .codex])
        #expect(index.retainedEventCount == 0)
        #expect(try index.search(homeDirectory: fixture.home, workspace: fixture.workspace, query: "CLAUDE").count == 1)
        #expect(try index.search(homeDirectory: fixture.home, workspace: fixture.workspace, query: "不存在").isEmpty)
    }

    @Test func appendsIncrementallyAndReloadsAfterTruncation() throws {
        let fixture = try HistoryFixture()
        let index = YCodeHistoryIndex()
        var session = try #require(index.scanWorkspace(homeDirectory: fixture.home, workspace: fixture.workspace).first { $0.agent == .claude })
        let initial = try index.events(for: session)
        #expect(initial.count == 4)

        let handle = try FileHandle(forWritingTo: fixture.claudeFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"assistant\",\"timestamp\":\"2026-09-16T10:00:05.000Z\",\"message\":{\"content\":\"增量可见\"}}\n".utf8))
        try handle.close()
        session = try #require(index.scanWorkspace(homeDirectory: fixture.home, workspace: fixture.workspace).first { $0.agent == .claude })
        let appended = try index.events(for: session)
        #expect(appended.count == 5)
        #expect(appended.last?.preview == "增量可见")
        #expect(Set(appended.map(\.id)).count == appended.count)

        try Data("{\"type\":\"user\",\"message\":{\"content\":\"截断后的新内容\"}}\n".utf8).write(to: fixture.claudeFile, options: .atomic)
        session = try #require(index.scanWorkspace(homeDirectory: fixture.home, workspace: fixture.workspace).first { $0.agent == .claude })
        let truncated = try index.events(for: session)
        #expect(truncated.count == 1)
        #expect(truncated[0].sequence == 0)
        #expect(truncated[0].preview == "截断后的新内容")
    }
}

private struct HistoryFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let claudeFile: URL
    let codexFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-history-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("项目 with.space", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let claudeDirectory = home.appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(YCodeHistoryIndex.encodeClaudeWorkspace(workspace), isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        claudeFile = claudeDirectory.appendingPathComponent("claude-session.jsonl")
        let claudeLines = [
            #"{"type":"user","timestamp":"2026-09-16T10:00:00.123Z","message":{"content":"整理迁移计划"}}"#,
            "{broken-json",
            #"{"type":"assistant","timestamp":"2026-09-16T10:00:01.000Z","message":{"content":[{"type":"tool_use","name":"Read","input":{"path":"计划.md"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-16T10:00:02.000Z","message":{"content":[{"type":"text","text":"Claude 完成"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-16T10:00:03.000Z","message":{"content":[{"type":"thinking","thinking":"先思考"},{"type":"tool_use","name":"Bash","input":{"cmd":"true"}}]}}"#
        ]
        try Data((claudeLines.joined(separator: "\n") + "\n").utf8).write(to: claudeFile)

        let codexDirectory = home.appendingPathComponent(".codex/sessions/2026/09/16", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        codexFile = codexDirectory.appendingPathComponent("rollout-codex-session.jsonl")
        let codexLines = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"codex-session\",\"cwd\":\"\(workspace.path)\",\"originator\":\"Codex CLI\"}}",
            #"{"type":"response_item","timestamp":"2026-09-16T10:00:00.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>synthetic</environment_context>"}]}}"#,
            #"{"type":"response_item","timestamp":"2026-09-16T10:00:01.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"继续原生迁移"}]}}"#,
            #"{"type":"event_msg","timestamp":"2026-09-16T10:00:02.000Z","payload":{"type":"agent_message","message":"完成原生历史"}}"#,
            #"{"type":"response_item","timestamp":"2026-09-16T10:00:03.000Z","payload":{"type":"function_call","name":"shell","arguments":{"cmd":"true"}}}"#
        ]
        try Data((codexLines.joined(separator: "\n") + "\n").utf8).write(to: codexFile)

        for (name, originator) in [
            ("rollout-old-desktop.jsonl", "Codex Desktop"),
            ("rollout-current-desktop.jsonl", "codex_work_desktop"),
        ] {
            let url = codexDirectory.appendingPathComponent(name)
            let line = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(name)\",\"cwd\":\"\(workspace.path)\",\"originator\":\"\(originator)\"}}\n"
            try Data(line.utf8).write(to: url)
        }
    }
}
