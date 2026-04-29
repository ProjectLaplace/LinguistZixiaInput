import Foundation
import SQLite3

/// User dictionary for storing learned phrases.
/// Persists to ~/Library/Application Support/LaplaceIME/user_dict.db.
/// Only stores multi-character words; no frequency ranking.
public class UserDictionary {
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var queryStmt: OpaquePointer?
    private var prefixStmt: OpaquePointer?
    private var existsStmt: OpaquePointer?

    /// Initialize with a specific database path (for testing).
    public init?(path: String) {
        guard openAndSetup(path: path) else { return nil }
    }

    /// Initialize with the default user dictionary location.
    public init?() {
        guard let dir = UserDictionary.defaultDirectory() else { return nil }
        let path = (dir as NSString).appendingPathComponent("user_dict.db")
        guard openAndSetup(path: path) else { return nil }
    }

    deinit {
        if let insertStmt = insertStmt { sqlite3_finalize(insertStmt) }
        if let queryStmt = queryStmt { sqlite3_finalize(queryStmt) }
        if let prefixStmt = prefixStmt { sqlite3_finalize(prefixStmt) }
        if let existsStmt = existsStmt { sqlite3_finalize(existsStmt) }
        if let db = db {
            // 触发 ANALYZE 并把统计信息写入 sqlite_stat1 系统表（持久化于 DB 文件）。
            // 下次进程启动时，SQLite query planner 在 prepare 阶段会自动读取这些
            // 统计信息并据此选择执行计划，应用层无需任何代码改动。
            sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(db)
        }
    }

    // MARK: - Setup

    private func openAndSetup(path: String) -> Bool {
        // Ensure parent directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }

        // 性能调优 PRAGMA：page_size 必须先于任何 schema 创建；其余为 runtime 设定
        sqlite3_exec(db, "PRAGMA page_size = 8192;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -20000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456;", nil, nil, nil)

        let createSQL = """
            CREATE TABLE IF NOT EXISTS user_entries (
                pinyin TEXT NOT NULL,
                word TEXT NOT NULL,
                UNIQUE(pinyin, word)
            )
            """
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return false
        }

        // Create index if not exists
        sqlite3_exec(
            db, "CREATE INDEX IF NOT EXISTS idx_user_pinyin ON user_entries(pinyin)", nil, nil, nil)

        // Prepare statements
        let insertSQL = "INSERT OR IGNORE INTO user_entries (pinyin, word) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            return false
        }

        let querySQL = "SELECT word FROM user_entries WHERE pinyin = ?"
        guard sqlite3_prepare_v2(db, querySQL, -1, &queryStmt, nil) == SQLITE_OK else {
            return false
        }

        let prefixSQL = "SELECT word FROM user_entries WHERE pinyin >= ? AND pinyin < ? LIMIT ?"
        guard sqlite3_prepare_v2(db, prefixSQL, -1, &prefixStmt, nil) == SQLITE_OK else {
            return false
        }

        let existsSQL = "SELECT 1 FROM user_entries WHERE pinyin = ? AND word = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, existsSQL, -1, &existsStmt, nil) == SQLITE_OK else {
            return false
        }

        return true
    }

    private static func defaultDirectory() -> String? {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            return nil
        }
        return appSupport.appendingPathComponent("LaplaceIME").path
    }

    // MARK: - Write

    /// Save a multi-character word to the user dictionary.
    /// Single characters are ignored.
    public func save(pinyin: String, word: String) {
        guard word.count > 1, !pinyin.isEmpty else { return }
        guard let stmt = insertStmt else { return }

        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, pinyin, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, word, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    // MARK: - Read

    /// Look up words for an exact pinyin match.
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

    /// Look up words whose pinyin starts with the given prefix.
    public func candidatesWithPrefix(_ prefix: String, limit: Int = 9) -> [String] {
        guard let stmt = prefixStmt, !prefix.isEmpty else { return [] }

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
