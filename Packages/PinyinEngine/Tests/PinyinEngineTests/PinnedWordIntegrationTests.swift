import XCTest

@testable import PinyinEngine

/// PinyinEngine + PinnedWordStore 集成：验证 pin word 后候选首位、pinCandidate API、unpin 行为。
///
/// 测试基于 fixtures/zh_dict.json 中已有的拼音条目：
///   cihui = ["词汇", "辞汇"]   ← 多候选，便于验证「pin 第二项后首位变化」
///   shijian = ["时间"]
final class PinnedWordIntegrationTests: XCTestCase {

    private var zhPath: String!
    private var jaPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
    }

    /// 构造引擎（注入指定 pinnedWords）。
    private func makeEngine(pinnedWords: PinnedWordStore?) -> PinyinEngine {
        PinyinEngine(
            zhDictPath: zhPath, jaDictPath: jaPath, userDictPath: ":memory:",
            pinnedChars: nil, pinnedWords: pinnedWords)
    }

    private func type(_ engine: PinyinEngine, _ text: String) -> EngineState {
        var state = EngineState.idle
        for char in text {
            state = engine.process(.letter(char))
        }
        return state
    }

    // MARK: - 候选层面：pinned word 提到主候选前

    func testPinnedWordSurfacesFirstInCandidates() {
        // cihui 默认顺序是 ["词汇", "辞汇"]；pin "辞汇" 应让它升到首位。
        let pinned = PinnedWordStore(
            toml: """
                [pinned]
                cihui = ["辞汇"]
                """)
        let engine = makeEngine(pinnedWords: pinned)

        let state = type(engine, "cihui")
        XCTAssertEqual(
            state.candidates.first, "辞汇",
            "Pinned word should override default top candidate; got \(state.candidates.prefix(5))")
    }

    func testNoPinnedWordKeepsDictionaryOrder() {
        // 控制组：没有 pinnedWords 时，cihui 走词频默认顺序（首位「词汇」）。
        let engine = makeEngine(pinnedWords: nil)
        let state = type(engine, "cihui")
        XCTAssertEqual(state.candidates.first, "词汇")
    }

    func testPinnedWordDoesNotPolluteSingleSyllable() {
        // 单音节「shi」时，wo 这种多音节 pin 不应当污染候选；
        // 即便 pinnedWords 有内容，单音节首位仍由 char 路径决定。
        let pinned = PinnedWordStore(
            toml: """
                [pinned]
                cihui = ["辞汇"]
                """)
        let engine = makeEngine(pinnedWords: pinned)

        let state = type(engine, "shi")
        XCTAssertNotEqual(state.candidates.first, "辞汇")
    }

    // MARK: - pinCandidate / unpinCandidate API

    func testPinCandidateMovesWordToFront() {
        let pinned = PinnedWordStore(toml: "[pinned]\n")
        let engine = makeEngine(pinnedWords: pinned)

        let state = type(engine, "cihui")
        // 找到「辞汇」的下标；默认它在第二位。
        guard let idx = state.candidates.firstIndex(of: "辞汇") else {
            XCTFail("辞汇 should appear in cihui candidates")
            return
        }
        XCTAssertNotEqual(idx, 0, "Pre-condition: 辞汇 should not already be top")

        XCTAssertTrue(engine.pinCandidate(atIndex: idx))

        // pin 之后 store 内已记录；esc 清空再输入同一拼音，候选应已重排。
        _ = engine.process(.esc)
        let after = type(engine, "cihui")
        XCTAssertEqual(after.candidates.first, "辞汇")
    }

    func testPinCandidateRejectsWhenBufferEmpty() {
        let pinned = PinnedWordStore(toml: "[pinned]\n")
        let engine = makeEngine(pinnedWords: pinned)

        // 缓冲区无活跃输入时 pinCandidate 应当返回 false 静默无副作用。
        XCTAssertFalse(engine.pinCandidate(atIndex: 0))
    }

    func testPinCandidateRejectsOutOfRangeIndex() {
        let pinned = PinnedWordStore(toml: "[pinned]\n")
        let engine = makeEngine(pinnedWords: pinned)

        type(engine, "cihui")
        XCTAssertFalse(engine.pinCandidate(atIndex: 9999))
        XCTAssertFalse(engine.pinCandidate(atIndex: -1))
    }

    func testUnpinCandidateRemovesPinnedWord() {
        let pinned = PinnedWordStore(
            toml: """
                [pinned]
                cihui = ["辞汇"]
                """)
        let engine = makeEngine(pinnedWords: pinned)

        let state = type(engine, "cihui")
        XCTAssertEqual(state.candidates.first, "辞汇")

        // 取消 pin：由于这里是 user-only 测试 store（init(toml:) 没有 sys 层），
        // unpin 后 store 内不再有该词，候选列表回到 dict 默认顺序「词汇」。
        XCTAssertTrue(engine.unpinCandidate(atIndex: 0))
        _ = engine.process(.esc)
        let after = type(engine, "cihui")
        XCTAssertEqual(after.candidates.first, "词汇")
    }

    // MARK: - pinCandidate 区分 char vs word

    func testPinCandidateRoutesSingleCharToCharStore() {
        // 单字候选应走 PinnedCharStore；为了观测，注入空 charStore 并验证 pin 后单字提顶。
        let charStore = PinnedCharStore(toml: "[pinned]\n")
        let wordStore = PinnedWordStore(toml: "[pinned]\n")
        let engine = PinyinEngine(
            zhDictPath: zhPath, jaDictPath: jaPath, userDictPath: ":memory:",
            pinnedChars: charStore, pinnedWords: wordStore)

        let state = type(engine, "shi")
        // shi 单字候选首屏；找一个非首位的单字
        guard let idx = state.candidates.firstIndex(of: "时") else {
            XCTFail("时 should appear in shi candidates")
            return
        }
        XCTAssertNotEqual(idx, 0)
        XCTAssertTrue(engine.pinCandidate(atIndex: idx))

        XCTAssertEqual(charStore.pinnedChars(for: "shi").first, "时")
        XCTAssertTrue(wordStore.pinnedWords(for: "shi").isEmpty)

        // 候选首位被刷新成「时」
        _ = engine.process(.esc)
        let after = type(engine, "shi")
        XCTAssertEqual(after.candidates.first, "时")
    }
}
