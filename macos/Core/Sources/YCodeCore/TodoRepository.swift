import Foundation

public enum YCodeTodoStatus: String, CaseIterable, Codable, Sendable {
    case todo
    case doing
    case done
}

public struct YCodeTodo: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let title: String
    public let status: YCodeTodoStatus
    public let sortOrder: Int64
    public let startedAtMilliseconds: Int64?
    public let doneAtMilliseconds: Int64?
    public let createdAtMilliseconds: Int64
    public let updatedAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, status
        case projectID = "project_id"
        case sortOrder = "sort_order"
        case startedAtMilliseconds = "started_at_ms"
        case doneAtMilliseconds = "done_at_ms"
        case createdAtMilliseconds = "created_at_ms"
        case updatedAtMilliseconds = "updated_at_ms"
    }
}

public enum YCodeTodoError: LocalizedError, Equatable {
    case projectNotFound(String)
    case todoNotFound(String)
    case emptyTitle
    case invalidStatus(String)
    case invalidOrder
    case projectCannotBeResolved

    public var errorDescription: String? {
        switch self {
        case let .projectNotFound(id): "找不到项目：\(id)"
        case let .todoNotFound(id): "找不到待办：\(id)"
        case .emptyTitle: "待办标题不能为空"
        case let .invalidStatus(status): "无效待办状态：\(status)"
        case .invalidOrder: "排序必须包含当前项目的全部待办且不能重复"
        case .projectCannotBeResolved: "无法从当前终端或工作目录确定项目"
        }
    }
}

public extension Notification.Name {
    static let ycodeTodosChanged = Notification.Name("dev.ycode.native.todos.changed")
}

/// Synchronous SQLite repository shared by the app and the standalone MCP helper.
/// Every multi-step write uses `BEGIN IMMEDIATE` so concurrent helper/UI writes serialize.
public final class YCodeTodoRepository: @unchecked Sendable {
    private let database: SQLiteConnection
    private let lock = NSRecursiveLock()

    public init(databaseURL: URL) throws {
        try YCodeNativeDatabase.prepare(at: databaseURL)
        database = try SQLiteConnection(path: databaseURL.path)
        try database.execute("PRAGMA foreign_keys=ON")
        try database.execute("PRAGMA journal_mode=WAL")
    }

    public func list(projectID: String) throws -> [YCodeTodo] {
        try locked {
            guard try projectExists(projectID) else { throw YCodeTodoError.projectNotFound(projectID) }
            return try database.query("""
                SELECT id,project_id,title,status,sort_order,started_at,done_at,created_at,updated_at
                FROM project_todos WHERE project_id=? ORDER BY sort_order ASC, created_at ASC, id ASC
                """, bindings: [.text(projectID)], map: Self.todo)
        }
    }

    @discardableResult
    public func create(projectID: String, title: String) throws -> YCodeTodo {
        let title = try validatedTitle(title)
        let result = try transaction {
            guard try projectExists(projectID) else { throw YCodeTodoError.projectNotFound(projectID) }
            let next = try database.scalarInt(
                "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM project_todos WHERE project_id=\(sqlLiteral(projectID))"
            )
            let id = UUID().uuidString.lowercased()
            let now = Self.nowMilliseconds()
            try database.execute("""
                INSERT INTO project_todos
                (id,project_id,title,status,sort_order,started_at,done_at,created_at,updated_at)
                VALUES (?,?,?,'todo',?,NULL,NULL,?,?)
                """, bindings: [
                    .text(id), .text(projectID), .text(title), .integer(Int64(next)),
                    .integer(now), .integer(now)
                ])
            return try todo(id: id)
        }
        notify(projectID: projectID)
        return result
    }

    @discardableResult
    public func update(
        id: String,
        title: String? = nil,
        status: YCodeTodoStatus? = nil
    ) throws -> YCodeTodo {
        let title = try title.map(validatedTitle)
        guard title != nil || status != nil else { return try todo(id: id) }
        let result = try transaction {
            let current = try todo(id: id)
            let now = Self.nowMilliseconds()
            let resolvedTitle = title ?? current.title
            let resolvedStatus = status ?? current.status
            var started = current.startedAtMilliseconds
            var done = current.doneAtMilliseconds
            if let status, status != current.status {
                if status == .doing { started = now }
                if status == .done { done = now }
            }
            try database.execute("""
                UPDATE project_todos
                SET title=?,status=?,started_at=?,done_at=?,updated_at=? WHERE id=?
                """, bindings: [
                    .text(resolvedTitle), .text(resolvedStatus.rawValue),
                    started.map(SQLiteBinding.integer) ?? .null,
                    done.map(SQLiteBinding.integer) ?? .null,
                    .integer(now), .text(id)
                ])
            return try todo(id: id)
        }
        notify(projectID: result.projectID)
        return result
    }

