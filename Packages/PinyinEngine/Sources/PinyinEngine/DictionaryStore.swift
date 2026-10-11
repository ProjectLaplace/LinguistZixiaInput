import Foundation
import SQLite3

/// SQLite-backed dictionary store for pinyin lookups.
/// Replaces the in-memory JSON dictionary with indexed database queries.
public class DictionaryStore {
    private var db: OpaquePointer?
    private var queryStmt: OpaquePointer?
    private var prefixStmt: OpaquePointer?
    private var topStmt: OpaquePointer?
    private var rangeExistsStmt: OpaquePointer?

    /// 查询开销的累计计数，供性能测量读取。
    public struct QueryStats: Equatable {
        /// 执行的 SQL 语句次数
        public var statements = 0
        /// SQLite 虚拟机执行步数（`SQLITE_STMTSTATUS_VM_STEP`），反映查询实际扫描与排序的工作量
        public var vmSteps = 0

        public init() {}
    }

    /// 自创建或上次 `resetStats()` 以来的累计查询开销
    public private(set) var stats = QueryStats()

    /// 精确查询与前缀存在性检查的结果缓存（含未命中）。词库只读，缓存无需失效；
    /// 逐键组词时同一拼音会在相邻按键间反复查询，命中缓存即不再执行 SQL。
    private var topCandidateCache: LookupCache<String, TopCandidate?>
    private var prefixCache: LookupCache<String, Bool>

    /// 两个缓存当前保存的条目数，供测试检查上限
    var cachedLookupCount: Int { topCandidateCache.count + prefixCache.count }

    private typealias TopCandidate = (word: String, frequency: Int)

    /// 每个缓存每一代的默认容量。缓存最多保存两代，即每个缓存至多 8192 条，
    /// 两个缓存合计约 1 MB 量级。
    public static let defaultLookupCacheCapacity = 4096

    /// Open a SQLite dictionary database at the given file path.
    /// - Parameters:
    ///   - path: Absolute path to the .db file
    ///   - lookupCacheCapacity: 查询结果缓存每一代的容量
    public init?(path: String, lookupCacheCapacity: Int = defaultLookupCacheCapacity) {
        topCandidateCache = LookupCache(capacity: lookupCacheCapacity)
        prefixCache = LookupCache(capacity: lookupCacheCapacity)

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

        // 区间内是否存在条目：前缀剪枝用，只需索引定位一次
        let rangeExistsSql = "SELECT 1 FROM entries WHERE pinyin >= ? AND pinyin < ? LIMIT 1"
        if sqlite3_prepare_v2(db, rangeExistsSql, -1, &rangeExistsStmt, nil) != SQLITE_OK {
            rangeExistsStmt = nil
        }
    }

    deinit {
        if let queryStmt = queryStmt { sqlite3_finalize(queryStmt) }
        if let prefixStmt = prefixStmt { sqlite3_finalize(prefixStmt) }
        if let topStmt = topStmt { sqlite3_finalize(topStmt) }
        if let rangeExistsStmt = rangeExistsStmt { sqlite3_finalize(rangeExistsStmt) }
        if let db = db { sqlite3_close(db) }
    }

    /// 清零累计查询开销
    public func resetStats() {
        stats = QueryStats()
    }

    /// 记录一次语句执行的开销。读取 VM 步数时同时清零该语句的计数器，
    /// 使复用的预编译语句每次只计入本次执行。
    private func recordExecution(of stmt: OpaquePointer) {
        stats.statements += 1
        stats.vmSteps += Int(sqlite3_stmt_status(stmt, SQLITE_STMTSTATUS_VM_STEP, 1))
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
        recordExecution(of: stmt)
        return results
    }

    /// Look up the top candidate with its frequency for exact pinyin match.
    /// - Parameter pinyin: The pinyin key
    /// - Returns: (word, frequency) tuple, or nil if no match
    public func topCandidate(for pinyin: String) -> (word: String, frequency: Int)? {
        if let cached = topCandidateCache[pinyin] { return cached }
        let result = queryTopCandidate(for: pinyin)
        topCandidateCache[pinyin] = .some(result)
        return result
    }

    private func queryTopCandidate(for pinyin: String) -> TopCandidate? {
        guard let stmt = topStmt else { return nil }

        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, pinyin, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        let stepResult = sqlite3_step(stmt)
        recordExecution(of: stmt)
        guard stepResult == SQLITE_ROW,
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
        if let stmt = stmt { recordExecution(of: stmt) }
        return results
    }

