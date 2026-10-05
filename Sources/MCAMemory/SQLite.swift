import Foundation
import SQLite3

/// Minimal SQLite3 wrapper.
///
/// Deliberately dependency-free. The obvious alternative, GRDB, would drag in a
/// custom SQLite build to make extension loading work; we avoid needing that at
/// all by keeping vector search in Swift (see `VectorIndex`) and using only
/// FTS5, which the system SQLite already ships.
final class SQLiteDatabase {
    enum DBError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)

        var description: String {
            switch self {
            case .open(let m): return "SQLite open failed: \(m)"
            case .prepare(let m, let sql): return "SQLite prepare failed: \(m)\nSQL: \(sql)"
            case .step(let m, let sql): return "SQLite step failed: \(m)\nSQL: \(sql)"
            }
        }
    }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DBError.open(message)
        }
        // WAL keeps readers from blocking the ingest path, which matters
        // because capture is continuous while queries are bursty.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw DBError.step(message, sql: sql)
        }
    }

    enum Value {
        case text(String)
        case int(Int64)
        case double(Double)
        case blob(Data)
        case null
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ parameters: [Value] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DBError.step(errorMessage, sql: sql)
        }
    }

    /// Runs a query, mapping each row.
    func query<T>(_ sql: String, _ parameters: [Value] = [], row: (Row) -> T) throws -> [T] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var results: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                results.append(row(Row(statement: statement)))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw DBError.step(errorMessage, sql: sql)
            }
        }
        return results
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DBError.prepare(errorMessage, sql: sql)
        }
        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            switch parameter {
            case .text(let string):
                sqlite3_bind_text(statement, position, string, -1, Self.transient)
            case .int(let value):
                sqlite3_bind_int64(statement, position, value)
            case .double(let value):
                sqlite3_bind_double(statement, position, value)
            case .blob(let data):
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement, position, bytes.baseAddress,
                        Int32(data.count), Self.transient)
                }
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    struct Row {
        let statement: OpaquePointer?

        func string(_ index: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: pointer)
        }

        func optionalString(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return string(index)
        }

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

        func blob(_ index: Int32) -> Data {
            guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
            let count = Int(sqlite3_column_bytes(statement, index))
            return Data(bytes: pointer, count: count)
        }
    }

    /// Whether this build of SQLite has FTS5. Checked at startup so a missing
    /// module is reported clearly instead of failing on the first search.
    static func hasFTS5(path: String = ":memory:") -> Bool {
        guard let db = try? SQLiteDatabase(path: path) else { return false }
        return (try? db.execute("CREATE VIRTUAL TABLE fts5_probe USING fts5(x)")) != nil
    }
}
