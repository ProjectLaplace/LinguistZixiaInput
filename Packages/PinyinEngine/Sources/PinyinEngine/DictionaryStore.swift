import Foundation
import SQLite3

/// SQLite-backed dictionary store for pinyin lookups.
/// Replaces the in-memory JSON dictionary with indexed database queries.
public class DictionaryStore {
    private var db: OpaquePointer?
    private var queryStmt: OpaquePointer?
    private var prefixStmt: OpaquePointer?
    private var topStmt: OpaquePointer?

    /// Open a SQLite dictionary database at the given file path.
    /// - Parameter path: Absolute path to the .db file
    public init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }

        // 性能调优 PRAGMA：仅适用于只读 zh_dict 单进程访问场景，失败时回退默认行为
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -20000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA locking_mode = EXCLUSIVE;", nil, nil, nil)

        let sql = "SELECT word FROM entries WHERE pinyin = ? ORDER BY frequency DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &queryStmt, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }

        // Range query for prefix matching: uses index efficiently
        let prefixSql =
            "SELECT word FROM entries WHERE pinyin >= ? AND pinyin < ? ORDER BY frequency DESC LIMIT ?"
        if sqlite3_prepare_v2(db, prefixSql, -1, &prefixStmt, nil) != SQLITE_OK {
            prefixStmt = nil
        }

        // Top candidate with frequency
        let topSql =
            "SELECT word, frequency FROM entries WHERE pinyin = ? ORDER BY frequency DESC LIMIT 1"
        if sqlite3_prepare_v2(db, topSql, -1, &topStmt, nil) != SQLITE_OK {
            topStmt = nil
        }
    }

    deinit {
        if let queryStmt = queryStmt { sqlite3_finalize(queryStmt) }
        if let prefixStmt = prefixStmt { sqlite3_finalize(prefixStmt) }
        if let topStmt = topStmt { sqlite3_finalize(topStmt) }
        if let db = db { sqlite3_close(db) }
    }

    /// Look up candidate words for an exact pinyin string.
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

    /// Look up the top candidate with its frequency for exact pinyin match.
    /// - Parameter pinyin: The pinyin key
    /// - Returns: (word, frequency) tuple, or nil if no match
    public func topCandidate(for pinyin: String) -> (word: String, frequency: Int)? {
        guard let stmt = topStmt else { return nil }

        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, pinyin, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW,
            let cStr = sqlite3_column_text(stmt, 0)
        else { return nil }

        let word = String(cString: cStr)
        let frequency = Int(sqlite3_column_int64(stmt, 1))
        return (word, frequency)
    }

    /// Look up all candidates with frequencies for an exact pinyin match.
    /// - Parameter pinyin: The pinyin key
    /// - Returns: Array of (word, frequency) tuples, ordered by frequency descending
    public func candidatesWithFrequency(for pinyin: String) -> [(word: String, frequency: Int)] {
        guard let db = db else { return [] }

        var stmt: OpaquePointer?
        let sql = "SELECT word, frequency FROM entries WHERE pinyin = ? ORDER BY frequency DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, pinyin, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [(word: String, frequency: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let word = String(cString: cStr)
                let frequency = Int(sqlite3_column_int64(stmt, 1))
                results.append((word, frequency))
            }
        }
        return results
    }

    /// Look up candidate words whose pinyin starts with the given prefix.
    /// Uses range query (>= prefix, < prefix+1) to leverage the B-tree index.
    /// - Parameters:
    ///   - prefix: The pinyin prefix (e.g. "xiangf" matches "xiangfa", "xiangfan", etc.)
    ///   - limit: Maximum number of results (default 9)
    /// - Returns: Array of candidate words, ordered by frequency descending
    public func candidatesWithPrefix(_ prefix: String, limit: Int = 9) -> [String] {
        guard let stmt = prefixStmt, !prefix.isEmpty else { return [] }

        // Compute the upper bound: increment the last character
        var upper = prefix
        let lastChar = upper.removeLast()
        upper.append(Character(UnicodeScalar(lastChar.asciiValue! + 1)))

        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, prefix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, upper, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: cStr))
            }
        }
        return results
    }
}
