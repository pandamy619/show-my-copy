import Foundation
import SQLite3

/// Whether a SQLite database file is intact, asked of SQLite itself with `PRAGMA quick_check`.
///
/// `HistoryStoreOpener` asks this when the store would not open, so that only a database SQLite finds damaged counts
/// towards moving the store aside. A database that is intact but would not open (another build's schema, a full
/// disk, a second copy of the app holding it) is left where it is, since nothing is wrong with it.
enum SQLiteIntegrity: Equatable, Sendable {
    case intact
    /// SQLite read the file and found it damaged, or it is not a database it can read.
    case damaged
    /// Could not be checked now: the file is locked by another process or cannot be opened.
    case unknown

    /// Runs `PRAGMA quick_check(1)` on the database at `url`. Reads the whole file: call it only when the store
    /// did not open, never on every launch.
    static func quickCheck(_ url: URL) -> SQLiteIntegrity {
        var database: OpaquePointer?
        // Read-write without create: the check writes nothing, but a database with a write-ahead log cannot be read
        // in read-only mode without its shared memory file.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let opened = sqlite3_open_v2(url.path(percentEncoded: false), &database, flags, nil)
        guard opened == SQLITE_OK, let database else {
            sqlite3_close(database)
            return classify(opened)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check(1)", -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            return classify(sqlite3_extended_errcode(database))
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            return classify(step)
        }
        guard let text = sqlite3_column_text(statement, 0) else {
            return .damaged
        }
        return String(cString: text) == "ok" ? .intact : .damaged
    }

    /// Only SQLite's own verdicts on the file count as damage; a lock or an I/O problem may pass.
    private static func classify(_ code: Int32) -> SQLiteIntegrity {
        switch code & 0xFF {
        case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_FORMAT:
            .damaged
        default:
            .unknown
        }
    }
}
