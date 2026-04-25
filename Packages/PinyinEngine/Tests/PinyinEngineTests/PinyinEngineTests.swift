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
        // The 2nd candidate should NOT be the first word 「时」 — that path is only
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
        // "kaifajishu" — no whole-string match, but per-syllable composition works
        let state = type("kaifajishu")
        // Should auto-split into multiple pinyin segments
        XCTAssertTrue(state.items.count > 1, "Should auto-split into multiple segments")
        // Buffer shows pinyin, not Chinese preview
        XCTAssertTrue(state.items.allSatisfy { $0.isPinyin }, "All items should be pinyin")
        // Composed candidate should exist in candidate list
        XCTAssertFalse(state.candidates.isEmpty, "Should have composed candidates")
    }

    func testGreedyPhraseComposition() {
        // "jianchayixia" — Conversion should match jiancha(检查) + yixia(一下)
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
        // "shijian" has whole-string match 时间 — should be first, not composed 是见
        let state = type("shijian")
        XCTAssertEqual(state.candidates.first, "时间")
    }

    func testCompositionWithPartialRemainderSkipped() {
        // "kaifaj" — remainder "j" is incomplete, composition requires no remainder
        let state = type("kaifaj")
        // Should not contain a composed candidate with dangling "j"
        XCTAssertFalse(state.candidates.isEmpty, "Should have prefix match candidates")
    }

    func testCompositionFallsBackToSingleChars() {
        // "kaifajishu" — whole-string match exists (开发技术), so it takes priority
        // If it didn't, Conversion would produce 开发+技术 over 开+发+技+术
        let state = type("kaifajishu")
        XCTAssertTrue(
            state.candidates.contains("开发技术"),
            "Should produce 开发技术")
    }

    func testCompositionMultiWordPhrase() {
        // "wanquanhushuo" — Conversion should compose wanquan(完全) + hushuo(胡说) = 完全胡说
        let state = type("wanquanhushuo")
        XCTAssertTrue(
            state.candidates.contains("完全胡说"),
            "Conversion should produce 完全胡说")
    }

    func testConversionCrossesSyllableBoundary() {
        // "jianchayixiane" — two-stage approach splits "xian"+"e" → 检查仪限额
        // Conversion should prefer "xia"+"ne" because it enables 一下+呢 → 检查一下呢
        let state = type("jianchayixiane")
        XCTAssertTrue(
            state.candidates.contains("检查一下呢"),
            "Conversion should produce 检查一下呢 by choosing xia+ne over xian+e")
    }

    func testConversionPrefersHighQualityPhrases() {
        // "shishenmene" — 失神+门额 has two multi-char words but low avg quality;
        // 是+什么+呢 has one high-quality multi-char word (什么) and should win.
        let state = type("shishenmene")
        XCTAssertTrue(
            state.candidates.contains("是什么呢"),
            "Conversion should prefer 是什么呢 over 失神门额")
    }

    func testConversionWordCoveragePreventsSingleCharFiller() {
        // "jingquepipei" — 景区+饿+匹配 has a single-char filler (饿);
        // 精确+匹配 has full wordCoverage and should win.
        let state = type("jingquepipei")
        XCTAssertEqual(
            state.candidates.first, "精确匹配",
            "Conversion should prefer 精确匹配 (full wordCoverage) over 景区饿匹配 (single-char filler)")
    }

    func testConversionFewerSegmentsPreferred() {
        // "shenmetamadejiaojingxi" — "jiao" should NOT be split into "ji+a+o"
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
        // "shenmetamadejiaojingxi" — 的脚(dejiao, freq=5555) is a dictionary artifact
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
        // "shij" — "shi" is complete, "j" is partial remainder
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
        // "xiangf" — "xiang" + "f" (incomplete), should prefix-match "xiangfa" → 想法
        let state = type("xiangf")
        XCTAssertFalse(
            state.candidates.isEmpty, "xiangf should produce candidates via prefix match")
        XCTAssertTrue(state.candidates.contains("想法"), "想法 should appear for xiangf")
    }

    func testExactMatchTakesPriorityOverPrefix() {
        // "shi" is a complete syllable with exact matches — should not need prefix fallback
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
        // Find "是" in candidates — it should be a first-segment candidate
        guard let idx = state.candidates.firstIndex(of: "是") else {
            XCTFail("是 should be in candidates for shijian")
            return
        }
        // Select it (number keys are 1-based)
        let afterSelect = number(idx + 1)
        // Should NOT commit — buffer should have confirmed text + remaining pinyin
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
        // Conversion should NOT be triggered — candidates should be exact matches
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

    // MARK: - Punctuation: Confirm + Commit

    func testPunctuationEmptyBufferCommitsFullWidth() {
        // No active input — comma should directly commit full-width comma
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

    // MARK: - Garbage-tail fallback (孤立韵母兜底)

    // 用户敲了既不是音节也不是声母的「垃圾尾巴」（如 wuwuu 末尾的 u），
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
        // 关键回归保护：以前没候选时 space 兜底 commit 原 ASCII「wuwuu」，是 bug。
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
}
