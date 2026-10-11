import XCTest

@testable import PinyinEngine

final class DictionaryStoreTests: XCTestCase {

    private var store: DictionaryStore!

    override func setUp() {
        super.setUp()
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        store = DictionaryStore(path: zhPath)
    }

    // MARK: - 查询计数

    func testStatsStartAtZero() {
        XCTAssertEqual(store.stats, DictionaryStore.QueryStats())
    }

    func testEachLookupCountsOneStatementWithVMSteps() {
        _ = store.candidates(for: "shijian")
        _ = store.topCandidate(for: "shijian")
        _ = store.candidatesWithFrequency(for: "shijian")
        _ = store.candidatesWithPrefix("shi")

        XCTAssertEqual(store.stats.statements, 4)
        XCTAssertGreaterThan(store.stats.vmSteps, 0)
    }

    func testResetStatsClearsCounters() {
        _ = store.candidates(for: "shijian")
        store.resetStats()
        XCTAssertEqual(store.stats, DictionaryStore.QueryStats())
    }

    func testEngineExposesQueryStatsOfItsChineseDictionary() {
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        let engine = PinyinEngine(zhDictPath: zhPath, jaDictPath: jaPath)

        _ = engine.process(.letter("s"))

        XCTAssertGreaterThan(engine.zhDictionary?.stats.statements ?? 0, 0)
    }

    // MARK: - 指定音节的单字候选

    func testSingleCharCandidatesCoverAllGivenSyllablesInOneStatement() {
        let chars = store.singleCharCandidates(forSyllables: ["shi", "shu"], limit: 100)

        XCTAssertTrue(chars.contains("是"))
        XCTAssertTrue(chars.contains("书"))
        XCTAssertTrue(chars.allSatisfy { $0.count == 1 })
        XCTAssertEqual(store.stats.statements, 1)
    }

    func testSingleCharCandidatesRespectLimit() {
        XCTAssertEqual(store.singleCharCandidates(forSyllables: ["shi"], limit: 3).count, 3)
    }
}
