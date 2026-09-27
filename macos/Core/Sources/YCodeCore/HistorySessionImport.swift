import Foundation

/// 闲置多久算「该收进归档」：14 天。侧栏默认只看活跃会话，
/// 半个月没碰过的那条对当下的工作没有任何帮助，但它也不该被删——归档档位随时能翻回来。
///
/// 导入历史和定时清扫用的是同一个阈值，两边不能各写各的：
/// 否则导入进来是活跃的、一小时后又被扫走，列表会自己跳。
public enum YCodeSessionArchivePolicy {
    public static let idleInterval: TimeInterval = 14 * 24 * 60 * 60
}

/// 一条准备写进 sessions 表的「发现来的」会话。
/// 跟 `createSession` 不同的是它带着 jsonl 自己的时间戳与归档状态：
/// 导入的是历史，不是刚刚新建的东西。
public struct DiscoveredSessionDraft: Sendable, Equatable {
    public let projectID: String
    public let title: String
    public let agentProfile: String
    public let agentSessionID: String
    /// 这条会话在磁盘上的 jsonl。记下来是为了删除会话时能连它一起收掉，
    /// 否则下一轮扫描又会把同一条对话原样导回来。
    public let jsonlPath: String
    public let updatedAtMilliseconds: Int64
    public let archivedAtMilliseconds: Int64?

    public init(
        projectID: String,
        title: String,
        agentProfile: String,
        agentSessionID: String,
        jsonlPath: String,
        updatedAtMilliseconds: Int64,
        archivedAtMilliseconds: Int64?
    ) {
        self.projectID = projectID
        self.title = title
        self.agentProfile = agentProfile
        self.agentSessionID = agentSessionID
        self.jsonlPath = jsonlPath
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.archivedAtMilliseconds = archivedAtMilliseconds
    }
}

/// 把扫到的 jsonl 历史折算成会话行。
///
/// 侧栏原先把「历史会话」单列一节，于是同一条对话在界面上有两种身份：
/// 活着的时候是会话，退出之后变成历史。现在只保留一种——jsonl 一开始就是会话，
/// 14 天没动静的直接落在归档档位里，需要时从那儿捞回来。
public enum YCodeHistorySessionImport {
    /// - Parameters:
    ///   - profileIDsByIntrospect: introspect id（`claude` / `codex` / `pi`）→ 启动用的 profile id。
    ///     没有对应 profile 的历史直接跳过：导进来也没有 agent 能 resume 它。
    public static func drafts(
        sessions: [YCodeHistorySession],
        projectID: String,
        profileIDsByIntrospect: [String: String],
        now: Date = Date(),
        idleInterval: TimeInterval = YCodeSessionArchivePolicy.idleInterval
    ) -> [DiscoveredSessionDraft] {
        let cutoff = Int64((now.timeIntervalSince1970 - idleInterval) * 1_000)
        let archivedAt = Int64(now.timeIntervalSince1970 * 1_000)
        var seen = Set<String>()
        var drafts: [DiscoveredSessionDraft] = []
        for session in sessions {
            let agentSessionID = session.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !agentSessionID.isEmpty,
                  seen.insert(session.agent.rawValue + ":" + agentSessionID).inserted,
                  let profileID = profileIDsByIntrospect[session.agent.rawValue] else { continue }
            drafts.append(
                DiscoveredSessionDraft(
                    projectID: projectID,
                    title: title(for: session),
                    agentProfile: profileID,
                    agentSessionID: agentSessionID,
                    jsonlPath: session.jsonlURL.standardizedFileURL.path,
                    updatedAtMilliseconds: session.modifiedAtMilliseconds,
                    // 导入时就把超期的那批标成归档，省得它们先在活跃列表里闪一下
                    // 再被定时清扫收走。
                    archivedAtMilliseconds: session.modifiedAtMilliseconds < cutoff ? archivedAt : nil
                )
            )
        }
        return drafts
    }

    /// jsonl 里没读出标题时退回短 id：这类会话在列表里至少还能互相区分，
    /// 而空标题会被界面显示成斜体的「新会话」——它明明不是新的。
    private static func title(for session: YCodeHistorySession) -> String {
        let trimmed = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return String(session.sessionID.prefix(8))
    }
}
