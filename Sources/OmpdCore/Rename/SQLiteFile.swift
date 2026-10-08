import Foundation
import SQLite3

/// Just enough of SQLite to rewrite rows of omp's databases (`history.db`, `composer.db`) while omps have them open:
/// a busy timeout so their locks are waited out, statements with text parameters, one transaction.
final class SQLiteFile {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?
    private let path: String

    /// Opens an existing database for writing; nil when there is none at `path`.
    init?(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        self.path = path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            handle = nil
            throw Failure(description: message)
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func hasTable(_ name: String) throws -> Bool {
        try rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1", [name]).isEmpty == false
    }

    /// Runs `body` in one write transaction (`BEGIN IMMEDIATE`), rolled back when it throws.
    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE", [])
        do {
            try body()
            try run("COMMIT", [])
        } catch {
            try? run("ROLLBACK", [])
            throw error
        }
    }

    func run(_ sql: String, _ parameters: [String]) throws {
        _ = try rows(sql, parameters)
    }

    /// The first column of every row `sql` returns, as text.
    func rows(_ sql: String, _ parameters: [String]) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), parameter, -1, transient) == SQLITE_OK else { throw failure() }
        }
        var values: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text)) }
            case SQLITE_DONE:
                return values
            default:
                throw failure()
            }
        }
    }

    private func failure() -> Failure {
        Failure(description: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite failed on \(path)")
    }
}
