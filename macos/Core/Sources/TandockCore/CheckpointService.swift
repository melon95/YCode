import Foundation

public struct TandockCheckpointRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let projectID: String
    public let sequence: Int
    public let commitSHA: String
    public let refName: String
    public let kind: String
    public let source: String?
    public let eventKind: String?
    public let bodyPreview: String?
    public let createdAtMilliseconds: Int64

    public init(
        id: String,
        sessionID: String,
        projectID: String,
        sequence: Int,
        commitSHA: String,
        refName: String,
        kind: String,
        source: String?,
        eventKind: String?,
        bodyPreview: String?,
        createdAtMilliseconds: Int64
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectID = projectID
        self.sequence = sequence
        self.commitSHA = commitSHA
        self.refName = refName
        self.kind = kind
        self.source = source
        self.eventKind = eventKind
        self.bodyPreview = bodyPreview
        self.createdAtMilliseconds = createdAtMilliseconds
    }
}

public enum TandockCheckpointError: LocalizedError, Equatable {
    case emptySnapshot
    case duplicateEvent
    case gitUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptySnapshot: "检查点没有可记录的文件状态"
        case .duplicateEvent: "重复的轮次事件已忽略"
        case .gitUnavailable: "未安装 Git 命令行工具，已跳过检查点"
        }
    }
}

public extension Notification.Name {
    static let tandockCheckpointCreated = Notification.Name("dev.ycode.native.checkpoint-created")
}

public final class TandockCheckpointRepository: @unchecked Sendable {
    private let database: SQLiteConnection

    public init(databaseURL: URL) throws {
        try TandockNativeDatabase.prepare(at: databaseURL)
        database = try SQLiteConnection(path: databaseURL.path)
        try database.execute("PRAGMA foreign_keys=ON")
    }

    public func list(sessionID: String) throws -> [TandockCheckpointRecord] {
        try database.query("""
            SELECT id, session_id, project_id, sequence, commit_sha, ref_name, kind,
                   source, event_kind, body_preview, created_at
            FROM session_checkpoints WHERE session_id=? ORDER BY sequence ASC;
            """, bindings: [.text(sessionID)], map: Self.record)
    }

    public func previous(sessionID: String) throws -> TandockCheckpointRecord? {
        try database.query("""
            SELECT id, session_id, project_id, sequence, commit_sha, ref_name, kind,
                   source, event_kind, body_preview, created_at
            FROM session_checkpoints WHERE session_id=? ORDER BY sequence DESC LIMIT 1;
            """, bindings: [.text(sessionID)], map: Self.record).first
    }

    public func checkpoint(id: String) throws -> TandockCheckpointRecord? {
        try database.query("""
            SELECT id, session_id, project_id, sequence, commit_sha, ref_name, kind,
                   source, event_kind, body_preview, created_at
            FROM session_checkpoints WHERE id=?;
            """, bindings: [.text(id)], map: Self.record).first
    }

