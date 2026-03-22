import XCTest

@testable import PinyinEngine

final class PinnedCharStoreTests: XCTestCase {

    func testBasicLookup() {
        let store = PinnedCharStore(
            toml: """
                [pinned]
                d = "的地得大"
                shi = "是时"
                """)
        XCTAssertEqual(store.pinnedChars(for: "d"), ["的", "地", "得", "大"])
        XCTAssertEqual(store.pinnedChars(for: "shi"), ["是", "时"])
    }

    func testEmptyValue() {
        let store = PinnedCharStore(
            toml: """
                [pinned]
                ba = ""
                """)
        XCTAssertEqual(store.pinnedChars(for: "ba"), [])
    }

    func testMissingSyllable() {
        let store = PinnedCharStore(
            toml: """
                [pinned]
                a = "啊"
                """)
        XCTAssertEqual(store.pinnedChars(for: "zzz"), [])
    }

    func testCommentsAndBlankLines() {
        let store = PinnedCharStore(
            toml: """
                # This is a comment
                [pinned]

                # Another comment
                wo = "我"
                de = "的地得"
                """)
        XCTAssertEqual(store.pinnedChars(for: "wo"), ["我"])
        XCTAssertEqual(store.pinnedChars(for: "de"), ["的", "地", "得"])
    }

    func testIgnoresOtherSections() {
        let store = PinnedCharStore(
            toml: """
                [other]
                foo = "bar"

                [pinned]
                ni = "你"

                [another]
                baz = "qux"
                """)
        XCTAssertEqual(store.pinnedChars(for: "ni"), ["你"])
        XCTAssertEqual(store.pinnedChars(for: "foo"), [])
    }

    func testEngineIntegration() {
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        let jaPath = Bundle.module.url(forResource: "ja_dict", withExtension: "db")!.path
        let pinned = PinnedCharStore(
            toml: """
                [pinned]
                de = "的地得"
                d = "的地得大"
                """)
        let engine = PinyinEngine(
            zhDictPath: zhPath, jaDictPath: jaPath, userDictPath: ":memory:",
            pinnedChars: pinned)

        // Type "de" — pinned chars should be at the front
        var state = engine.process(.letter("d"))
        state = engine.process(.letter("e"))
        XCTAssertTrue(state.candidates.count >= 3)
        XCTAssertEqual(Array(state.candidates.prefix(3)), ["的", "地", "得"])

        // Type just "d" — abbreviated pinyin pinned chars
        _ = engine.process(.esc)
        state = engine.process(.letter("d"))
        XCTAssertTrue(state.candidates.count >= 4)
        XCTAssertEqual(Array(state.candidates.prefix(4)), ["的", "地", "得", "大"])
    }
}
