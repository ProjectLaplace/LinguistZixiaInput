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
    private func tab() -> EngineState { engine.process(.tab(backward: false)) }
    private func shiftTab() -> EngineState { engine.process(.tab(backward: true)) }

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

    // MARK: - Auto-split & Composition (自动切分与组词)

    func testMultiSyllableAutoSplit() {
        let state = type("shijian")
        // "shijian" should auto-split into provisional("shi") + pinyin("jian")
        XCTAssertEqual(state.items.count, 2)
        XCTAssertEqual(state.items[0], .provisional(pinyin: "shi", candidate: "是"))
        XCTAssertEqual(state.items[1], .pinyin("jian"))
        // Whole-string match "时间" should be first candidate
        XCTAssertEqual(state.candidates.first, "时间")
    }

    func testAutoSplitSpaceCommitsWholeStringMatch() {
        type("shijian")
        let state = space()
        // Whole-string match "时间" takes priority
        XCTAssertEqual(state.committedText, "时间")
        XCTAssertTrue(state.items.isEmpty)
    }

    func testAutoSplitComposedCandidate() {
        // "wode" exists as a word, so whole-string match comes first
        let state = type("wode")
        XCTAssertEqual(state.candidates.first, "我的")
    }

    func testAutoSplitLongPhraseComposition() {
        // "kaifajishu" — no whole-string match, but per-syllable composition works
        let state = type("kaifajishu")
        // Should have provisional items for completed syllables
        XCTAssertTrue(state.items.count > 1, "Should auto-split into multiple segments")
        // Composed candidate should exist: 开发 + 技术 or 开 + 发 + 技 + 术
        let display = state.fullDisplayBuffer
        XCTAssertFalse(display == "kaifajishu", "Should show Chinese preview, not raw pinyin")
    }

    func testAutoSplitPartialInput() {
        // "shij" — "shi" is complete, "j" is partial remainder
        let state = type("shij")
        XCTAssertEqual(state.items.count, 2)
        XCTAssertEqual(state.items[0], .provisional(pinyin: "shi", candidate: "是"))
        XCTAssertEqual(state.items[1], .pinyin("j"))
    }

    func testEnterCommitsRawPinyinWithAutoSplit() {
        type("shijian")
        let state = enter()
        // Enter should commit raw pinyin, not candidates
        XCTAssertEqual(state.committedText, "shijian")
    }

    // MARK: - Tab Navigation (Tab 段间导航)

    func testTabEntersSegmentFocus() {
        type("shijian")
        let state = tab()
        // Should focus on the first editable segment
        XCTAssertNotNil(state.focusedSegmentIndex)
    }

    func testTabShowsPerSegmentCandidates() {
        type("shijian")
        let beforeTab = engine.process(.tab(backward: false))
        // After Tab, candidates should be for the focused segment, not whole string
        // First segment is "shi"
        XCTAssertEqual(beforeTab.candidates.first, "是")
    }

    func testTabCycleThroughSegments() {
        type("shijian")
        tab()  // focus on first segment
        let state = tab()  // move to second segment
        // Candidates should now be for "jian"
        XCTAssertFalse(state.candidates.isEmpty)
        // Focus should have moved
        XCTAssertNotNil(state.focusedSegmentIndex)
    }

    func testSpaceInTabModeConfirmsSegment() {
        type("shijian")
        tab()  // focus on first segment "shi"
        let state = space()  // confirm with first candidate
        // Should NOT commit to output, just confirm the segment
        XCTAssertNil(state.committedText)
        // The focused segment should now be .text
        XCTAssertTrue(state.items.contains(.text("是")))
    }

    func testShiftTabNavigatesBackward() {
        type("shijian")
        let state = shiftTab()
        // Should focus on the last editable segment
        XCTAssertNotNil(state.focusedSegmentIndex)
    }

    // MARK: - Apostrophe Separation (撇号分隔)

    func testApostropheSeparationCandidates() {
        // "xi'an" — user explicitly separates into xi + an
        // Candidates should NOT include single-char words like 先/现 (those match "xian" as one syllable)
        // Should include composed "西安" (西 + 安)
        let state = type("xi'an")
        XCTAssertFalse(state.candidates.isEmpty, "xi'an should produce candidates")
        // Single-char xian words should be filtered out
        XCTAssertFalse(state.candidates.contains("先"), "Single-char 先 should not appear for xi'an")
        XCTAssertFalse(state.candidates.contains("现"), "Single-char 现 should not appear for xi'an")
        // Composed candidate 西安 should be present
        XCTAssertTrue(state.candidates.contains("西安"), "Composed 西安 should appear for xi'an")
    }
}