    public func insert(
        sessionID: String,
        projectID: String,
        commitSHA: String,
        refName: String,
        kind: String,
        source: String?,
        eventKind: String?,
        bodyPreview: String?,
        keepLimit: Int?
    ) throws -> (record: TandockCheckpointRecord, prunedRefs: [String]) {
        let id = UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        var pruned: [String] = []
        try transaction {
            let duplicate = try duplicateTurn(
                sessionID: sessionID,
                source: source,
                eventKind: eventKind,
                bodyPreview: bodyPreview
            )
            if kind == "turn", duplicate { throw TandockCheckpointError.duplicateEvent }
            let sequence = try database.scalarInt(
                "SELECT COALESCE(MAX(sequence), -1) + 1 FROM session_checkpoints WHERE session_id=\(sqlLiteral(sessionID))"
            )
            try database.execute("""
                INSERT INTO session_checkpoints (
                    id, session_id, project_id, sequence, commit_sha, ref_name,
                    kind, source, event_kind, body_preview, created_at
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, bindings: [
                    .text(id), .text(sessionID), .text(projectID), .integer(Int64(sequence)),
                    .text(commitSHA), .text(refName), .text(kind),
                    source.map(SQLiteBinding.text) ?? .null,
                    eventKind.map(SQLiteBinding.text) ?? .null,
                    bodyPreview.map(SQLiteBinding.text) ?? .null,
                    .integer(now)
                ])
            pruned = try prune(sessionID: sessionID, keepLimit: keepLimit)
        }
        guard let record = try checkpoint(id: id) else { throw ProjectWorkspaceError.sessionNotFound(sessionID) }
        return (record, pruned)
    }

    private func duplicateTurn(sessionID: String, source: String?, eventKind: String?, bodyPreview: String?) throws -> Bool {
        let rows = try database.query("""
            SELECT COUNT(*) FROM session_checkpoints
            WHERE session_id=? AND kind='turn'
              AND COALESCE(source, '')=COALESCE(?, '')
              AND COALESCE(event_kind, '')=COALESCE(?, '')
              AND COALESCE(body_preview, '')=COALESCE(?, '')
            """, bindings: [
                .text(sessionID),
                source.map(SQLiteBinding.text) ?? .null,
                eventKind.map(SQLiteBinding.text) ?? .null,
                bodyPreview.map(SQLiteBinding.text) ?? .null
            ]) { Int(sqliteInt($0, column: 0) ?? 0) }
        return (rows.first ?? 0) > 0
    }

    private func prune(sessionID: String, keepLimit: Int?) throws -> [String] {
        guard let keepLimit else { return [] }
        let keep = max(1, keepLimit)
        let overflow = try database.query("""
            SELECT id, ref_name FROM session_checkpoints
            WHERE session_id=?
            ORDER BY sequence DESC
            LIMIT -1 OFFSET ?;
            """, bindings: [.text(sessionID), .integer(Int64(keep))]) {
                (id: sqliteString($0, column: 0) ?? "", ref: sqliteString($0, column: 1) ?? "")
            }
        guard !overflow.isEmpty else { return [] }
        for row in overflow {
            try database.execute("DELETE FROM session_checkpoints WHERE id=?", bindings: [.text(row.id)])
        }
        return overflow.map(\.ref)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try body()
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private static func record(_ row: OpaquePointer) -> TandockCheckpointRecord {
        TandockCheckpointRecord(
            id: sqliteString(row, column: 0) ?? "",
            sessionID: sqliteString(row, column: 1) ?? "",
            projectID: sqliteString(row, column: 2) ?? "",
            sequence: Int(sqliteInt(row, column: 3) ?? 0),
            commitSHA: sqliteString(row, column: 4) ?? "",
            refName: sqliteString(row, column: 5) ?? "",
            kind: sqliteString(row, column: 6) ?? "",
            source: sqliteString(row, column: 7),
            eventKind: sqliteString(row, column: 8),
            bodyPreview: sqliteString(row, column: 9),
            createdAtMilliseconds: sqliteInt(row, column: 10) ?? 0
        )
    }
}

public struct TandockCheckpointService: Sendable {
    private let repository: TandockCheckpointRepository
    private let git: TandockGitService
    private let keepLimit: Int?
    private let notificationCenter: NotificationCenter

    public init(
        repository: TandockCheckpointRepository,
        git: TandockGitService = TandockGitService(),
        keepLimit: Int? = 50,
        notificationCenter: NotificationCenter = .default
    ) {
        self.repository = repository
        self.git = git
        self.keepLimit = keepLimit
        self.notificationCenter = notificationCenter
    }

    @discardableResult
    public func createInitial(session: SessionMetadata, project: ProjectRecord) throws -> TandockCheckpointRecord {
        try create(kind: "initial", session: session, project: project, event: nil)
    }

    @discardableResult
    public func createTurn(session: SessionMetadata, project: ProjectRecord, event: TandockAgentHookEvent) throws -> TandockCheckpointRecord {
        try create(kind: "turn", session: session, project: project, event: event)
    }

    /// 每个仓库一条串行队列：Git 不进主线程，同一会话的 initial 一定排在 turn 前面，
    /// 同一仓库不会同时跑两个 `git add -A`；别的大仓库排着的快照也不会拖住这一个。
    private static let queuesLock = NSLock()
    private nonisolated(unsafe) static var queues: [String: DispatchQueue] = [:]

    private static func queue(for project: ProjectRecord) -> DispatchQueue {
        let key = project.repositoryURL.standardizedFileURL.path
        queuesLock.lock()
        defer { queuesLock.unlock() }
        if let queue = queues[key] { return queue }
        let queue = DispatchQueue(label: "dev.tandock.checkpoints", qos: .utility)
        queues[key] = queue
        return queue
    }

    /// 后台建 initial 快照，调用方不等。Agent 在用户第一次输入前不会改文件；
    /// 用较高优先级跑，尽量赶在第一次输入之前完成。
    public func enqueueInitial(
        session: SessionMetadata,
        project: ProjectRecord,
        completion: (@Sendable (Result<TandockCheckpointRecord, Error>) -> Void)? = nil
    ) {
        enqueue(project, qos: .userInitiated, completion) { try createInitial(session: session, project: project) }
    }

    public func enqueueTurn(
        session: SessionMetadata,
        project: ProjectRecord,
        event: TandockAgentHookEvent,
        completion: (@Sendable (Result<TandockCheckpointRecord, Error>) -> Void)? = nil
    ) {
        enqueue(project, qos: .utility, completion) { try createTurn(session: session, project: project, event: event) }
    }

    private func enqueue(
        _ project: ProjectRecord,
        qos: DispatchQoS,
        _ completion: (@Sendable (Result<TandockCheckpointRecord, Error>) -> Void)?,
        _ work: @escaping @Sendable () throws -> TandockCheckpointRecord
    ) {
        Self.queue(for: project).async(qos: qos) {
            let result = Result { try work() }
            completion?(result)
        }
    }

    public func list(sessionID: String) throws -> [TandockCheckpointRecord] {
        try repository.list(sessionID: sessionID)
    }

    public func diff(root: URL, from previous: TandockCheckpointRecord?, to checkpoint: TandockCheckpointRecord) throws -> String {
        try git.diffTree(root: root, oldCommit: previous?.commitSHA, newCommit: checkpoint.commitSHA)
    }

    private func create(kind: String, session: SessionMetadata, project: ProjectRecord, event: TandockAgentHookEvent?) throws -> TandockCheckpointRecord {
        guard git.isUsable else { throw TandockCheckpointError.gitUnavailable }
        let refName = "refs/tandock/checkpoints/\(session.id)/\(UUID().uuidString.lowercased())"
        let commit = try git.createSnapshotCommit(
            root: project.repositoryURL,
            message: "Tandock checkpoint \(kind) \(session.id)",
            refName: refName
        )
        let inserted: (record: TandockCheckpointRecord, prunedRefs: [String])
        do {
            inserted = try repository.insert(
                sessionID: session.id,
                projectID: project.id,
                commitSHA: commit,
                refName: refName,
                kind: kind,
                source: event?.source,
                eventKind: event?.eventKind,
                bodyPreview: event?.bodyPreview,
                keepLimit: keepLimit
            )
        } catch {
            try? git.deleteRef(root: project.repositoryURL, refName: refName)
            throw error
        }
        for ref in inserted.prunedRefs {
            try? git.deleteRef(root: project.repositoryURL, refName: ref)
        }
        notificationCenter.post(name: .tandockCheckpointCreated, object: inserted.record)
        return inserted.record
    }
}
