import Foundation
import SQLite3

nonisolated enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// A single connection confined to its owning actor. Never pass it between executors.
/// Errors contain SQLite result codes only, never SQL, paths, or indexed content.
nonisolated final class SQLiteConnection {
    private var database: OpaquePointer?
    private var isInTransaction = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw PhotoIndexError.invalidInput }
        try Task.checkCancellation()
        try PhotoIndexLocation.validateDatabase(at: url)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_FILEPROTECTION_COMPLETE
        let result = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw PhotoIndexError.storage(result)
        }
        database = opened
        do {
            try check(sqlite3_busy_timeout(opened, 2_000))
            try execute("PRAGMA foreign_keys = ON")
            let journal = try query("PRAGMA journal_mode = DELETE")
            guard journal == [[.text("delete")]] else { throw PhotoIndexError.invalidDatabase }
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA temp_store = MEMORY")
            try execute("PRAGMA secure_delete = ON")
            try PhotoIndexLocation.protectDatabase(at: url)
        } catch {
            sqlite3_close_v2(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    /// Executes one statement. Use separate calls inside a transaction for schema batches.
    func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        try run(sql, bindings, collectRows: false, checkCancellation: true)
    }

    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        try run(sql, bindings, collectRows: true, checkCancellation: true)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard !isInTransaction else { throw PhotoIndexError.invalidTransition }
        try Task.checkCancellation()
        try execute("BEGIN IMMEDIATE")
        isInTransaction = true
        defer { isInTransaction = false }
        do {
            let result = try body()
            try Task.checkCancellation()
            try execute("COMMIT")
            return result
        } catch {
            // Cancellation must not prevent the rollback that discards the partial work.
            _ = try? run("ROLLBACK", [], collectRows: false, checkCancellation: false)
            throw error
        }
    }

    func close() throws {
        guard let database else { return }
        guard !isInTransaction else { throw PhotoIndexError.invalidTransition }
        try check(sqlite3_close(database))
        self.database = nil
    }

    @discardableResult
    private func run(_ sql: String, _ bindings: [SQLiteValue], collectRows: Bool,
                     checkCancellation: Bool) throws -> [[SQLiteValue]] {
        guard let database else { throw PhotoIndexError.closed }
        if checkCancellation { try Task.checkCancellation() }
        guard !sql.utf8.contains(0), sql.utf8.count < Int(Int32.max) else {
            throw PhotoIndexError.invalidInput
        }
        var statement: OpaquePointer?
        let code = try sql.withCString { characters in
            var tail: UnsafePointer<CChar>?
            let result = sqlite3_prepare_v2(database, characters, -1, &statement, &tail)
            if result == SQLITE_OK, let tail,
               !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let statement { sqlite3_finalize(statement) }
                statement = nil
                throw PhotoIndexError.invalidInput
            }
            return result
        }
        guard code == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            if code == SQLITE_OK { throw PhotoIndexError.invalidInput }
            throw PhotoIndexError.storage(code)
        }
        defer { sqlite3_finalize(statement) }
        guard Int(sqlite3_bind_parameter_count(statement)) == bindings.count else {
            throw PhotoIndexError.invalidInput
        }
        for (offset, value) in bindings.enumerated() {
            try bind(value, at: Int32(offset + 1), to: statement)
        }
        var rows: [[SQLiteValue]] = []
        while true {
            if checkCancellation { try Task.checkCancellation() }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw PhotoIndexError.storage(result) }
            if collectRows {
                rows.append(try (0..<sqlite3_column_count(statement)).map {
                    try value(at: $0, from: statement)
                })
            }
        }
    }

    private func bind(_ value: SQLiteValue, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        switch value {
        case .null:
            result = sqlite3_bind_null(statement, index)
        case .integer(let value):
            result = sqlite3_bind_int64(statement, index, value)
        case .real(let value):
            result = sqlite3_bind_double(statement, index, value)
        case .text(let value):
            let count = value.utf8.count
            guard count <= Int(Int32.max) else { throw PhotoIndexError.invalidInput }
            // An explicit length preserves embedded NUL characters in private OCR text.
            result = value.withCString {
                sqlite3_bind_text(statement, index, $0, Int32(count), Self.transient)
            }
        case .blob(let value):
            guard value.count <= Int(Int32.max) else { throw PhotoIndexError.invalidInput }
            if value.isEmpty {
                // A nil pointer passed to bind_blob means NULL, not a zero-length BLOB.
                result = sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transient)
                }
            }
        }
        try check(result)
    }

    private func value(at index: Int32, from statement: OpaquePointer) throws -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            let pointer = sqlite3_column_text(statement, index)
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let pointer else { throw PhotoIndexError.invalidStoredData }
            guard let text = String(bytes: UnsafeBufferPointer(start: pointer, count: count),
                                    encoding: .utf8) else { throw PhotoIndexError.invalidStoredData }
            return .text(text)
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0 else { return .blob(Data()) }
            guard let pointer = sqlite3_column_blob(statement, index) else {
                throw PhotoIndexError.invalidStoredData
            }
            return .blob(Data(bytes: pointer, count: count))
        default:
            throw PhotoIndexError.invalidStoredData
        }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw PhotoIndexError.storage(result) }
    }
}
