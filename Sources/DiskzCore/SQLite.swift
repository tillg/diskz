import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Statement {
    let handle: OpaquePointer
    private let db: OpaquePointer

    init(db: OpaquePointer, sql: String) throws {
        var h: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &h, nil) == SQLITE_OK, let h else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(db)) + " in: " + sql)
        }
        handle = h
        self.db = db
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ args: [Any?]) {
        sqlite3_reset(handle)
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(handle, n)
            case let v as Int64: sqlite3_bind_int64(handle, n, v)
            case let v as Int: sqlite3_bind_int64(handle, n, Int64(v))
            case let v as Bool: sqlite3_bind_int64(handle, n, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(handle, n, v)
            case let v as String: sqlite3_bind_text(handle, n, v, -1, transient)
            default: preconditionFailure("unsupported SQLite argument \(String(describing: arg))")
            }
        }
    }

    /// Returns true while there is a row.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(description: String(cString: sqlite3_errmsg(db)))
        }
    }

    func run(_ args: [Any?] = []) throws {
        bind(args)
        _ = try step()
        sqlite3_reset(handle)
    }

    func int(_ col: Int32) -> Int64 { sqlite3_column_int64(handle, col) }
    func double(_ col: Int32) -> Double { sqlite3_column_double(handle, col) }
    func text(_ col: Int32) -> String { String(cString: sqlite3_column_text(handle, col)) }
    func isNull(_ col: Int32) -> Bool { sqlite3_column_type(handle, col) == SQLITE_NULL }
}

final class Database {
    let handle: OpaquePointer

    init(path: String) throws {
        var h: OpaquePointer?
        guard sqlite3_open(path, &h) == SQLITE_OK, let h else {
            throw SQLiteError(description: "cannot open database at \(path)")
        }
        handle = h
        sqlite3_busy_timeout(h, 10_000) // the app and the CLI may use the same database
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)) + " in: " + sql)
        }
    }

    func prepare(_ sql: String) throws -> Statement { try Statement(db: handle, sql: sql) }

    func run(_ sql: String, _ args: [Any?] = []) throws { try prepare(sql).run(args) }

    func query<T>(_ sql: String, _ args: [Any?] = [], _ row: (Statement) -> T) throws -> [T] {
        let s = try prepare(sql)
        s.bind(args)
        var out: [T] = []
        while try s.step() { out.append(row(s)) }
        return out
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
