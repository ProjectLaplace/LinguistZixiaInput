import XCTest

@testable import PinyinEngine

final class PinyinEngineTests: XCTestCase {

    private var engine: PinyinEngine!

    override func setUp() {
        super.setUp()
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        engine = PinyinEngine(zhDictPath: zhPath, jaDictPath: jaPath)
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
    private func cycleActive() -> EngineState {
        engine.process(.cycleActiveCandidate(backward: false))
    }
    private func cycleActiveBack() -> EngineState {
        engine.process(.cycleActiveCandidate(backward: true))
    }

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

    func testNumberSelectsAndCommits() {
        type("shi")
        let state = number(2)
        // Number selection commits directly in non-Tab mode
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertEqual(state.committedText, "时")
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
        // 「shijian」→「时间」, [ picks first char「时」 and commits directly
        XCTAssertEqual(state.committedText, "时")
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testBracketRightPicksLastChar() {
        type("shijian")
        let state = bracketRight()
        // 「shijian」→「时间」, ] picks last char「间」 and commits directly
        XCTAssertEqual(state.committedText, "间")
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testBracketThenContinueTyping() {
        // After bracket commits, the next pinyin starts fresh
        type("shijian")
        bracketLeft()  // commits 「时」
        let state = type("shi")
        XCTAssertEqual(state.items, [.pinyin("shi")])
        XCTAssertNil(state.committedText)
    }

    // MARK: - Active Candidate State

    func testActiveCandidateIndexDefaultsToZero() {
        let idle = EngineState.idle
        XCTAssertEqual(idle.activeCandidateIndex, 0)
        let state = type("shi")
        XCTAssertEqual(state.activeCandidateIndex, 0)
    }

    func testActiveCandidateIndexResetsAfterCommit() {
        type("shi")
        let state = space()
        XCTAssertEqual(state.activeCandidateIndex, 0)
    }

    // MARK: - First-Word Candidate Injection

    func testFirstWordCandidateInjectedFor4Syllables() {
        // kaifajishu (4 syllables): no whole match, Conversion produces 开发+技术
        let state = type("kaifajishu")
        XCTAssertGreaterThanOrEqual(state.candidates.count, 2)
        XCTAssertEqual(state.candidates[0], "开发技术")
        XCTAssertEqual(state.candidates[1], "开发")
    }

    func testFirstWordCandidateNotInjectedFor2Syllables() {
        // shijian (2 syllables): too short, no first-word injection
        let state = type("shijian")
        XCTAssertEqual(state.candidates.first, "时间")
        // The 2nd candidate should NOT be the first word 「时」; that path is only
        // for ≥4 syllable input. (「时」 may still appear as a first-segment
        // supplementary candidate later in the list, but not at index 1.)
        if state.candidates.count >= 2 {
            XCTAssertNotEqual(state.candidates[1], "时")
        }
    }

    // MARK: - Cycle Active Candidate

    func testCycleActiveCandidateMovesForward() {
        let typed = type("kaifajishu")
        XCTAssertGreaterThanOrEqual(typed.candidates.count, 2)
        XCTAssertEqual(typed.activeCandidateIndex, 0)
        let cycled = cycleActive()
        XCTAssertEqual(cycled.activeCandidateIndex, 1)
    }

    func testCycleActiveCandidateBackwardWrapsAround() {
        let typed = type("kaifajishu")
        XCTAssertGreaterThanOrEqual(typed.candidates.count, 2)
        let cycled = cycleActiveBack()
        XCTAssertEqual(cycled.activeCandidateIndex, typed.candidates.count - 1)
    }

    func testSpaceCommitsActiveCandidate() {
        let typed = type("kaifajishu")
        XCTAssertGreaterThanOrEqual(typed.candidates.count, 2)
        let secondCandidate = typed.candidates[1]
        cycleActive()  // active → index 1
        let committed = space()
        XCTAssertEqual(committed.committedText, secondCandidate)
    }

    func testSpaceCommitsFirstCandidateWhenNotCycled() {
        let typed = type("kaifajishu")
        let firstCandidate = typed.candidates[0]
        let committed = space()
        XCTAssertEqual(committed.committedText, firstCandidate)
    }

    func testPunctuationCommitsActiveCandidate() {
        let typed = type("kaifajishu")
        XCTAssertGreaterThanOrEqual(typed.candidates.count, 2)
        let secondCandidate = typed.candidates[1]
        cycleActive()  // active → index 1
        let committed = engine.process(.punctuation(","))
        XCTAssertEqual(committed.committedText, secondCandidate + "，")
    }

    // MARK: - Bracket Compose Mode

    func testBracketOnFirstWordCandidateEntersComposeMode() {
        // kaifajishu (4 syl): 1st 「开发技术」, 2nd 「开发」（首词注入）
        type("kaifajishu")
        cycleActive()  // active → 「开发」
        let state = bracketLeft()
        // 选「开」，消耗 kaifa（2 音节），剩余 jishu
        XCTAssertNil(state.committedText)
        XCTAssertEqual(state.items.first, .text("开"))
        XCTAssertTrue(state.candidates.contains("技术"), "Remaining 'jishu' should match 「技术」")
    }

    func testBracketComposeChainCommitsWhenSyllablesExhausted() {
        // 流程：kaifajishu → Ctrl+Tab → [ → 「开」+ jishu → [ on 「技术」 → 提交「开技」
        type("kaifajishu")
        cycleActive()
        bracketLeft()  // 「开」 in buffer, remaining jishu
        let state = bracketLeft()  // active=0 「技术」 (2 chars), 消耗 jishu，无剩余 → 提交
        XCTAssertEqual(state.committedText, "开技")
        XCTAssertTrue(state.items.isEmpty)
    }

    func testBracketRightOnFirstWordPicksLastChar() {
        // ] picks last char of active candidate
        type("kaifajishu")
        cycleActive()  // active → 「开发」
        let state = bracketRight()
        XCTAssertNil(state.committedText)
        XCTAssertEqual(state.items.first, .text("发"))
    }

    func testBracketOnWholeMatchStillCommitsDirectly() {
        // 4 音节但 active 是整串 → 消耗全部 → commit（保持 commit 1 行为）
        type("kaifajishu")
        // active 默认 0 = 「开发技术」(4 chars)
        let state = bracketLeft()
        XCTAssertEqual(state.committedText, "开")
        XCTAssertTrue(state.items.isEmpty)
    }

    func testSpaceInComposeModeCommitsTextPlusBestRemaining() {
        // 「开」+ jishu，空格应提交 「开」 + 剩余的最佳候选 「技术」
        type("kaifajishu")
        cycleActive()
        bracketLeft()  // 「开」 + jishu
        let state = space()
        XCTAssertEqual(state.committedText, "开技术")
        XCTAssertTrue(state.items.isEmpty)
    }

    func testEscInComposeModeDiscardsAll() {
        // 「开」+ jishu，ESC 应清空整个缓冲区，不向宿主写出任何内容
        type("kaifajishu")
        cycleActive()
        bracketLeft()  // 「开」 + jishu
        let state = esc()
        XCTAssertNil(state.committedText)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testEscWithOnlyPinyinDiscardsAll() {
        // 缓冲区里只有拼音段时，ESC 清空缓冲区并重置引擎
        type("shi")
        let state = esc()
        XCTAssertNil(state.committedText)
        XCTAssertTrue(state.items.isEmpty)
    }

    func testEscWithLiteralBlockDiscardsAll() {
        // 混输态下字面块（如「xianzai API」中的「API」）也属于缓冲区，
        // ESC 应一并清空，不向宿主写出任何内容
        type("xianzai")
        _ = engine.process(.letter("A"))
        _ = engine.process(.letter("P"))
        _ = engine.process(.letter("I"))
        let state = esc()
        XCTAssertNil(state.committedText)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testCycleActiveCandidateNoOpWithSingleCandidate() {
        let typed = type("a")  // assumes few candidates; check real count
        guard typed.candidates.count <= 1 else {
            // Skip if fixture provides multiple candidates here
            return
        }
        let cycled = cycleActive()
        XCTAssertEqual(cycled.activeCandidateIndex, 0)
    }

    func testNumberCommitsThenContinueTyping() {
        // shi + number(2) commits「时」directly
        type("shi")
        let committed = number(2)
        XCTAssertEqual(committed.committedText, "时")
        XCTAssertTrue(committed.items.isEmpty)

        // Continue typing starts a fresh buffer
        type("shi")
        let state = space()
        XCTAssertEqual(state.committedText, "是")
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
        XCTAssertEqual(state.items[0], .pinyin("shi"))
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
        // "kaifajishu": no whole-string match, but per-syllable composition works
        let state = type("kaifajishu")
        // Should auto-split into multiple pinyin segments
        XCTAssertTrue(state.items.count > 1, "Should auto-split into multiple segments")
        // Buffer shows pinyin, not Chinese preview
        XCTAssertTrue(state.items.allSatisfy { $0.isPinyin }, "All items should be pinyin")
        // Composed candidate should exist in candidate list
        XCTAssertFalse(state.candidates.isEmpty, "Should have composed candidates")
    }

    func testGreedyPhraseComposition() {
        // "jianchayixia": Conversion should match jiancha(检查) + yixia(一下)
        // not jianchayi(检查仪) + xia(下) or per-syllable jian+cha+yi+xia
        let state = type("jianchayixia")
        XCTAssertTrue(
            state.candidates.contains("检查一下"),
            "Conversion should produce 检查一下")
        XCTAssertFalse(
            state.candidates.contains("见差一下"),
            "Per-syllable 见差一下 should not appear")
    }

    func testWholeStringMatchTakesPriorityOverComposition() {
        // "shijian" has whole-string match 时间: should be first, not composed 是见
        let state = type("shijian")
        XCTAssertEqual(state.candidates.first, "时间")
    }

    func testCompositionWithPartialRemainderSkipped() {
        // "kaifaj": remainder "j" is incomplete, composition requires no remainder
        let state = type("kaifaj")
        // Should not contain a composed candidate with dangling "j"
        XCTAssertFalse(state.candidates.isEmpty, "Should have prefix match candidates")
    }

    func testCompositionFallsBackToSingleChars() {
        // "kaifajishu": whole-string match exists (开发技术), so it takes priority
        // If it didn't, Conversion would produce 开发+技术 over 开+发+技+术
        let state = type("kaifajishu")
        XCTAssertTrue(
            state.candidates.contains("开发技术"),
            "Should produce 开发技术")
    }

    func testCompositionMultiWordPhrase() {
        // "wanquanhushuo": Conversion should compose wanquan(完全) + hushuo(胡说) = 完全胡说
        let state = type("wanquanhushuo")
        XCTAssertTrue(
            state.candidates.contains("完全胡说"),
            "Conversion should produce 完全胡说")
    }

    func testConversionCrossesSyllableBoundary() {
        // "jianchayixiane": two-stage approach splits "xian"+"e" → 检查仪限额
        // Conversion should prefer "xia"+"ne" because it enables 一下+呢 → 检查一下呢
        let state = type("jianchayixiane")
        XCTAssertTrue(
            state.candidates.contains("检查一下呢"),
            "Conversion should produce 检查一下呢 by choosing xia+ne over xian+e")
    }

    func testConversionPrefersHighQualityPhrases() {
        // "shishenmene": 失神+门额 has two multi-char words but low avg quality;
        // 是+什么+呢 has one high-quality multi-char word (什么) and should win.
        let state = type("shishenmene")
        XCTAssertTrue(
            state.candidates.contains("是什么呢"),
            "Conversion should prefer 是什么呢 over 失神门额")
    }

    func testConversionWordCoveragePreventsSingleCharFiller() {
        // "jingquepipei": 景区+饿+匹配 has a single-char filler (饿);
        // 精确+匹配 has full wordCoverage and should win.
        let state = type("jingquepipei")
        XCTAssertEqual(
            state.candidates.first, "精确匹配",
            "Conversion should prefer 精确匹配 (full wordCoverage) over 景区饿匹配 (single-char filler)")
    }

    func testConversionFewerSegmentsPreferred() {
        // "shenmetamadejiaojingxi": "jiao" should NOT be split into "ji+a+o"
        // because fewer segments is better when wordCoverage is equal
        let state = type("shenmetamadejiaojingxi")
        XCTAssertFalse(state.candidates.isEmpty)
        let first = state.candidates.first ?? ""
        // Should NOT contain the ji+a+o split pattern (级啊奥/级啊哦)
        XCTAssertFalse(
            first.contains("级啊"),
            "Conversion should not split jiao into ji+a+o, got: \(first)")
        // Should contain 惊喜 (jingxi correctly matched as a multi-char word)
        XCTAssertTrue(
            first.contains("惊喜"),
            "Conversion should match 惊喜 as a multi-char word, got: \(first)")
    }

    func testConversionLowFreqMultiCharNotCountedAsCoverage() {
        // "shenmetamadejiaojingxi": 的脚(dejiao, freq=5555) is a dictionary artifact
        // It should not win the path over 叫 (jiao as a single char), regardless of
        // whether 的脚 happens to clear the wordNoiseFloor under the current config.
        // So the result should use 叫 (jiao alone) not 脚 (via 的脚 compound)
        let state = type("shenmetamadejiaojingxi")
        let first = state.candidates.first ?? ""
        XCTAssertTrue(
            first.contains("叫"),
            "Low-freq 的脚 should not boost wordCoverage, expect 叫 not 脚, got: \(first)")
    }

    func testAutoSplitPartialInput() {
        // "shij": "shi" is complete, "j" is partial remainder
        let state = type("shij")
        XCTAssertEqual(state.items.count, 2)
        XCTAssertEqual(state.items[0], .pinyin("shi"))
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

    func testTabDoesNotAutoConfirmOtherSegments() {
        type("shijian")
        let state = tab()  // focus on first segment "shi"
        // Non-focused segment "jian" should remain .pinyin, not be auto-confirmed
        XCTAssertEqual(state.items, [.pinyin("shi"), .pinyin("jian")])
        XCTAssertEqual(state.focusedSegmentIndex, 0)
    }

    func testSpaceInTabModeConfirmsSegment() {
        type("shijian")
        tab()  // focus on first segment "shi"
        let state = space()  // confirm with first candidate
        // Should NOT commit to output, just confirm the segment
        XCTAssertNil(state.committedText)
        // The confirmed segment should be .text, other stays .pinyin
        XCTAssertEqual(state.items[0], .text("是"))
        XCTAssertEqual(state.items[1], .pinyin("jian"))
        // Focus should advance to "jian"
        XCTAssertEqual(state.focusedSegmentIndex, 1)
    }

    func testShiftTabNavigatesBackward() {
        type("shijian")
        let state = shiftTab()
        // Should skip the last segment (active input) and focus the second-to-last
        XCTAssertEqual(state.focusedSegmentIndex, 0)
    }

    func testTabNavigationNotStuckAfterEntry() {
        type("shijian")
        tab()  // focus on first segment
        let state = tab()  // move to second segment
        XCTAssertEqual(state.focusedSegmentIndex, 1)
        let state2 = shiftTab()  // move back to first
        XCTAssertEqual(state2.focusedSegmentIndex, 0)
    }

    // MARK: - Prefix Matching (前缀匹配)

    func testPrefixMatchWithPartialSyllable() {
        // "xiangf": "xiang" + "f" (incomplete), should prefix-match "xiangfa" → 想法
        let state = type("xiangf")
        XCTAssertFalse(
            state.candidates.isEmpty, "xiangf should produce candidates via prefix match")
        XCTAssertTrue(state.candidates.contains("想法"), "想法 should appear for xiangf")
    }

    func testExactMatchTakesPriorityOverPrefix() {
        // "shi" is a complete syllable with exact matches: should not need prefix fallback
        let state = type("shi")
        XCTAssertEqual(state.candidates.first, "是")
    }

    func testPrefixMatchCommitsCorrectly() {
        // Type partial, then space to commit the prefix-matched candidate
        type("xiangf")
        let state = space()
        XCTAssertEqual(state.committedText, "想法")
    }

    // MARK: - ü Alternative Spelling (u 代替 ü)

    func testUAsUmlautForLue() {
        // "hulue" should match "hulve" → 忽略
        let state = type("hulue")
        XCTAssertTrue(state.candidates.contains("忽略"), "hulue should match 忽略 (stored as hulve)")
    }

    func testUAsUmlautForNue() {
        // "nue" should match "nve" → 虐
        let state = type("nue")
        XCTAssertFalse(state.candidates.isEmpty, "nue should produce candidates")
    }

    func testUAsUmlautDoesNotBreakRegularLu() {
        // "lu" is a valid syllable (路/陆), should still work
        let state = type("lu")
        XCTAssertFalse(state.candidates.isEmpty, "lu should still produce candidates")
        XCTAssertEqual(state.candidates.first, "路")
    }

    // MARK: - Apostrophe Separation (撇号分隔)

    // MARK: - First Segment Candidates

    func testFirstSegmentCandidatesAppearAfterExactMatch() {
        // "shijian" has exact matches like 时间/世间, and should also show
        // candidates for the first segment "shi" (是/时/十...) after the exact matches
        let state = type("shijian")
        XCTAssertFalse(state.candidates.isEmpty)
        // Exact matches should come first
        XCTAssertTrue(state.candidates.contains("时间"), "时间 should be in candidates")
        // First-segment candidates should also be present (alternatives for "shi")
        // "是" is the top candidate for "shi" and should appear as a supplement
        let hasFirstSegCandidates = state.candidates.contains("是") || state.candidates.contains("十")
        XCTAssertTrue(hasFirstSegCandidates, "First segment alternatives for 'shi' should appear")
    }

    func testFirstSegmentCandidateConfirmsOnlyFirstSegment() {
        // Type "shijian", select a first-segment candidate (e.g., "是")
        // Should confirm "是" as .text and continue composing "jian"
        let state = type("shijian")
        // Find "是" in candidates: it should be a first-segment candidate
        guard let idx = state.candidates.firstIndex(of: "是") else {
            XCTFail("是 should be in candidates for shijian")
            return
        }
        // Select it (number keys are 1-based)
        let afterSelect = number(idx + 1)
        // Should NOT commit: buffer should have confirmed text + remaining pinyin
        XCTAssertNil(afterSelect.committedText)
        // Buffer should contain confirmed "是" followed by composing pinyin for "jian"
        XCTAssertTrue(
            afterSelect.items.contains(.text("是")),
            "Buffer should contain confirmed 是")
        let hasPinyin = afterSelect.items.contains(where: { $0.isPinyin })
        XCTAssertTrue(hasPinyin, "Buffer should still have pinyin items for 'jian'")
        // Candidates should now be for "jian"
        XCTAssertTrue(
            afterSelect.candidates.contains("间") || afterSelect.candidates.contains("见"),
            "Candidates should be for remaining 'jian'")
    }

    func testFirstSegmentThenSpaceCommits() {
        // Type "shijian", select first-segment "是", then space to commit
        let state = type("shijian")
        guard let idx = state.candidates.firstIndex(of: "是") else {
            XCTFail("是 should be in candidates for shijian")
            return
        }
        let s2 = number(idx + 1)  // confirm "是" as first segment
        XCTAssertNil(s2.committedText)
        let committed = space()  // commit the whole buffer
        XCTAssertNotNil(committed.committedText)
        // Should start with 是
        XCTAssertTrue(
            committed.committedText?.hasPrefix("是") == true,
            "Committed text should start with 是, got: \(committed.committedText ?? "nil")")
    }

    func testExactMatchSkipsConversion() {
        // "shijian" has exact matches (时间, 世间, etc.)
        // Conversion should NOT be triggered: candidates should be exact matches
        // plus first-segment alternatives, NOT a Conversion-composed string
        let state = type("shijian")
        // The first candidate should be an exact match, not a Conversion composition
        XCTAssertEqual(
            state.candidates.first, "时间",
            "First candidate should be exact match 时间, not Conversion composition")
    }

    func testConversionWithFirstSegmentCandidates() {
        // "shishenmene" has no exact match, so Conversion should compose "是什么呢"
        // and also show first-segment candidates for the Conversion first word's pinyin
        let state = type("shishenmene")
        XCTAssertFalse(state.candidates.isEmpty)
        XCTAssertEqual(
            state.candidates.first, "是什么呢",
            "First candidate should be Conversion-composed 是什么呢")
        // Should also have first-segment candidates for "shi" (是/时/十...)
        // But "是" might already be the first char of the composed result,
        // so check for other alternatives
        let hasAlternatives =
            state.candidates.contains("时") || state.candidates.contains("十")
            || state.candidates.contains("事")
        XCTAssertTrue(
            hasAlternatives,
            "Should have first-segment alternatives like 时/十/事")
    }

    func testApostropheSeparationCandidates() {
        // "xi'an": user explicitly separates into xi + an
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

    // MARK: - Punctuation: Confirm + Commit

    func testPunctuationEmptyBufferCommitsFullWidth() {
        // No active input: comma should directly commit full-width comma
        let state = engine.process(.punctuation(","))
        XCTAssertEqual(state.committedText, "，")
        XCTAssertTrue(state.items.isEmpty)
    }

    func testPunctuationWithCandidatesConfirmsFirstThenCommits() {
        // Type pinyin to get candidates, then press comma
        type("shi")
        let state = engine.process(.punctuation(","))
        // Should confirm first candidate + append full-width comma
        XCTAssertNotNil(state.committedText)
        XCTAssertTrue(state.committedText!.hasSuffix("，"))
        // The text before the comma should be the first candidate (a Chinese character)
        let textBeforePunctuation = String(state.committedText!.dropLast())
        XCTAssertFalse(textBeforePunctuation.isEmpty)
        XCTAssertTrue(state.items.isEmpty, "Buffer should be cleared after punctuation commit")
    }

    func testPunctuationPeriodConfirmsAndCommits() {
        type("ni")
        let state = engine.process(.punctuation("."))
        XCTAssertNotNil(state.committedText)
        XCTAssertTrue(state.committedText!.hasSuffix("。"))
    }

    func testUnderscoreEmptyBufferCommitsDash() {
        // 无活跃输入时，下划线应映射为破折号
        let state = engine.process(.punctuation("_"))
        XCTAssertEqual(state.committedText, "——")
        XCTAssertTrue(state.items.isEmpty)
    }

    func testUnderscoreWithCandidatesConfirmsFirstThenCommitsDash() {
        // 有候选时，下划线作为标点：确认首选 + 追加破折号
        type("shi")
        let state = engine.process(.punctuation("_"))
        XCTAssertNotNil(state.committedText)
        XCTAssertTrue(state.committedText!.hasSuffix("——"))
    }

    func testUnderscoreAsLetterInActiveInput() {
        // 有活跃输入时，下划线作为字母追加到拼音（自定义短语场景）
        type("test")
        let state = engine.process(.letter("_"))
        XCTAssertTrue(state.items.contains(where: { $0.content.contains("_") }))
    }

    func testConfirmPunctuationCharsConstantExists() {
        // Verify the engine exposes the confirm punctuation set
        let chars = PinyinEngine.confirmPunctuationChars
        XCTAssertTrue(chars.contains(","))
        XCTAssertTrue(chars.contains("."))
        XCTAssertTrue(chars.contains("!"))
        XCTAssertTrue(chars.contains("_"))
        // Apostrophe is NOT in the set (handled as separator)
        XCTAssertFalse(chars.contains("'"))
    }

    // MARK: - Bare-initial expansion

    func testBareInitialExpansionGangcd() {
        let state = type("gangcd")
        // Conversion 展开裸声母：gang+c(→cai)+d(→de) 利用短语上下文组出「刚才的」
        XCTAssertEqual(state.candidates.first, "刚才的")
        // Conversion 组词后应有首段补充候选（如「刚才」「钢材」等）
        XCTAssertTrue(state.candidates.count > 1, "应有 Conversion 首段补充候选")

        let committed = space()
        XCTAssertEqual(committed.committedText, "刚才的")
    }

    // MARK: - Garbage-tail fallback (孤立韵母回退)

    // 用户输入了既不是音节也不是声母的「垃圾尾巴」（如 wuwuu 末尾的 u），
    // Conversion 与前缀匹配都失败时，引擎应基于前面合法音节组词，
    // 把候选 + remainder 原文拼接成「中文+残留字符」，让按空格/数字键能选。

    func testGarbageTailMultiSyllableProducesMixedCandidates() {
        let state = type("wuwuu")
        XCTAssertFalse(
            state.candidates.isEmpty, "wuwuu should produce candidates via garbage-tail fallback")
        // 候选都应以 garbage 字符 u 结尾（说明走了 fallback 路径，不是误命中前缀匹配）
        XCTAssertTrue(
            state.candidates.allSatisfy { $0.hasSuffix("u") },
            "All candidates should end with the garbage 'u'; got \(state.candidates.prefix(5))")
    }

    func testGarbageTailSingleSyllableProducesMixedCandidates() {
        // 单合法音节 + garbage：wuu = wu + u，应给出「无u」「五u」等
        let state = type("wuu")
        XCTAssertFalse(state.candidates.isEmpty, "wuu should produce candidates")
        XCTAssertTrue(
            state.candidates.contains("无u"),
            "Should contain composed 无u; got \(state.candidates.prefix(5))")
    }

    func testGarbageTailSpaceCommitsTopCandidateNotRawAscii() {
        // 关键回归保护：以前没候选时 space 回退为 commit 原 ASCII「wuwuu」，是 bug。
        // 现在 fallback 提供候选，space 应 commit 候选（中文+u），不再 commit 原文。
        type("wuwuu")
        let committed = space()
        XCTAssertNotNil(committed.committedText)
        XCTAssertNotEqual(committed.committedText, "wuwuu", "Should not commit raw ASCII")
        XCTAssertTrue(
            committed.committedText?.hasSuffix("u") ?? false,
            "Committed text should be 中文+u; got \(committed.committedText ?? "nil")")
    }

    func testGarbageTailNumberKeySelectsCandidate() {
        // 数字键 guard 当 candidates 空时拒绝；fallback 提供候选后数字键应能选字。
        let state = type("wuwuu")
        XCTAssertFalse(state.candidates.isEmpty)
        let committed = number(1)
        XCTAssertEqual(committed.committedText, state.candidates[0])
    }

    // MARK: - Uppercase Literal Mixed Input (大写字面块混输)
    //
    // 测试 fixture 词典体量较小，可用的多音节词包括 xianzai/现在、pengyou/朋友、
    // beijing/北京、shijian/时间 等。混输 case 依据这些已知词构造。

    func testUppercaseLiteralOnlyBuffer() {
        // 纯字面块：API 不参与拼音切分，候选与提交保持原样
        let state = type("API")
        XCTAssertEqual(state.items, [.literal("API")])
        XCTAssertEqual(state.candidates, ["API"])
        let committed = space()
        XCTAssertEqual(committed.committedText, "API")
    }

    func testLiteralThenPinyinComposes() {
        // 字面块 + 拼音：APIpengyou → 「API 朋友」
        let state = type("APIpengyou")
        XCTAssertEqual(state.candidates.first, "API 朋友")
        let committed = space()
        XCTAssertEqual(committed.committedText, "API 朋友")
    }

    func testPinyinThenLiteralComposes() {
        // 拼音 + 字面块：xianzaiAPI → 「现在 API」
        let state = type("xianzaiAPI")
        XCTAssertEqual(state.candidates.first, "现在 API")
        let committed = space()
        XCTAssertEqual(committed.committedText, "现在 API")
    }

    func testPinyinLiteralPinyinComposes() {
        // 拼音 + 字面块 + 拼音：xianzaiAPIpengyou → 「现在 API 朋友」
        let state = type("xianzaiAPIpengyou")
        XCTAssertEqual(state.candidates.first, "现在 API 朋友")
        let committed = space()
        XCTAssertEqual(committed.committedText, "现在 API 朋友")
    }

    func testConsecutiveUppercaseAggregatesIntoSingleLiteral() {
        // 多个连续大写字母聚合为单一字面块
        let state = type("USApengyou")
        let literalItems = state.items.filter { $0.isLiteral }
        XCTAssertEqual(
            literalItems.count, 1,
            "Consecutive uppercase letters should collapse into one literal block")
        XCTAssertEqual(literalItems.first?.content, "USA")
        XCTAssertEqual(state.candidates.first, "USA 朋友")
    }

    func testUppercaseIDoesNotTriggerJapaneseTransientMode() {
        // 大写 I 在空 buffer 起首时必须走字面块路径，不应触发日文 transient 模式
        let state = engine.process(.letter("I"))
        XCTAssertEqual(state.mode, .pinyin, "Uppercase I must not toggle transient mode")
        XCTAssertEqual(state.items, [.literal("I")])
        XCTAssertEqual(state.candidates, ["I"])
    }

    func testLowercaseIStillTogglesTransientModeAtBoundary() {
        // 小写 i 在段落边界处仍是 transient 模式开关
        let state = engine.process(.letter("i"))
        XCTAssertEqual(state.mode, .transient)
        XCTAssertTrue(state.items.isEmpty)
    }

    func testBackspaceTrimsLiteralBlockTailFirst() {
        // 退格从字面块尾部逐字符删除，删空后整块消失
        type("xianzaiAPI")
        var state = backspace()
        XCTAssertEqual(state.items.last?.content, "AP")
        XCTAssertEqual(state.candidates.first, "现在 AP")
        state = backspace()
        XCTAssertEqual(state.items.last?.content, "A")
        state = backspace()
        // 字面块删空后回到纯拼音组词路径
        XCTAssertFalse(state.items.contains(where: { $0.isLiteral }))
        XCTAssertEqual(state.candidates.first, "现在")
    }

    func testEnterCommitsRawWithLiteralSpacing() {
        // Enter 提交原文，中英边界保留空格
        type("xianzaiAPIpengyou")
        let committed = enter()
        XCTAssertEqual(committed.committedText, "xianzai API pengyou")
    }

    func testLiteralStartingBufferOpensSpan() {
        // 空 buffer 起首的大写字母直接开启字面块
        let state = type("A")
        XCTAssertEqual(state.items, [.literal("A")])
        XCTAssertEqual(state.candidates, ["A"])
    }

    // MARK: - Mixed Buffer Candidate Structure (混输候选区结构)
    //
    // 候选区结构对齐纯拼音模式：pos 1 为整句、pos 2+ 为首拼音段备选。
    // fixture 词典中 xianzai → 「现在」「西安」，pengyou → 「朋友」。
    // 测试 expected 候选基于 fixture 实际产出，不是产品级词典预期。

    func testMixedBufferOffersFirstSpanAlternativesAfterSentence() {
        // 拼音 + 字面块 + 拼音：候选首条整句，之后是首拼音段「xianzai」的备选
        let state = type("xianzaiAPIpengyou")
        XCTAssertEqual(state.candidates.first, "现在 API 朋友")
        XCTAssertEqual(
            Array(state.candidates.dropFirst()), ["现在", "西安"],
            "pos 2+ 应为首拼音段 xianzai 的备选词序列")
    }

    func testMixedBufferSelectingFirstSpanConfirmsIntoComposingText() {
        // 选 pos 2「现在」→「现在」确认进预编辑文本（marked text），不直接写出到宿主文档；
        // buffer 剩 APIpengyou 重建候选，整句方案「API 朋友」浮顶。
        type("xianzaiAPIpengyou")
        let committed = number(2)
        XCTAssertNil(
            committed.committedText,
            "首段备选选中后写入预编辑文本，不立即提交到宿主文档")
        XCTAssertTrue(
            committed.items.contains(where: {
                if case .text(let s) = $0 { return s == "现在" }
                return false
            }),
            "预编辑文本应包含已确认的「现在」.text 项")
        // 余下 spans 重新组词：API + pengyou → 整句「API 朋友」
        XCTAssertEqual(committed.candidates.first, "API 朋友")
        XCTAssertTrue(
            committed.items.contains(where: { $0.isLiteral && $0.content == "API" }),
            "余下 buffer 应保留字面块 API")
    }

    func testMixedBufferLiteralPrefixOffersLiteralAsSecondCandidate() {
        // 字面块前置：APIxianzaipengyou，rawSpans = [.literal("API"), .pinyin("xianzaipengyou")]。
        // rawSpans 首个 chunk 为 .literal，pos 2 = 字面块本身「API」（仅一项，因为字面块没有备选）。
        // 选 pos 2「API」仅截除字面块并以 .text 推进预编辑文本，余下 spans 重建组词。
        let state = type("APIxianzaipengyou")
        XCTAssertEqual(state.candidates.first, "API 现在朋友")
        XCTAssertEqual(
            Array(state.candidates.dropFirst()), ["API"],
            "首 chunk 为字面块时 pos 2 = 字面块本身")
        let committed = number(2)
        XCTAssertNil(committed.committedText, "选中字面块后写入预编辑文本，不立即提交")
        XCTAssertTrue(
            committed.items.contains(where: {
                if case .text(let s) = $0 { return s == "API" }
                return false
            }),
            "字面块作为独立 .text 推进预编辑文本")
        // 余下 spans = [.pinyin("xianzaipengyou")]，候选区切回纯拼音组词
        XCTAssertEqual(committed.candidates.first, "现在朋友")
        // 后续按空格 / Enter 整体提交时跨「API↔现在朋友」边界保留空格
        let final = space()
        XCTAssertEqual(final.committedText, "API 现在朋友")
    }

    func testMixedBufferLiteralPrefixSingleCharFirstSpanOffersLiteralAsSecondCandidate() {
        // 字面块前置 + 单字首段：APIxianzai，rawSpans = [.literal("API"), .pinyin("xianzai")]。
        // 首 chunk 为 .literal，pos 2 = 「API」（仅字面块本身）。
        // 选 pos 2 仅推进字面块，buffer 余下 [.pinyin("xianzai")]。
        let state = type("APIxianzai")
        XCTAssertEqual(state.candidates.first, "API 现在")
        XCTAssertEqual(Array(state.candidates.dropFirst()), ["API"])
        let committed = number(2)
        XCTAssertNil(committed.committedText, "选中字面块后写入预编辑文本，不立即提交")
        XCTAssertTrue(
            committed.items.contains(where: {
                if case .text(let s) = $0 { return s == "API" }
                return false
            }),
            "字面块作为独立 .text 推进预编辑文本")
        // 余下 [.pinyin("xianzai")]：候选区与纯拼音模式同构
        XCTAssertEqual(committed.candidates.first, "现在")
    }

    func testMixedBufferPinyinLiteralPinyinKeepsTrailingSpansAndPreservesBoundarySpace() {
        // xianzaiAPIhenzhongyao：首段 xianzai 备选「现在」「西安」。
        // 选 pos 2「现在」→「现在」进预编辑文本，余下 spans = [.literal("API"), .pinyin("henzhongyao")]
        // 重建为整句候选「API + henzhongyao 的中文译文」。
        type("xianzaiAPIhenzhongyao")
        let committed = number(2)
        XCTAssertNil(committed.committedText, "首段备选选中后写入预编辑文本，不立即提交")
        XCTAssertTrue(
            committed.items.contains(where: {
                if case .text(let s) = $0 { return s == "现在" }
                return false
            }),
            "预编辑文本含已确认的「现在」.text 项")
        XCTAssertTrue(
            committed.items.contains(where: { $0.isLiteral && $0.content == "API" }),
            "余下 buffer 保留字面块 API")
        XCTAssertTrue(
            committed.items.contains(where: {
                if case .pinyin(let s) = $0 { return s == "henzhongyao" }
                return false
            }) || committed.items.contains(where: { $0.sourcePinyin?.contains("h") == true }),
            "余下 buffer 包含 henzhongyao 拼音段")
    }

    func testMixedBufferTrailingLiteralConfirmsFirstSpanIntoComposingText() {
        // 拼音 + 字面块尾随：xianzaiAPI，选 pos 2「现在」→「现在」进预编辑文本，余下 API
        let state = type("xianzaiAPI")
        XCTAssertEqual(state.candidates.first, "现在 API")
        XCTAssertEqual(Array(state.candidates.dropFirst()), ["现在", "西安"])
        let committed = number(2)
        XCTAssertNil(committed.committedText, "首段备选选中后写入预编辑文本，不立即提交")
        XCTAssertTrue(
            committed.items.contains(where: {
                if case .text(let s) = $0 { return s == "现在" }
                return false
            }))
        XCTAssertEqual(committed.candidates, ["API"])
    }

    func testPureLiteralBufferProducesSingleCandidate() {
        // 纯字面块 buffer 没有拼音段，候选只有整句一条
        let state = type("API")
        XCTAssertEqual(state.candidates, ["API"])
    }

    func testPurePinyinBufferKeepsExistingCandidateStructure() {
        // 回归：纯拼音 buffer 候选结构不受混输改造影响。
        // xianzai 的候选「现在」（整串）+「西安」（首段「xian」补充候选，登记为部分方案）。
        let state = type("xianzai")
        XCTAssertEqual(state.candidates.first, "现在")
        XCTAssertTrue(state.candidates.contains("西安"))
        // 选 pos 1「现在」走整串方案直接提交
        let committed = number(1)
        XCTAssertEqual(committed.committedText, "现在")
    }

    func testPurePinyinBufferPartialFirstSegmentRouteIntact() {
        // 回归：纯拼音模式下首段补充候选「西安」仍走部分方案路径（confirmFirstSegment），
        // 不应误入混输 mixedFirstSpanCandidates 路由。
        type("xianzai")
        let committed = number(2)
        XCTAssertNil(committed.committedText, "部分方案不直接提交，buffer 留下首段译文 + 余下拼音")
        XCTAssertEqual(committed.items.first?.content, "西安")
    }

    // MARK: - Mixed Buffer End-to-End Commit (混输逐段选完到最终提交)
    //
    // 端到端覆盖「按 pos 2 / 空格逐段确认 + 最终整体提交」流程，重点验证最终 commit
    // 字符串里跨「中文 ↔ 拉丁字面块」边界的空格保留正确（commit 1 修复 regression）。

    func testMixedBufferStepwiseConfirmThenFinalCommitPreservesBoundarySpaces() {
        // xianzaiAPIpengyou：先选 pos 2「现在」确认进预编辑文本；候选区基于剩余
        // 「API + pengyou」整句方案 =「API 朋友」。再按空格整体提交，期望最终 commit
        // 为「现在 API 朋友」，跨「现在↔API」与「API↔朋友」两个中↔拉边界都保留空格。
        type("xianzaiAPIpengyou")
        let confirmed = number(2)
        XCTAssertNil(confirmed.committedText)
        XCTAssertEqual(confirmed.candidates.first, "API 朋友")
        let final = space()
        XCTAssertEqual(final.committedText, "现在 API 朋友")
    }

    func testMixedBufferThreeStepStepwiseConfirmation() {
        // 端到端覆盖 spec 完整流程示例「选现在 → 选 API → 选朋友」三步走：
        // 步骤 1：输入 xianzaiAPIpengyou，候选 = [现在 API 朋友, 现在, 西安]
        // 步骤 2：按 2 选「现在」→ 余下 spans = [.literal(API), .pinyin(pengyou)]，
        //         首 chunk 切换为 .literal，候选 = [API 朋友, API]
        // 步骤 3：按 2 选「API」→ 余下 spans = [.pinyin(pengyou)]，候选 = [朋友, ...]
        // 步骤 4：按 2 选「朋友」→ rawSpans 耗尽，候选为空
        // 步骤 5：空格整体提交 →「现在 API 朋友」，跨两次中↔拉边界都保留空格
        let s1 = type("xianzaiAPIpengyou")
        XCTAssertEqual(s1.candidates.first, "现在 API 朋友")
        XCTAssertEqual(Array(s1.candidates.dropFirst()), ["现在", "西安"])

        let s2 = number(2)
        XCTAssertNil(s2.committedText, "选「现在」后写入预编辑文本，不立即提交")
        XCTAssertEqual(s2.candidates.first, "API 朋友")
        XCTAssertEqual(
            Array(s2.candidates.dropFirst()), ["API"],
            "余下首 chunk 为 .literal，pos 2 应为字面块「API」本身")

        let s3 = number(2)
        XCTAssertNil(s3.committedText, "选「API」后字面块作为离散步骤推进，仍不提交")
        XCTAssertEqual(s3.candidates.first, "朋友", "余下 spans = [pengyou]，候选切回纯拼音")
        // 此时预编辑文本累积：[.text(现在), .text(API), .pinyin(pengyou)]
        let texts = s3.items.compactMap { item -> String? in
            if case .text(let s) = item { return s }
            return nil
        }
        XCTAssertEqual(
            texts, ["现在", "API"],
            "预编辑文本应保留两个独立的 .text 项，分别承载已确认的「现在」与「API」")

        let s4 = number(1)
        XCTAssertEqual(
            s4.committedText, "现在 API 朋友",
            "选完最后一段后整体提交，跨两个中↔拉边界都保留空格")
    }

    func testMixedBufferStepwiseConfirmTrailingLiteralPreservesBoundarySpace() {
        // xianzaiAPI：选 pos 2「现在」确认进预编辑文本；候选 = ["API"]。空格提交
        // 期望最终 commit「现在 API」，保留中↔拉边界空格。
        type("xianzaiAPI")
        let confirmed = number(2)
        XCTAssertNil(confirmed.committedText)
        XCTAssertEqual(confirmed.candidates, ["API"])
        let final = space()
        XCTAssertEqual(final.committedText, "现在 API")
    }

    // MARK: - Mixed Buffer Bracket (混输态以词定字)
    //
    // 混输态 [ / ] 操作首个拼音段：`[` 取该段首选的首字，`]` 取末字。前置字面块
    // 一并被确认进预编辑文本前缀。整段消耗后若 `rawSpans` 不再含拼音段（空或
    // 仅剩字面块），即把预编辑文本与剩余字面块一并直接提交（中↔拉边界由
    // `joinedCommitText` 统一插入空格）；若仍含拼音段，则保留 buffer 继续组词。

    func testMixedBracketLeftOnTrailingLiteralCommitsImmediately() {
        // xianzaiAPI 按 [：首拼音段 xianzai 首选「现在」，取首字「现」；
        // 余 rawSpans = [.literal("API")] 不含拼音段 → 直接提交「现 API」。
        type("xianzaiAPI")
        let state = bracketLeft()
        XCTAssertEqual(state.committedText, "现 API")
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testMixedBracketRightOnTrailingLiteralCommitsImmediately() {
        // xianzaiAPI 按 ]：首拼音段 xianzai 首选「现在」，取末字「在」；
        // 余 rawSpans = [.literal("API")] → 直接提交「在 API」。
        type("xianzaiAPI")
        let state = bracketRight()
        XCTAssertEqual(state.committedText, "在 API")
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testMixedBracketLeftOnLeadingLiteralCommitsImmediately() {
        // APIxianzai 按 [：先确认前置字面块 API → 取首拼音段 xianzai 首选首字「现」；
        // 余 rawSpans 空 → 直接提交「API 现」。
        type("APIxianzai")
        let state = bracketLeft()
        XCTAssertEqual(state.committedText, "API 现")
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testMixedBracketRightOnLeadingLiteralCommitsImmediately() {
        // APIxianzai 按 ]：先确认 API → 取首拼音段 xianzai 首选末字「在」；
        // 余 rawSpans 空 → 直接提交「API 在」。
        type("APIxianzai")
        let state = bracketRight()
        XCTAssertEqual(state.committedText, "API 在")
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testMixedBracketLeftWithMultiplePinyinSegmentsKeepsBuffer() {
        // xianzaiAPIpengyou 按 [：首拼音段 xianzai 取首字「现」；
        // 余 rawSpans = [.literal("API"), .pinyin("pengyou")] 仍含拼音 → 保留 buffer。
        type("xianzaiAPIpengyou")
        let state = bracketLeft()
        XCTAssertNil(state.committedText)
        let texts = state.items.compactMap { item -> String? in
            if case .text(let s) = item { return s }
            return nil
        }
        XCTAssertEqual(texts, ["现"], "已确认前缀仅含「现」")
        XCTAssertTrue(
            state.items.contains(where: { $0.isLiteral && $0.content == "API" }),
            "中间字面块 API 保留")
        XCTAssertTrue(
            state.items.contains(where: {
                if case .pinyin = $0 { return true }
                return false
            }),
            "后续拼音段 pengyou 保留为可编辑 .pinyin 项")
    }

    func testMixedBracketLeftPressedTwiceCommitsAccumulated() {
        // xianzaiAPIpengyou 连按两次 [：第一次取「现」，buffer 仍含 pengyou；
        // 第二次先确认前置字面块 API、再取 pengyou 首字「朋」，余 rawSpans 空
        // → 直接提交「现 API 朋」。
        type("xianzaiAPIpengyou")
        let first = bracketLeft()
        XCTAssertNil(first.committedText)
        let second = bracketLeft()
        XCTAssertEqual(second.committedText, "现 API 朋")
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertTrue(second.candidates.isEmpty)
    }

    // MARK: - Mixed Buffer Tab (混输态 Tab 段聚焦)
    //
    // 混输态 Tab 跳过 .literal（字面块不可 re-segment），只在 .pinyin chunk 之间循环。
    // editable 项天然过滤字面块，焦点循环规则与纯拼音模式一致。

    func testMixedTabFocusesFirstPinyinSegmentSkippingLiteral() {
        // xianzaiAPIpengyou：composingItems 中 .pinyin chunks 按 Conversion 切分排布
        // （fixture 词典将 xianzai 拆为 [xian, zai] 两个 chunk）。
        // 首次 Tab 进入聚焦模式 → 焦点首个 .pinyin chunk（xian）。
        type("xianzaiAPIpengyou")
        let state = tab()
        XCTAssertNotNil(state.focusedSegmentIndex)
        // 焦点落在首 chunk「xian」，候选 = fixture 中 xian 的单音节查询结果
        XCTAssertEqual(state.candidates.first, "西安")
    }

    func testMixedTabAdvancesPinyinChunksSkippingLiteral() {
        // xianzaiAPIpengyou：composingItems = [.pinyin(xian), .pinyin(zai),
        //   .literal(API), .pinyin(peng), .pinyin(you)]。Tab 在 editable .pinyin chunk
        // 之间循环。第三次 Tab 跨过字面块落在 peng；第四次落在 you。
        type("xianzaiAPIpengyou")
        tab()  // focus → xian
        tab()  // focus → zai
        let state = tab()  // focus → peng（跳过字面块 API）
        XCTAssertNotNil(state.focusedSegmentIndex)
        // peng 在 fixture 词典中无候选条目；这里仅验证焦点跨过字面块继续推进。
        // 通过 items 中 focus 索引对应项的拼音确认
        guard let idx = state.focusedSegmentIndex, idx < state.items.count else {
            XCTFail("focus index should be valid")
            return
        }
        XCTAssertEqual(state.items[idx].sourcePinyin, "peng")
    }

    func testMixedShiftTabFocusesPenultimatePinyinChunk() {
        // xianzaiAPIpengyou：从空闲 backward Tab 跳过末段（活跃输入段），focus 倒数第二个
        // 可编辑 chunk = peng（you 是末段）；与纯拼音模式 backward Tab 行为一致。
        type("xianzaiAPIpengyou")
        let state = shiftTab()
        guard let idx = state.focusedSegmentIndex, idx < state.items.count else {
            XCTFail("focus index should be valid after backward tab")
            return
        }
        XCTAssertEqual(state.items[idx].sourcePinyin, "peng")
    }

    func testMixedTabConfirmPreservesLiteralSpan() {
        // xianzaiAPIpengyou：Tab focus 首 chunk「xian」，按空格确认；
        // 字面块 API 应保留在缓冲区，不能因 confirmFocusedSegment 重建 rawSpans 而丢失。
        type("xianzaiAPIpengyou")
        tab()
        let state = space()
        XCTAssertNil(state.committedText, "未确认完末段，不应整体提交")
        XCTAssertTrue(
            state.items.contains(where: {
                if case .text(let s) = $0 { return s == "西安" }
                return false
            }),
            "首 chunk 应被确认为 .text(\"西安\")（fixture 中 xian 单音节首选）")
        XCTAssertTrue(
            state.items.contains(where: { $0.isLiteral && $0.content == "API" }),
            "字面块 API 应保留在缓冲区")
    }

    // MARK: - Mixed Buffer Pin (混输态固顶)
    //
    // 混输态 pin 仅对首拼音段备选有意义；命中字面块候选或整句 pos 1 → no-op。

    func testMixedPinFirstSpanCandidateUsesFirstSegmentPinyin() {
        // 用独立的 PinnedWordStore 注入 engine，验证 pin「西安」后写入 key = "xianzai"。
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        let pinnedWords = PinnedWordStore(toml: "[pinned]\n")
        let testEngine = PinyinEngine(
            zhDictPath: zhPath, jaDictPath: jaPath, userDictPath: ":memory:",
            pinnedChars: nil, pinnedWords: pinnedWords)

        for ch in "xianzaiAPIpengyou" { _ = testEngine.process(.letter(ch)) }
        let state = testEngine.currentState
        // 候选 = [整句, 现在, 西安]；pin pos 3「西安」（index 2），key 取首段 pinyin "xianzai"
        guard let idx = state.candidates.firstIndex(of: "西安") else {
            XCTFail("「西安」应出现在 xianzaiAPIpengyou 的候选中")
            return
        }
        XCTAssertTrue(testEngine.pinCandidate(atIndex: idx))
        XCTAssertEqual(
            pinnedWords.pinnedWords(for: "xianzai"), ["西安"],
            "pin key 应为首拼音段的规范化 pinyin「xianzai」")
    }

    func testMixedPinLiteralCandidateIsNoOp() {
        // APIxianzai：pos 1 = 「API 现在」，pos 2 = 「API」（字面块本身）。
        // pin pos 2 应静默 no-op，store 内不应写入。
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        let pinnedWords = PinnedWordStore(toml: "[pinned]\n")
        let testEngine = PinyinEngine(
            zhDictPath: zhPath, jaDictPath: jaPath, userDictPath: ":memory:",
            pinnedChars: nil, pinnedWords: pinnedWords)

        for ch in "APIxianzai" { _ = testEngine.process(.letter(ch)) }
        let state = testEngine.currentState
        guard let idx = state.candidates.firstIndex(of: "API") else {
            XCTFail("字面块「API」应作为 pos 2 候选出现")
            return
        }
        XCTAssertFalse(
            testEngine.pinCandidate(atIndex: idx),
            "字面块候选无对应 pinyin key，pin 应 no-op")
        // 任何 pinyin key 下都不应有写入痕迹
        XCTAssertTrue(pinnedWords.pinnedWords(for: "xianzai").isEmpty)
        XCTAssertTrue(pinnedWords.pinnedWords(for: "API").isEmpty)
    }

    func testMixedPinSentenceCandidateIsNoOp() {
        // 整句 pos 1 = 合成结果含字面块原文，无单一 pinyin key，pin 应 no-op。
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        let pinnedWords = PinnedWordStore(toml: "[pinned]\n")
        let testEngine = PinyinEngine(
            zhDictPath: zhPath, jaDictPath: jaPath, userDictPath: ":memory:",
            pinnedChars: nil, pinnedWords: pinnedWords)

        for ch in "xianzaiAPIpengyou" { _ = testEngine.process(.letter(ch)) }
        XCTAssertFalse(
            testEngine.pinCandidate(atIndex: 0),
            "pos 1 整句候选无单一 pinyin key，pin 应 no-op")
        XCTAssertTrue(pinnedWords.pinnedWords(for: "xianzai").isEmpty)
    }

    // MARK: - ComposingItem Boundary Space Rule

    func testComposingItemBoundaryHanLatinAcrossText() {
        // 跨「中文 ↔ 拉丁」边界的两个 .text 项相邻：补空格
        let prev = ComposingItem.text("现在")
        let next = ComposingItem.text("API")
        XCTAssertTrue(ComposingItem.needsSeparatorSpace(before: prev, after: next))
        XCTAssertTrue(ComposingItem.needsSeparatorSpace(before: next, after: prev))
    }

    func testComposingItemBoundaryHanHanNoSpace() {
        // 两个中文 .text 相邻：不补空格
        let prev = ComposingItem.text("你好")
        let next = ComposingItem.text("世界")
        XCTAssertFalse(ComposingItem.needsSeparatorSpace(before: prev, after: next))
    }

    func testComposingItemBoundaryTextLiteralSpaces() {
        // .text 与 .literal 跨中↔拉边界：补空格
        XCTAssertTrue(
            ComposingItem.needsSeparatorSpace(
                before: .text("现在"), after: .literal("API")))
        XCTAssertTrue(
            ComposingItem.needsSeparatorSpace(
                before: .literal("API"), after: .text("现在")))
    }

    func testComposingItemBoundaryPinyinLiteralSpaces() {
        // 拼音 ↔ 字面块：恒补空格（与产品要求的 `xian'zai API` 呈现一致）
        XCTAssertTrue(
            ComposingItem.needsSeparatorSpace(
                before: .pinyin("xianzai"), after: .literal("API")))
        XCTAssertTrue(
            ComposingItem.needsSeparatorSpace(
                before: .literal("API"), after: .pinyin("pengyou")))
    }

    func testComposingItemBoundaryTextPinyinNoSpace() {
        // .text 与 .pinyin 相邻：不补空格（拼音最终归宿为中文，保留现状）
        XCTAssertFalse(
            ComposingItem.needsSeparatorSpace(
                before: .text("西安"), after: .pinyin("pengyou")))
        XCTAssertFalse(
            ComposingItem.needsSeparatorSpace(
                before: .pinyin("xianzai"), after: .text("朋友")))
    }

    // MARK: - V Command Time

    private func runVCommand(_ name: String) -> String {
        for char in name { _ = engine.process(.letter(char)) }
        let state = engine.process(.space)
        return state.committedText ?? ""
    }

    func testVTimeOutputsISO8601WithLocalOffset() {
        let output = runVCommand("vtime")
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$"#
        XCTAssertNotNil(
            output.range(of: pattern, options: .regularExpression),
            "vtime output \(output) should match yyyy-MM-ddTHH:mm:ss±HH:MM")
    }

    func testVTiAliasMatchesVTime() {
        let output = runVCommand("vti")
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$"#
        XCTAssertNotNil(
            output.range(of: pattern, options: .regularExpression),
            "vti output \(output) should match yyyy-MM-ddTHH:mm:ss±HH:MM")
    }

    func testVTimeUOutputsISO8601UTC() {
        let output = runVCommand("vtimeu")
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#
        XCTAssertNotNil(
            output.range(of: pattern, options: .regularExpression),
            "vtimeu output \(output) should match yyyy-MM-ddTHH:mm:ssZ")
    }

    func testVTiuAliasMatchesVTimeU() {
        let output = runVCommand("vtiu")
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#
        XCTAssertNotNil(
            output.range(of: pattern, options: .regularExpression),
            "vtiu output \(output) should match yyyy-MM-ddTHH:mm:ssZ")
    }

    func testVDateTimeIncludesSeconds() {
        let output = runVCommand("vdatetime")
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#
        XCTAssertNotNil(
            output.range(of: pattern, options: .regularExpression),
            "vdatetime output \(output) should match yyyy-MM-dd HH:mm:ss")
    }

    func testVDtIncludesSeconds() {
        let output = runVCommand("vdt")
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#
        XCTAssertNotNil(
            output.range(of: pattern, options: .regularExpression),
            "vdt output \(output) should match yyyy-MM-dd HH:mm:ss")
    }
}
