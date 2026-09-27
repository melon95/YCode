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
        #expect(sessions.count == 3)
        #expect(Set(sessions.map(\.agent)) == [.codex, .claude, .pi])
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

    @Test func scansPiSessionsFromEncodedWorkspaceDirectory() throws {
        let fixture = try HistoryFixture()
        let index = YCodeHistoryIndex()
        let before = try Data(contentsOf: fixture.piFile)

        let session = try #require(
            index.scanWorkspace(homeDirectory: fixture.home, workspace: fixture.workspace).first { $0.agent == .pi }
        )
        // 文件名是 `<时间戳>_<会话 id>.jsonl`，只有下划线后面那截才是 pi --resume 认的 id。
        #expect(session.sessionID == "01a0c6de-636a-7211-ae7f-725cfcc36faf")
        // 标题取第一条用户消息，而不是那条带着整段 preamble 的 system 消息。
        #expect(session.title == "读取 pi 历史")

        let events = try index.events(for: session)
        // 首行 `session` 是文件头，不产出事件（与 codex 的 session_meta 同处理），
        // 所以 sequence 从 1 起跳；`model_change` 留成 unknown 占住 sequence 1，
        // 于是 sequence 始终等于行号 —— 增量追加时不会错位。
        #expect(events.map(\.sequence) == [1, 2, 3, 4, 5, 6, 7])
        #expect(events.map(\.preview) == [
            "?? model_change",
            "<skill name=\"apple-design\" location=\"/x/SKILL.md\">\nRefs\n</skill>",
            "读取 pi 历史",
            "先看一眼格式",
            "[tool: bash]",
            "[result: bash]",
            "pi 历史已接入"
        ])
        // 状态变更行不参与排序与搜索：时间戳被抹成 0。
        #expect(events[0].timestampMilliseconds == 0)
        #expect(events.dropFirst().allSatisfy { $0.timestampMilliseconds > 0 })

        // 图片分片只有 base64，绝不能混进正文 —— 否则一条消息几百 KB 会把预览和搜索撑爆。
        #expect(events[2].preview == "读取 pi 历史")
        #expect(!events[2].preview.contains("iVBOR"))

        #expect(try Data(contentsOf: fixture.piFile) == before)
    }

    @Test func piToolResultCarriesErrorStatusAndToolName() throws {
        let fixture = try HistoryFixture()
        let index = YCodeHistoryIndex()
        let session = try #require(
            index.scanWorkspace(homeDirectory: fixture.home, workspace: fixture.workspace).first { $0.agent == .pi }
        )
        let events = try index.events(for: session)
        let result = try #require(events.first {
            if case .toolResult = $0.kind { return true }
            return false
        })
        guard case let .toolResult(tool, excerpt, status) = result.kind else {
            Issue.record("expected toolResult")
            return
        }
        // pi 直接给了工具名，不用像 Claude 那样拿 tool_use_id 回查。
        #expect(tool == "bash")
        #expect(excerpt.contains("ok"))
        #expect(status == .ok)
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
    let piFile: URL

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

        // pi：~/.pi/agent/sessions/<编码后的 cwd>/<时间戳>_<id>.jsonl
        // 这几行的形状照抄自真实文件（~/.pi/agent/sessions/），包括 image 分片、
        // 数字毫秒时间戳、以及 toolResult 上的 toolName / isError。
        let piDirectory = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
            .appendingPathComponent(YCodeHistoryIndex.encodePiWorkspace(workspace), isDirectory: true)
        try FileManager.default.createDirectory(at: piDirectory, withIntermediateDirectories: true)
        piFile = piDirectory.appendingPathComponent("2026-09-22T02-07-38-346Z_01a0c6de-636a-7211-ae7f-725cfcc36faf.jsonl")
        let piLines = [
            "{\"type\":\"session\",\"version\":3,\"id\":\"01a0c6de-636a-7211-ae7f-725cfcc36faf\",\"timestamp\":\"2026-09-22T02:07:38.346Z\",\"cwd\":\"\(workspace.path)\"}",
            #"{"type":"model_change","id":"e839","parentId":null,"timestamp":"2026-09-22T02:07:38.587Z","provider":"anthropic","modelId":"claude-opus-5"}"#,
            // pi 把 skill 作为一条独立的 user 消息注入 —— 标题必须跳过它，
            // 否则会变成一整段 skill 正文（真实数据里确实出现过 22KB 的标题）。
            #"{"type":"message","id":"a0","parentId":null,"timestamp":"2026-09-22T02:07:39.000Z","message":{"role":"user","content":[{"type":"text","text":"<skill name=\"apple-design\" location=\"/x/SKILL.md\">\nRefs\n</skill>"}]}}"#,
            #"{"type":"message","id":"a1","parentId":null,"timestamp":"2026-09-22T02:07:40.000Z","message":{"role":"user","content":[{"type":"text","text":"读取 pi 历史"},{"type":"image","data":"iVBORw0KGgoAAAANSUhEUg"}]}}"#,
            #"{"type":"message","id":"a2","parentId":"a1","timestamp":"2026-09-22T02:07:41.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"先看一眼格式","thinkingSignature":"xx"},{"type":"toolCall","id":"toolu_1","name":"bash","arguments":{"command":"ls"}}]}}"#,
            #"{"type":"message","id":"a3","parentId":"a2","timestamp":"2026-09-22T02:07:42.000Z","message":{"role":"assistant","content":[{"type":"text","text":"跑一下"},{"type":"toolCall","id":"toolu_2","name":"bash","arguments":{"command":"true"}}]}}"#,
            #"{"type":"message","id":"a4","parentId":"a3","timestamp":"2026-09-22T02:07:43.000Z","message":{"role":"toolResult","toolCallId":"toolu_1","toolName":"bash","content":[{"type":"text","text":"ok"}],"isError":false,"timestamp":1790041763724}}"#,
            #"{"type":"message","id":"a5","parentId":"a4","timestamp":"2026-09-22T02:07:44.000Z","message":{"role":"assistant","content":[{"type":"text","text":"pi 历史已接入"}]}}"#
        ]
        try Data((piLines.joined(separator: "\n") + "\n").utf8).write(to: piFile)

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
