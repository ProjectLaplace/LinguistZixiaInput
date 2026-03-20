import Foundation
import SQLite3

/// SQLite-backed dictionary store for pinyin lookups.
/// Replaces the in-memory JSON dictionary with indexed database queries.
public class DictionaryStore {
    private var db: OpaquePointer?
    private var queryStmt: OpaquePointer?

    /// Open a SQLite dictionary database at the given file path.
    /// - Parameter path: Absolute path to the .db file
    public init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }

        let sql = "SELECT word FROM entries WHERE pinyin = ? ORDER BY frequency DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &queryStmt, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit {
        if let queryStmt = queryStmt {
            sqlite3_finalize(queryStmt)
        }
        if let db = db {
            sqlite3_close(db)
        }
    }

    /// Look up candidate words for a given pinyin string.
    /// - Parameter pinyin: The pinyin key (e.g. "shi", "shijian")
    /// - Returns: Array of candidate words, ordered by frequency descending
    public func candidates(for pinyin: String) -> [String] {
        guard let stmt = queryStmt else { return [] }

        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, pinyin, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: cStr))
            }
        }
        return results
    }
}
