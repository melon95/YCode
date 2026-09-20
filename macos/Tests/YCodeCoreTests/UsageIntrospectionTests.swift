import Foundation
import Testing
@testable import YCodeCore

@Suite("Usage introspection")
struct UsageIntrospectionTests {
    @Test("Claude dedupes message IDs and counts anonymous turns")
    func claudeDeduplication() throws {
        let fixture = try UsageFixture()
        defer { fixture.remove() }
        let usage = YCodeUsageAnalyzer().aggregateWorkspace(homeDirectory: fixture.home, workspace: fixture.workspace)

        let claude = try #require(usage.sessions.first { $0.agent == .claude })
        #expect(claude.tokens == YCodeTokenCounts(input: 115, output: 62, cacheCreation: 7, cacheRead: 11))
        #expect(claude.messageCount == 4)
        #expect(claude.model == "claude-opus-4-8")
    }

    @Test("Codex uses last cumulative counter and separates cached input")
    func codexCumulativeUsage() throws {
        let fixture = try UsageFixture()
        defer { fixture.remove() }
        let usage = YCodeUsageAnalyzer().aggregateWorkspace(homeDirectory: fixture.home, workspace: fixture.workspace)

        let codex = try #require(usage.sessions.first { $0.agent == .codex })
        #expect(codex.tokens == YCodeTokenCounts(input: 500, output: 300, cacheRead: 1_500, reasoning: 90))
        #expect(codex.messageCount == 1)
        #expect(codex.model == "gpt-5.5")
        #expect(usage.totals.total == 2_495)
        #expect(usage.totals.reasoning == 90)
    }

    @Test("unknown models keep tokens at zero cost and UTC dates keep their boundary")
    func missingModelAndDateBoundary() throws {
        let fixture = try UsageFixture(includeUnknownCodex: true)
        defer { fixture.remove() }
        let usage = YCodeUsageAnalyzer().aggregateWorkspace(homeDirectory: fixture.home, workspace: fixture.workspace)

        let unknown = try #require(usage.sessions.first { $0.sessionID == "unknown-codex" })
        #expect(unknown.tokens.total == 15)
        #expect(unknown.model == nil)
        #expect(unknown.costUSD == 0)
        #expect(usage.byDay.map(\.date) == ["2026-06-18", "2026-06-19"])
    }

    @Test("project aggregation reports each registered project")
    func projectAggregation() throws {
        let first = try UsageFixture()
        defer { first.remove() }
        let analyzer = YCodeUsageAnalyzer()
        let usage = analyzer.aggregateProjects(homeDirectory: first.home, projects: [
            .init(id: "one", name: "One", workspaceURLs: [first.workspace]),
            .init(id: "duplicate", name: "Duplicate cwd", workspaceURLs: [first.workspace, first.workspace]),
        ])

        #expect(usage.byProject.count == 2)
        #expect(usage.byProject.allSatisfy { $0.sessionCount == 2 })
        #expect(usage.byProject.allSatisfy { $0.tokens.total == 2_495 })
        #expect(usage.sessions.count == 2)
        #expect(usage.totals.total == 4_990)
    }
}

private struct UsageFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init(workspaceName: String = "usage repo", includeUnknownCodex: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-usage-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        workspace = root.appendingPathComponent(workspaceName)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let claudeDirectory = home.appendingPathComponent(".claude/projects")
            .appendingPathComponent(YCodeHistoryIndex.encodeClaudeWorkspace(workspace))
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let claude = claudeDirectory.appendingPathComponent("claude-usage.jsonl")
        let claudeLines = [
            #"{"type":"user","message":{"content":"Usage title"}}"#,
            #"{"type":"assistant","timestamp":"2026-06-18T23:59:59.900Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":7,"cache_read_input_tokens":11}}}"#,
            #"{"type":"assistant","timestamp":"2026-06-18T23:59:59.950Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":90,"output_tokens":40,"cache_creation_input_tokens":7,"cache_read_input_tokens":11}}}"#,
            #"{"type":"assistant","timestamp":"2026-06-19T00:00:00.000Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"assistant","timestamp":"2026-06-19T00:00:00.100Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":2,"output_tokens":3}}}"#,
            #"{"type":"assistant","timestamp":"2026-06-19T00:00:00.200Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":3,"output_tokens":4}}}"#,
        ]
        try Data((claudeLines.joined(separator: "\n") + "\n").utf8).write(to: claude)

        let codexDirectory = home.appendingPathComponent(".codex/sessions/2026/06/19")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try writeCodex(
            to: codexDirectory.appendingPathComponent("rollout-known.jsonl"),
            id: "known-codex",
            modelLine: #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            counters: [
                ("2026-06-19T00:01:00Z", 1_000, 800, 100, 40),
                ("2026-06-19T00:02:00Z", 2_000, 1_500, 300, 90),
            ]
        )
        if includeUnknownCodex {
            try writeCodex(
                to: codexDirectory.appendingPathComponent("rollout-unknown.jsonl"),
                id: "unknown-codex",
                modelLine: nil,
                counters: [("2026-06-19T00:03:00Z", 10, 0, 5, 0)]
            )
        }
    }

    private func writeCodex(
        to url: URL,
        id: String,
        modelLine: String?,
        counters: [(String, Int, Int, Int, Int)]
    ) throws {
        var lines = [#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(workspace.path)","originator":"Codex CLI"}}"#]
        if let modelLine { lines.append(modelLine) }
        lines.append(contentsOf: counters.map { timestamp, input, cached, output, reasoning in
            #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning)}}}}"#
        })
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
