import XCTest

@testable import PinyinEngine

/// features/abbreviation.feature 的行为测试，测试名带 scenario 标识。
final class AbbreviationFeatureTests: XCTestCase {

    private var engine: PinyinEngine!
    private var store: DictionaryStore!

    override func setUp() {
        super.setUp()
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        engine = PinyinEngine(zhDictPath: zhPath, jaDictPath: jaPath)
        store = DictionaryStore(path: zhPath)
    }

    @discardableResult
    private func type(_ text: String) -> EngineState {
        var state = EngineState.idle
        for char in text {
            state = engine.process(.letter(char))
        }
        return state
    }

    // MARK: - Scenarios

    /// @jianpin-001 四个声母组出四字词
    func test_jianpin001_fourInitialsComposeFourCharacterWord() {
        XCTAssertEqual(type("rgzn").candidates.first, "人工智能")
    }

    /// @jianpin-002 含 y 的简拼组出词
    func test_jianpin002_abbreviationWithYComposesWord() {
        XCTAssertEqual(type("zryy").candidates.first, "自然语言")
    }

    /// @jianpin-004 完整拼音与简拼在词边界处混合组词
    func test_jianpin004_fullPinyinAndAbbreviationMixAtWordBoundary() {
        XCTAssertEqual(type("shijianrgzn").candidates.first, "时间人工智能")
    }

    /// @jianpin-003 两个声母列出所有匹配的双字词
    func test_jianpin003_twoInitialsListEveryMatchingTwoCharacterWord() {
        let candidates = type("js").candidates

        XCTAssertTrue(candidates.contains("技术"), "\(candidates.prefix(9))")
        XCTAssertTrue(candidates.contains("计算"), "\(candidates.prefix(9))")
    }

    /// @jianpin-005 选择简拼列出的非首选词并上屏
    func test_jianpin005_choosingNonFirstAbbreviationWordCommitsIt() {
        let candidates = type("js").candidates
        guard let first = candidates.first, ["技术", "计算"].contains(first) else {
            return XCTFail("首选不是技术或计算：\(candidates.prefix(9))")
        }
        let other = first == "技术" ? "计算" : "技术"
        guard let index = candidates.firstIndex(of: other), index < 9 else {
            return XCTFail("\(other) 不在首页：\(candidates.prefix(9))")
        }

        let state = engine.process(.number(index + 1))

        XCTAssertEqual(state.committedText, other)
    }

    // MARK: - 候选列表

    /// 纯简拼输入的候选末尾列出首字母的单字，选中只消耗该字母，其余字母留下继续组词
    func testAbbreviationListsFirstLetterSingleCharactersAsPartialChoices() {
        let candidates = type("js").candidates
        guard let index = candidates.firstIndex(of: "级"), index < 9 else {
            return XCTFail("首字母单字不在首页：\(candidates.prefix(9))")
        }

        let state = engine.process(.number(index + 1))

        XCTAssertNil(state.committedText)
        XCTAssertEqual(state.items.first, .text("级"))
        XCTAssertEqual(state.items.last?.sourcePinyin, "s")
    }

    /// 首段为简拼段时，首段补充候选为与首段字母匹配的其他词；选中后剩余字母继续组词
    func testFirstAbbreviationSegmentOffersOtherWordsMatchingItsLetters() {
        let state = type("jsrgzn")
        let composed = state.candidates.first ?? ""
        let other = composed.hasPrefix("技术") ? "计算" : "技术"
        guard let index = state.candidates.firstIndex(of: other), index < 9 else {
            return XCTFail("\(other) 不在首页：\(state.candidates.prefix(9))")
        }

        let next = engine.process(.number(index + 1))

        XCTAssertNil(next.committedText)
        XCTAssertEqual(next.items.first, .text(other))
        XCTAssertEqual(next.candidates.first, "人工智能")
    }

    // MARK: - 开销

    /// 简拼越长，每次按键的词典查询次数不成倍增长：同一对起始单元的词条只扫描一次，
    /// 更长的简拼串在缓存中过滤。键入 rgznzryy，第 8 键的查询次数不超过第 3 键的两倍。
    func testAbbreviationQueriesDoNotMultiplyWithLength() {
        guard let store = engine.zhDictionary else { return XCTFail("no dictionary") }
        var statementsPerKey: [Int] = []
        for char in "rgznzryy" {
            store.resetStats()
            engine.process(.letter(char))
            statementsPerKey.append(store.stats.statements)
        }

        XCTAssertLessThanOrEqual(
            statementsPerKey[7], statementsPerKey[2] * 2, "\(statementsPerKey)")
    }

    // MARK: - 边界

    /// 起点字母能接续前一音节时，不从该处开始简拼段：guanl 中的 n 属于 guan，
    /// xiangf 中的 n、g 属于 xiang，二者末尾都只剩一个单元，不构成简拼串
    func testAbbreviationDoesNotStartInsidePrecedingSyllable() {
        XCTAssertFalse(Conversion.hasAbbreviationTail("shijianguanl"))
        XCTAssertFalse(Conversion.hasAbbreviationTail("xiangf"))
        XCTAssertTrue(Conversion.hasAbbreviationTail("shijianrgzn"))
        XCTAssertTrue(Conversion.hasAbbreviationTail("js"))
        XCTAssertTrue(Conversion.hasAbbreviationTail("zryy"))
    }

    /// 末单元能与其后的字母组成音节时，简拼段不在该处结束：jsan 中的 s 属于 san，
    /// 不应切出「技术」再把孤立的 an 组成单字
    func testAbbreviationDoesNotEndInsideFollowingSyllable() {
        for input in ["jsan", "jsai"] {
            guard let result = Conversion.compose(input, store: store) else { continue }
            XCTAssertFalse(
                result.text.hasPrefix("技术") || result.text.hasPrefix("计算"),
                "\(input) → \(result.text)")
        }
    }

    /// 单独的 zh/ch/sh 是一个双字母声母，不作为两个字母的简拼
    func testLoneDigraphInitialIsNotAbbreviation() {
        let state = type("zh")
        XCTAssertTrue(
            state.candidates.allSatisfy { $0.count == 1 }, "\(state.candidates.prefix(5))")
    }

    /// 简拼尾段不再进入「中文 + 残留字母」的 fallback
    func testAbbreviationTailDoesNotFallBackToResidualLetters() {
        let state = type("zryy")
        XCTAssertFalse(
            state.candidates.contains { $0.contains("y") }, "\(state.candidates.prefix(5))")
    }
}
