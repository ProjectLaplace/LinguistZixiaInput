import XCTest

@testable import PinyinEngine

final class CustomPhraseStoreTests: XCTestCase {

    func testSingleValue() {
        let store = CustomPhraseStore(
            toml: """
                [phrases]
                addr = '上海市长宁区'
                """)
        XCTAssertEqual(store.phrases(for: "addr"), ["上海市长宁区"])
    }

    func testDoubleQuotedValue() {
        let store = CustomPhraseStore(
            toml: """
                [phrases]
                hello = "你好世界"
                """)
        XCTAssertEqual(store.phrases(for: "hello"), ["你好世界"])
    }

    func testInlineArray() {
        let store = CustomPhraseStore(
            toml: """
                [phrases]
                xl_ = ['α', 'β', 'γ']
                """)
        XCTAssertEqual(store.phrases(for: "xl_"), ["α", "β", "γ"])
    }

    func testMultiLineArray() {
        let store = CustomPhraseStore(
            toml: """
                [phrases]
                pi_ = [
                  'π',
                  '3.14',
                  '3.1415927'
                ]
                """)
        XCTAssertEqual(store.phrases(for: "pi_"), ["π", "3.14", "3.1415927"])
    }

    func testTripleQuotedString() {
        let store = CustomPhraseStore(
            toml: """
                [phrases]
                sign = '''
                --乘风破浪会有时--
                --直挂云帆济沧海--'''
                """)
        let phrases = store.phrases(for: "sign")
        XCTAssertEqual(phrases.count, 1)
        XCTAssertTrue(phrases[0].contains("乘风破浪"))
        XCTAssertTrue(phrases[0].contains("直挂云帆"))
    }

    func testTripleQuotedInArray() {
        let store = CustomPhraseStore(
            toml: """
                [phrases]
                art = [
                  '''
                  Line1
                  Line2''',
                  '''
                  Alt1
                  Alt2'''
                ]
                """)
        let phrases = store.phrases(for: "art")
        XCTAssertEqual(phrases.count, 2)
        XCTAssertTrue(phrases[0].contains("Line1"))
        XCTAssertTrue(phrases[1].contains("Alt1"))
    }

    func testCommentsAndBlankLines() {
        let store = CustomPhraseStore(
            toml: """
                # Comment at top
                [phrases]

                # A phrase
                haha = '^_^'
                # Another
                email = 'test@example.com'
                """)
        XCTAssertEqual(store.phrases(for: "haha"), ["^_^"])
        XCTAssertEqual(store.phrases(for: "email"), ["test@example.com"])
    }

    func testMissingPhrase() {
        let store = CustomPhraseStore(
            toml: """
                [phrases]
                addr = '上海市长宁区'
                """)
        XCTAssertEqual(store.phrases(for: "nonexistent"), [])
        XCTAssertFalse(store.hasPhrase("nonexistent"))
        XCTAssertTrue(store.hasPhrase("addr"))
    }

    func testIgnoresOtherSections() {
        let store = CustomPhraseStore(
            toml: """
                [other]
                foo = 'bar'

                [phrases]
                addr = '上海市长宁区'

                [more]
                baz = 'qux'
                """)
        XCTAssertEqual(store.phrases(for: "addr"), ["上海市长宁区"])
        XCTAssertEqual(store.phrases(for: "foo"), [])
    }

    func testRepeatedKeys() {
        // Same key defined multiple times → accumulated as multiple candidates
        let store = CustomPhraseStore(
            toml: """
                [phrases]
                alpha = 'α'
                alpha = 'β'
                alpha = 'γ'
                """)
        XCTAssertEqual(store.phrases(for: "alpha"), ["α", "β", "γ"])
    }

    func testEngineIntegration() {
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        let phrases = CustomPhraseStore(
            toml: """
                [phrases]
                addr = '上海市长宁区'
                haha = '^_^'
                """)
        let engine = PinyinEngine(
            zhDictPath: zhPath, jaDictPath: jaPath, userDictPath: ":memory:",
            customPhrases: phrases)

        // Type "addr" — custom phrase should be first candidate
        var state = engine.process(.letter("a"))
        state = engine.process(.letter("d"))
        state = engine.process(.letter("d"))
        state = engine.process(.letter("r"))
        XCTAssertEqual(state.candidates.first, "上海市长宁区")

        // Space commits the custom phrase
        state = engine.process(.space)
        XCTAssertEqual(state.committedText, "上海市长宁区")

        // Type "haha" — custom phrase should be first candidate
        state = engine.process(.letter("h"))
        state = engine.process(.letter("a"))
        state = engine.process(.letter("h"))
        state = engine.process(.letter("a"))
        XCTAssertEqual(state.candidates.first, "^_^")
    }

    func testEnginePhraseWithZero() {
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        let phrases = CustomPhraseStore(
            toml: """
                [phrases]
                xl0 = ['α', 'β', 'γ']
                """)
        let engine = PinyinEngine(
            zhDictPath: zhPath, jaDictPath: jaPath, userDictPath: ":memory:",
            customPhrases: phrases)

        // Type "xl0" — 0 续入 buffer 后触发 phrase 候选
        var state = engine.process(.letter("x"))
        state = engine.process(.letter("l"))
        state = engine.process(.letter("0"))
        XCTAssertEqual(state.candidates.first, "α")

        // Number key selects: xl02 doesn't exist as phrase, so 2 selects candidate #2
        state = engine.process(.number(2))
        XCTAssertEqual(state.committedText, "β")
    }

    func testEngineDigitInPhraseName() {
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        let phrases = CustomPhraseStore(
            toml: """
                [phrases]
                sz0 = ['壹', '贰', '叁']
                sz01 = ['⒈', '⒉', '⒊']
                """)
        let engine = PinyinEngine(
            zhDictPath: zhPath, jaDictPath: jaPath, userDictPath: ":memory:",
            customPhrases: phrases)

        // Type "sz0" — shows sz0 candidates
        var state = engine.process(.letter("s"))
        state = engine.process(.letter("z"))
        state = engine.process(.letter("0"))
        XCTAssertEqual(state.candidates.first, "壹")

        // Press 1 — appends to phrase name (sz01 exists), now shows sz01 candidates
        state = engine.process(.number(1))
        XCTAssertEqual(state.candidates.first, "⒈")

        // Space commits
        state = engine.process(.space)
        XCTAssertEqual(state.committedText, "⒈")
    }
}