    /// String entrypoint used at process/protocol boundaries so invalid values return a typed error.
    @discardableResult
    public func update(id: String, title: String? = nil, statusRaw: String?) throws -> YCodeTodo {
        let status: YCodeTodoStatus?
        if let statusRaw {
            guard let parsed = YCodeTodoStatus(rawValue: statusRaw) else {
                throw YCodeTodoError.invalidStatus(statusRaw)
            }
            status = parsed
        } else {
            status = nil
        }
        return try update(id: id, title: title, status: status)
    }

    public func delete(id: String) throws {
        let projectID = try transaction {
            let current = try todo(id: id)
            guard try database.execute("DELETE FROM project_todos WHERE id=?", bindings: [.text(id)]) == 1 else {
                throw YCodeTodoError.todoNotFound(id)
            }
            return current.projectID
        }
        notify(projectID: projectID)
    }

    public func reorder(projectID: String, orderedIDs: [String]) throws {
        try transaction {
            guard try projectExists(projectID) else { throw YCodeTodoError.projectNotFound(projectID) }
            let current = try database.query(
                "SELECT id FROM project_todos WHERE project_id=?",
                bindings: [.text(projectID)]
            ) { sqliteString($0, column: 0) ?? "" }
            guard current.count == orderedIDs.count,
                  Set(current) == Set(orderedIDs),
                  Set(orderedIDs).count == orderedIDs.count else { throw YCodeTodoError.invalidOrder }
            for (index, id) in orderedIDs.enumerated() {
                try database.execute(
                    "UPDATE project_todos SET sort_order=? WHERE id=? AND project_id=?",
                    bindings: [.integer(Int64(index)), .text(id), .text(projectID)]
                )
            }
        }
        notify(projectID: projectID)
    }

    public func resolveProjectID(terminalID: String?, cwd: URL?) throws -> String {
        try locked {
            if let terminalID, !terminalID.isEmpty,
               let projectID = try database.query(
                    "SELECT project_id FROM sessions WHERE id=? LIMIT 1",
                    bindings: [.text(terminalID)],
                    map: { sqliteString($0, column: 0) ?? "" }
               ).first, !projectID.isEmpty {
                return projectID
            }
            if let cwd {
                let canonical = cwd.standardizedFileURL.resolvingSymlinksInPath().path
                if let projectID = try database.query(
                    "SELECT id FROM projects WHERE repo_path=? LIMIT 1",
                    bindings: [.text(canonical)],
                    map: { sqliteString($0, column: 0) ?? "" }
                ).first, !projectID.isEmpty {
                    return projectID
                }
                if let projectID = try database.query(
                    "SELECT project_id FROM sessions WHERE worktree_path=? LIMIT 1",
                    bindings: [.text(canonical)],
                    map: { sqliteString($0, column: 0) ?? "" }
                ).first, !projectID.isEmpty {
                    return projectID
                }
            }
            throw YCodeTodoError.projectCannotBeResolved
        }
    }

    private func todo(id: String) throws -> YCodeTodo {
        guard let value = try database.query("""
            SELECT id,project_id,title,status,sort_order,started_at,done_at,created_at,updated_at
            FROM project_todos WHERE id=? LIMIT 1
            """, bindings: [.text(id)], map: Self.todo).first else {
            throw YCodeTodoError.todoNotFound(id)
        }
        return value
    }

    private func projectExists(_ id: String) throws -> Bool {
        try database.scalarInt("SELECT COUNT(*) FROM projects WHERE id=\(sqlLiteral(id))") == 1
    }

    private func validatedTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw YCodeTodoError.emptyTitle }
        return trimmed
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try database.execute("BEGIN IMMEDIATE")
            do {
                let value = try body()
                try database.execute("COMMIT")
                return value
            } catch {
                try? database.execute("ROLLBACK")
                throw error
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func notify(projectID: String) {
        DistributedNotificationCenter.default().postNotificationName(
            .ycodeTodosChanged,
            object: nil,
            userInfo: ["projectID": projectID],
            deliverImmediately: true
        )
    }

    private static func todo(_ row: OpaquePointer) throws -> YCodeTodo {
        let statusRaw = sqliteString(row, column: 3) ?? ""
        guard let status = YCodeTodoStatus(rawValue: statusRaw) else { throw YCodeTodoError.invalidStatus(statusRaw) }
        return YCodeTodo(
            id: sqliteString(row, column: 0) ?? "",
            projectID: sqliteString(row, column: 1) ?? "",
            title: sqliteString(row, column: 2) ?? "",
            status: status,
            sortOrder: sqliteInt(row, column: 4) ?? 0,
            startedAtMilliseconds: sqliteInt(row, column: 5),
            doneAtMilliseconds: sqliteInt(row, column: 6),
            createdAtMilliseconds: sqliteInt(row, column: 7) ?? 0,
            updatedAtMilliseconds: sqliteInt(row, column: 8) ?? 0
        )
    }

    private static func nowMilliseconds() -> Int64 { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }
}
