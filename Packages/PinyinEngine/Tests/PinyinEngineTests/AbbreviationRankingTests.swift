import SQLite3
import XCTest

@testable import PinyinEngine

/// 整串简拼的排序：测试词库的词频都低于 `wordNoiseFloor`，无法检验「真正成词」的判定，
/// 故在临时目录中建一个小词库，模拟生产词库的词频分布。
final class AbbreviationRankingTests: XCTestCase {

    /// 每个测试独占一个临时目录，结束时清理。
    private var scratchDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: scratchDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchDir = scratchDir {
            try? FileManager.default.removeItem(at: scratchDir)
        }
        try super.tearDownWithError()
    }

    /// 两个高频双字词拼成的组词结果（如果 + 只能）在评分上略胜同一串字母的四字词（人工智能），
    /// 与生产词库中 rgzn 的情形相同。
    private func makeEngine(extraEntries: [(String, String, Int)] = []) throws -> PinyinEngine {
        let entries: [(String, String, Int)] =
            [
                ("ruguo", "如果", 900_000),
                ("zhineng", "只能", 500_000),
                ("ren", "人", 800_000),
                ("gong", "工", 400_000),
                ("zhi", "只", 700_000),
                ("neng", "能", 600_000),
            ] + extraEntries
        let zhPath = scratchDir.appendingPathComponent("zh_dict.db").path
        try writeDictionary(entries, to: zhPath)
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        return PinyinEngine(zhDictPath: zhPath, jaDictPath: jaPath)
    }

    private func writeDictionary(_ entries: [(String, String, Int)], to path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE entries (pinyin TEXT NOT NULL, word TEXT NOT NULL,
                frequency INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX idx_pinyin ON entries(pinyin);
            """
        for (pinyin, word, frequency) in entries {
            sql += "INSERT INTO entries VALUES ('\(pinyin)', '\(word)', \(frequency));"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func type(_ engine: PinyinEngine, _ text: String) -> EngineState {
        var state = EngineState.idle
        for char in text {
            state = engine.process(.letter(char))
        }
        return state
    }

    /// 与整串字母匹配的词是真正成词的词条时（词频不低于 wordNoiseFloor），它排在组词结果之前，
    /// 与完整拼音「整串匹配优先」一致
    func testWholeAbbreviationWordLeadsWhenItIsARealWord() throws {
        let engine = try makeEngine(extraEntries: [("rengongzhineng", "人工智能", 31_450)])

        let candidates = type(engine, "rgzn").candidates

        XCTAssertEqual(candidates.first, "人工智能", "\(candidates.prefix(5))")
        XCTAssertTrue(candidates.contains("如果只能"), "\(candidates.prefix(5))")
    }

    /// 整串匹配的词低于 wordNoiseFloor（词库噪声）时，组词结果仍排在首位
    func testNoiseLevelWholeAbbreviationWordDoesNotLead() throws {
        let engine = try makeEngine(extraEntries: [("ruoguanzhinian", "弱冠之年", 555)])

        let candidates = type(engine, "rgzn").candidates

        XCTAssertEqual(candidates.first, "如果只能", "\(candidates.prefix(5))")
        XCTAssertTrue(candidates.contains("弱冠之年"), "\(candidates.prefix(5))")
    }
}
