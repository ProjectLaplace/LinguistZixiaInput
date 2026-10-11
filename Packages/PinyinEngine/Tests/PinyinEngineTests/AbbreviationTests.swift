import XCTest

@testable import PinyinEngine

final class AbbreviationTests: XCTestCase {

    private var store: DictionaryStore!

    override func setUp() {
        super.setUp()
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        store = DictionaryStore(path: zhPath)
    }

    // MARK: - 单元切分

    func testUnitsSplitEachLetterAndPreferDigraphInitials() {
        XCTAssertEqual(Abbreviation.units(in: Array("rgzn"), from: 0), ["r", "g", "z", "n"])
        XCTAssertEqual(Abbreviation.units(in: Array("zhn"), from: 0), ["zh", "n"])
        XCTAssertEqual(Abbreviation.units(in: Array("chsh"), from: 0), ["ch", "sh"])
    }

    func testUnitsTreatYAndWAsAbbreviationLetters() {
        XCTAssertEqual(Abbreviation.units(in: Array("zryy"), from: 0), ["z", "r", "y", "y"])
        XCTAssertEqual(Abbreviation.units(in: Array("wm"), from: 0), ["w", "m"])
    }

    func testUnitsStopAtFirstNonAbbreviationLetter() {
        XCTAssertEqual(Abbreviation.units(in: Array("jsa"), from: 0), ["j", "s"])
        XCTAssertEqual(Abbreviation.units(in: Array("shijianrgzn"), from: 7), ["r", "g", "z", "n"])
        XCTAssertEqual(Abbreviation.units(in: Array("ai"), from: 0), [])
    }

    // MARK: - 音节切分

    func testSplitsDivideReadingIntoExactSyllableCount() {
        XCTAssertEqual(Abbreviation.splits(of: "xian", into: 1), [["xian"]])
        XCTAssertEqual(Abbreviation.splits(of: "jishu", into: 2), [["ji", "shu"]])
        XCTAssertTrue(
            Abbreviation.splits(of: "rengongzhineng", into: 4).contains([
                "ren", "gong", "zhi", "neng",
            ]))
        XCTAssertEqual(Abbreviation.splits(of: "jishu", into: 3), [])
    }

    func testSplitsAvoidInterjectionSyllablesWhenAlternativesExist() {
        // 西安 xi'an 不应切为 xia + n（嗯）
        XCTAssertEqual(Abbreviation.splits(of: "xian", into: 2), [["xi", "an"]])
    }

    // MARK: - 匹配

    func testTwoLettersMatchEveryTwoSyllableWordWithThoseInitials() {
        let words = store.abbreviationMatches(units: ["j", "s"]).map(\.word)

        XCTAssertTrue(words.contains("技术"))
        XCTAssertTrue(words.contains("计算"))
    }

    func testSingleLetterInitialAlsoMatchesItsDigraphSyllables() {
        // s 同时匹配 shu（技术 ji+shu）与 suan（计算 ji+suan）
        let matches = store.abbreviationMatches(units: ["j", "s"])

        XCTAssertEqual(
            Set(matches.map(\.pinyin)).intersection(["jishu", "jisuan"]), ["jishu", "jisuan"])
    }

    func testDigraphUnitMatchesOnlyItsOwnInitial() {
        XCTAssertTrue(store.abbreviationMatches(units: ["zh", "r", "y", "y"]).isEmpty)
        XCTAssertEqual(
            store.abbreviationMatches(units: ["z", "r", "y", "y"]).map(\.word), ["自然语言"])
    }

    func testMatchesCarryFullReadingAndSyllables() {
        let match = store.abbreviationMatches(units: ["r", "g", "z", "n"]).first

        XCTAssertEqual(match?.word, "人工智能")
        XCTAssertEqual(match?.pinyin, "rengongzhineng")
        XCTAssertEqual(match?.syllables, ["ren", "gong", "zhi", "neng"])
    }

    func testMatchesRequireExactlyOneSyllablePerUnit() {
        // 开发技术 kai+fa+ji+shu 只匹配四个单元，不匹配其前两个单元
        XCTAssertTrue(
            store.abbreviationMatches(units: ["k", "f", "j", "s"]).map(\.word).contains("开发技术"))
        XCTAssertFalse(store.abbreviationMatches(units: ["k", "f"]).map(\.word).contains("开发技术"))
    }

    func testMatchesAreOrderedByFrequencyDescending() {
        let frequencies = store.abbreviationMatches(units: ["j", "s"]).map(\.frequency)

        XCTAssertEqual(frequencies, frequencies.sorted(by: >))
    }

    // MARK: - 查询开销

    /// 同一对起始单元的词条只从词库扫描一次；更长的简拼串在缓存的词条中过滤。
    func testLongerAbbreviationSharingFirstTwoUnitsRunsNoFurtherQuery() {
        _ = store.abbreviationMatches(units: ["r", "g"])
        store.resetStats()

        _ = store.abbreviationMatches(units: ["r", "g", "z"])
        _ = store.abbreviationMatches(units: ["r", "g", "z", "n"])

        XCTAssertEqual(store.stats.statements, 0)
    }

    func testAbbreviationCacheStaysWithinCapacity() {
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let small = DictionaryStore(path: zhPath, abbreviationCacheCapacity: 2)!
        for (first, second) in [("j", "s"), ("r", "g"), ("z", "r"), ("k", "f"), ("s", "j")] {
            _ = small.abbreviationEntries(firstUnit: first, secondUnit: second)
        }

        XCTAssertLessThanOrEqual(small.cachedAbbreviationKeyCount, 4)
    }
}