    /// 一组音节下的单字候选，按词频降序。
    ///
    /// 单个声母的候选若用前缀范围查询，须扫描并排序该声母下的全部条目（`j` 开头约 5.8 万行）；
    /// 按音节精确查询只读取单字所在的少量条目。音节数随调用变化，故每次单独编译语句。
    /// - Parameters:
    ///   - syllables: 待查询的音节（如 `["shi", "shu"]`）
    ///   - limit: 返回的最大条数
    public func singleCharCandidates(forSyllables syllables: [String], limit: Int) -> [String] {
        guard let db = db, !syllables.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: syllables.count).joined(separator: ",")
        let sql =
            "SELECT word FROM entries WHERE pinyin IN (\(placeholders)) AND length(word) = 1 "
            + "ORDER BY frequency DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, syllable) in syllables.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), syllable, -1, transient)
        }
        sqlite3_bind_int(stmt, Int32(syllables.count + 1), Int32(limit))

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: cStr))
            }
        }
        recordExecution(of: stmt)
        return results
    }

    /// 是否存在拼音以 `prefix` 开头的条目（含拼音恰为 `prefix` 的条目）。
    /// 无法判断时（前缀为空或末字符非 ASCII）返回 true，使调用方不做剪枝。
    public func hasEntry(withPrefix prefix: String) -> Bool {
        guard let upper = Self.prefixUpperBound(prefix) else { return true }
        return hasEntry(inRange: prefix, upper)
    }

    /// 是否存在拼音以 `prefix` 开头且比 `prefix` 更长的条目。
    /// Conversion 的 DFS 据此判断累积拼音还能否延伸成任何词条。
    /// 无法判断时返回 true，使调用方不做剪枝。
    public func hasLongerEntry(startingWith prefix: String) -> Bool {
        guard let upper = Self.prefixUpperBound(prefix) else { return true }
        // 以 prefix 开头的更长拼音均不小于 prefix + "a"（拼音只含小写字母）
        return hasEntry(inRange: prefix + "a", upper)
    }

    private func hasEntry(inRange lower: String, _ upper: String) -> Bool {
        // 区间由下界与上界唯一确定，而上界由前缀推出，故以「下界|上界」为键
        let key = lower + "|" + upper
        if let cached = prefixCache[key] { return cached }
        let found = queryEntryExists(inRange: lower, upper)
        prefixCache[key] = found
        return found
    }

    private func queryEntryExists(inRange lower: String, _ upper: String) -> Bool {
        guard let stmt = rangeExistsStmt else { return true }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, lower, -1, transient)
        sqlite3_bind_text(stmt, 2, upper, -1, transient)

        let found = sqlite3_step(stmt) == SQLITE_ROW
        recordExecution(of: stmt)
        return found
    }

    /// 前缀区间的上界：末字符加一（`shi` → `shj`）。前缀为空或末字符非 ASCII 时返回 nil。
    private static func prefixUpperBound(_ prefix: String) -> String? {
        guard let last = prefix.last, let ascii = last.asciiValue, ascii < 127 else { return nil }
        return String(prefix.dropLast()) + String(UnicodeScalar(ascii + 1))
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
        recordExecution(of: stmt)
        return results
    }
}

/// 有上限的查询结果缓存，按两代淘汰：查找先查当前代，再查上一代并提升到当前代；
/// 当前代写满时整体降为上一代，原上一代丢弃。条目总数不超过两倍容量，
/// 近期反复使用的条目始终留在缓存中，效果近似 LRU 而无需维护访问顺序。
struct LookupCache<Key: Hashable, Value> {
    private let capacity: Int
    private var current: [Key: Value] = [:]
    private var previous: [Key: Value] = [:]

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { current.count + previous.count }

    subscript(key: Key) -> Value? {
        mutating get {
            if let value = current[key] { return value }
            guard let value = previous[key] else { return nil }
            insert(value, for: key)
            return value
        }
        set {
            guard let value = newValue else { return }
            insert(value, for: key)
        }
    }

    private mutating func insert(_ value: Value, for key: Key) {
        if current.count >= capacity {
            previous = current
            current = [:]
        }
        current[key] = value
    }
}
