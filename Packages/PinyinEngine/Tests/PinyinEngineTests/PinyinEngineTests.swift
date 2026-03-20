import XCTest

@testable import PinyinEngine

final class PinyinEngineTests: XCTestCase {

    private var engine: PinyinEngine!

    override func setUp() {
        super.setUp()
        engine = PinyinEngine()
    }

    // MARK: - Helpers

    /// Send a string of letters to the engine, return the last state
    @discardableResult
    private func type(_ text: String) -> EngineState {
        var state = EngineState.idle
        for char in text {
            state = engine.process(.letter(char))
        }
        return state
    }

    private func space() -> EngineState { engine.process(.space) }
    private func enter() -> EngineState { engine.process(.enter) }
    private func esc() -> EngineState { engine.process(.esc) }
    private func backspace() -> EngineState { engine.process(.backspace) }
    private func number(_ n: Int) -> EngineState { engine.process(.number(n)) }
    private func bracketLeft() -> EngineState { engine.process(.bracket(pickLast: false)) }
    private func bracketRight() -> EngineState { engine.process(.bracket(pickLast: true)) }

    // MARK: - Basic Input & Commit Flows

    func testPinyinInputProducesCandidates() {
        let state = type("shi")
        XCTAssertFalse(state.candidates.isEmpty, "「shi」should produce candidates")
        XCTAssertEqual(state.candidates.first, "是")
        XCTAssertEqual(state.items, [.pinyin("shi")])
        XCTAssertNil(state.committedText)
    }

    func testSpaceCommitsFirstCandidate() {
        type("shi")
        let state = space()
        XCTAssertEqual(state.committedText, "是")
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testNumberSelectsWordWithoutCommitting() {
        type("shi")
        let state = number(2)
        // Number selection finalizes pinyin to text but stays in buffer
        XCTAssertEqual(state.items, [.text("时")])
        XCTAssertNil(state.committedText)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testEnterCommitsRawPinyin() {
        type("shi")
        let state = enter()
        XCTAssertEqual(state.committedText, "shi")
        XCTAssertTrue(state.items.isEmpty)
    }

    func testEscResetsAll() {
        type("shi")
        let state = esc()
        XCTAssertNil(state.committedText)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testBackspaceDeletesLastCharacter() {
        type("shi")
        let state = backspace()
        XCTAssertEqual(state.items, [.pinyin("sh")])
    }

    func testBackspaceDeletesLastItemWhenSingleChar() {
        type("s")
        let state = backspace()
        XCTAssertTrue(state.items.isEmpty)
    }

    // MARK: - Word-based Character Selection (以词定字)

    func testBracketLeftPicksFirstChar() {
        type("shijian")
        let state = bracketLeft()
        // 「shijian」→「时间」, [ picks first char「时」
        XCTAssertEqual(state.items, [.text("时")])
        XCTAssertNil(state.committedText)
    }

    func testBracketRightPicksLastChar() {
        type("shijian")
        let state = bracketRight()
        // 「shijian」→「时间」, ] picks last char「间」
        XCTAssertEqual(state.items, [.text("间")])
        XCTAssertNil(state.committedText)
    }

    // MARK: - Composing Chain (复合缓冲区组词)

    func testComposingChain() {
        // shijian + [ + ziguang + spc → 「时光」
        type("shijian")
        bracketLeft()  // buffer: [.text("时")]

        type("ziguang")  // buffer: [.text("时"), .pinyin("ziguang")]

        let state = space()
        // space finalizes「紫光」then commits all: 「时」+「紫光」= 「时紫光」
        XCTAssertEqual(state.committedText, "时紫光")
        XCTAssertTrue(state.items.isEmpty)
    }

    func testComposingWithNumberThenSpace() {
        // shi + number(2) selects「时」, then continue typing
        type("shi")
        number(2)  // buffer: [.text("时")]

        type("shi")  // buffer: [.text("时"), .pinyin("shi")]

        let state = space()
        // space finalizes first candidate「是」, commits「时是」
        XCTAssertEqual(state.committedText, "时是")
    }

    // MARK: - Transient Japanese Mode (临时日文模式)

    func testTransientJapaneseMode() {
        // Press 'i' at segment boundary to switch mode
        let state = type("i")
        XCTAssertEqual(state.mode, .transient)
        XCTAssertTrue(state.items.isEmpty, "'i' should not appear in buffer")
    }

    func testJapaneseModeProducesJapaneseCandidates() {
        type("i")  // switch to Japanese mode
        let state = type("nihon")
        XCTAssertEqual(state.candidates.first, "日本")
    }

    func testJapaneseModeAutoRevertsAfterCommit() {
        type("i")  // switch to Japanese mode
        type("nihon")
        let state = space()  // commit
        XCTAssertEqual(state.committedText, "日本")
        XCTAssertEqual(state.mode, .pinyin, "Should auto-revert to pinyin mode after commit")
    }

    func testJapaneseModeAutoRevertsAfterEsc() {
        type("i")
        type("nihon")
        let state = esc()
        XCTAssertEqual(state.mode, .pinyin, "Should auto-revert to pinyin mode after esc")
    }

    // MARK: - Edge Cases

    func testEmptyBufferSpaceDoesNothing() {
        let state = space()
        XCTAssertNil(state.committedText)
        XCTAssertTrue(state.items.isEmpty)
    }

    func testEmptyBufferEnterDoesNothing() {
        let state = enter()
        XCTAssertNil(state.committedText)
        XCTAssertTrue(state.items.isEmpty)
    }

    func testEmptyBufferBackspaceDoesNothing() {
        let state = backspace()
        XCTAssertTrue(state.items.isEmpty)
    }

    func testLetterIMidPinyinIsNotModeSwitch() {
        let state = type("shi")
        // 'i' was part of "shi", mode should still be pinyin
        XCTAssertEqual(state.mode, .pinyin)
        XCTAssertEqual(state.items, [.pinyin("shi")])
    }

    func testSpaceWithNoCandidatesCommitsRawPinyin() {
        type("xyz")  // no candidates for this
        let state = space()
        XCTAssertEqual(state.committedText, "xyz")
        XCTAssertTrue(state.items.isEmpty)
    }
}
