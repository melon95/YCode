import Foundation
import Testing
@testable import YCodeCore

struct HistorySessionImportTests {
    private func history(
        agent: YCodeHistoryAgent,
        sessionID: String,
        title: String?,
        modifiedAtMilliseconds: Int64
    ) -> YCodeHistorySession {
        YCodeHistorySession(
            agent: agent,
            sessionID: sessionID,
            jsonlURL: URL(fileURLWithPath: "/tmp/\(sessionID).jsonl"),
            workspaceURL: URL(fileURLWithPath: "/tmp/repo", isDirectory: true),
            title: title,
            sizeBytes: 10,
            modifiedAtMilliseconds: modifiedAtMilliseconds
        )
    }

    @Test func jsonlBecomesSessionsAndAnythingOlderThanFourteenDaysArrivesArchived() {
        let now = Date()
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let day: Int64 = 24 * 60 * 60 * 1_000

        let drafts = YCodeHistorySessionImport.drafts(
            sessions: [
                history(agent: .claude, sessionID: "fresh", title: "最近这条", modifiedAtMilliseconds: nowMilliseconds - 2 * day),
                history(agent: .codex, sessionID: "stale", title: "上个月那条", modifiedAtMilliseconds: nowMilliseconds - 30 * day),
            ],
            projectID: "p1",
            profileIDsByIntrospect: ["claude": "claude-code", "codex": "codex"],
            now: now
        )

        #expect(drafts.map(\.agentSessionID) == ["fresh", "stale"])
        #expect(drafts[0].agentProfile == "claude-code")
        #expect(drafts[0].archivedAtMilliseconds == nil)
        // 14 天以前的那条一进来就是归档状态，不会先在活跃列表里闪一下。
        #expect(drafts[1].archivedAtMilliseconds != nil)
        // 时间戳用 jsonl 自己的，不是「导入的此刻」。
        #expect(drafts[1].updatedAtMilliseconds == nowMilliseconds - 30 * day)
        // jsonl 路径要一路带到库里：删除会话时靠它找到要删的文件。
        #expect(drafts[0].jsonlPath == "/tmp/fresh.jsonl")
    }

    @Test func duplicateOrUnlaunchableHistoryIsSkipped() {
        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)

        let drafts = YCodeHistorySessionImport.drafts(
            sessions: [
                history(agent: .claude, sessionID: "twice", title: "同一条扫了两次", modifiedAtMilliseconds: nowMilliseconds),
                history(agent: .claude, sessionID: "twice", title: "同一条扫了两次", modifiedAtMilliseconds: nowMilliseconds),
                history(agent: .codex, sessionID: "no-agent", title: "没有配 codex", modifiedAtMilliseconds: nowMilliseconds),
                history(agent: .claude, sessionID: "  ", title: "空 id", modifiedAtMilliseconds: nowMilliseconds),
                history(agent: .claude, sessionID: "untitled-0123456789", title: "   ", modifiedAtMilliseconds: nowMilliseconds),
            ],
            projectID: "p1",
            profileIDsByIntrospect: ["claude": "claude-code"]
        )

        #expect(drafts.map(\.agentSessionID) == ["twice", "untitled-0123456789"])
        // 读不出标题时退回短 id —— 空标题会被界面显示成「新会话」，它明明不是新的。
        #expect(drafts[1].title == "untitled")
    }
}
