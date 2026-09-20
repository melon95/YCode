import CSQLite
import Foundation

final class SQLiteConnection {
    private(set) var handle: OpaquePointer?
    let path: String

    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let handle { sqlite3_close(handle) }
            self.handle = nil
            throw YCodeMigrationError.sqlite(message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite error \(result)"
            if let error { sqlite3_free(error) }
            throw YCodeMigrationError.sqlite(message)
        }
    }

    @discardableResult
    func execute(_ sql: String, bindings: [SQLiteBinding]) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let statement else { throw currentError() }
                rows.append(try map(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw currentError()
            }
        }
    }

    func scalarString(_ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw currentError() }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    func scalarInt(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func tableExists(_ name: String) throws -> Bool {
        try scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=\(sqlLiteral(name))") > 0
    }

    func columns(in table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(sqlLiteral(table)))"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1) {
                result.insert(String(cString: value))
            }
        }
        return result
    }

    func backup(to destinationPath: String) throws {
        let destination = try SQLiteConnection(path: destinationPath)
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw destination.currentError()
        }
        var result: Int32 = SQLITE_OK
        repeat {
            result = sqlite3_backup_step(backup, -1)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { sqlite3_sleep(10) }
        } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw destination.currentError()
        }
    }

    private func currentError() -> YCodeMigrationError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite handle unavailable"
        return .sqlite(message)
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value):
                result = value.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
                }
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case let .blob(value):
                if value.isEmpty {
                    result = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    result = value.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                    }
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw currentError() }
        }
    }
}

enum SQLiteBinding {
    case text(String)
    case integer(Int64)
    case blob(Data)
    case null
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func sqliteString(_ statement: OpaquePointer, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
          let value = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: value)
}

func sqliteInt(_ statement: OpaquePointer, column: Int32) -> Int64? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return Int64(sqlite3_column_int64(statement, column))
}

func sqliteData(_ statement: OpaquePointer, column: Int32) -> Data? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: count)
}

func sqlLiteral(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}
