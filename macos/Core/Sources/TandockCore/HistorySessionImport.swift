import Foundation

public enum TandockSessionArchivePolicy {
    public static let idleInterval: TimeInterval = 14 * 24 * 60 * 60
}

public struct DiscoveredSessionDraft: Sendable, Equatable {
    public let projectID: String
    public let title: String
    public let agentProfile: String
    public let agentSessionID: String
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

public enum TandockHistorySessionImport {
    public static func drafts(
        sessions: [TandockHistorySession],
        projectID: String,
        profileIDsByIntrospect: [String: String],
        now: Date = Date(),
        idleInterval: TimeInterval = TandockSessionArchivePolicy.idleInterval
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
                    archivedAtMilliseconds: session.modifiedAtMilliseconds < cutoff ? archivedAt : nil
                )
            )
        }
        return drafts
    }

    private static func title(for session: TandockHistorySession) -> String {
        let trimmed = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return String(session.sessionID.prefix(8))
    }
}
