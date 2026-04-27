import XCTest

@testable import PinyinEngine

final class PinnedCharStoreTests: XCTestCase {

    // MARK: - 临时目录辅助

    /// 每个测试独占一个临时目录，结束时清理。
    private var scratchDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: scratchDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchDir = scratchDir {
            try? FileManager.default.removeItem(at: scratchDir)
        }
        try super.tearDownWithError()
    }

    private func writeTOML(_ content: String, name: String) throws -> String {
        let url = scratchDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - user-only 兼容（旧语义）

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

        // Type "de": pinned chars should be at the front
        var state = engine.process(.letter("d"))
        state = engine.process(.letter("e"))
        XCTAssertTrue(state.candidates.count >= 3)
        XCTAssertEqual(Array(state.candidates.prefix(3)), ["的", "地", "得"])

        // Type just "d": abbreviated pinyin pinned chars
        _ = engine.process(.esc)
        state = engine.process(.letter("d"))
        XCTAssertTrue(state.candidates.count >= 4)
        XCTAssertEqual(Array(state.candidates.prefix(4)), ["的", "地", "得", "大"])
    }

    // MARK: - 双层 init

    func testDualLayerMergesUserAndSys() throws {
        let sysPath = try writeTOML(
            """
            [pinned]
            d = "得"
            shi = "是时"
            """, name: "sys.toml")
        let userPath = try writeTOML(
            """
            [pinned]
            d = "的地"
            """, name: "user.toml")
        let store = PinnedCharStore(sysPath: sysPath, userPath: userPath)

        // user 在前、sys 在后，去重保留首次出现位置
        XCTAssertEqual(store.pinnedChars(for: "d"), ["的", "地", "得"])
        // sys-only 拼音仍可查到
        XCTAssertEqual(store.pinnedChars(for: "shi"), ["是", "时"])
    }

    func testDualLayerSysOnlyWhenUserNil() throws {
        let sysPath = try writeTOML(
            """
            [pinned]
            a = "啊"
            """, name: "sys.toml")
        let store = PinnedCharStore(sysPath: sysPath, userPath: nil)
        XCTAssertEqual(store.pinnedChars(for: "a"), ["啊"])
    }

    func testDualLayerUserOnlyWhenSysNil() throws {
        let userPath = try writeTOML(
            """
            [pinned]
            wo = "我"
            """, name: "user.toml")
        let store = PinnedCharStore(sysPath: nil, userPath: userPath)
        XCTAssertEqual(store.pinnedChars(for: "wo"), ["我"])
    }

    func testUserOverridesSysSameChar() throws {
        // 同字同拼音在两层各出现一次：合并后只出现一次（用户层位置）。
        let sysPath = try writeTOML(
            """
            [pinned]
            d = "的"
            """, name: "sys.toml")
        let userPath = try writeTOML(
            """
            [pinned]
            d = "的"
            """, name: "user.toml")
        let store = PinnedCharStore(sysPath: sysPath, userPath: userPath)
        XCTAssertEqual(store.pinnedChars(for: "d"), ["的"])
    }

    func testUserOrderedBeforeSysDistinctChars() throws {
        let sysPath = try writeTOML(
            """
            [pinned]
            d = "得"
            """, name: "sys.toml")
        let userPath = try writeTOML(
            """
            [pinned]
            d = "的"
            """, name: "user.toml")
        let store = PinnedCharStore(sysPath: sysPath, userPath: userPath)
        XCTAssertEqual(store.pinnedChars(for: "d"), ["的", "得"])
    }

    // MARK: - 写操作

    func testPinInsertsAtUserHead() throws {
        let userPath = scratchDir.appendingPathComponent("user.toml").path
        let store = PinnedCharStore(sysPath: nil, userPath: userPath)
        store.pin("的", forPinyin: "d")
        XCTAssertEqual(store.pinnedChars(for: "d"), ["的"])
    }

    func testPinMovesExistingToHead() throws {
        let userPath = try writeTOML(
            """
            [pinned]
            d = "地得"
            """, name: "user.toml")
        let store = PinnedCharStore(sysPath: nil, userPath: userPath)
        store.pin("得", forPinyin: "d")
        XCTAssertEqual(store.pinnedChars(for: "d"), ["得", "地"])
    }

    func testPinCopiesSysOnlyCharIntoUser() throws {
        // sys 层有「得」，user 层没有：pin 后应在 user 层队首出现。
        let sysPath = try writeTOML(
            """
            [pinned]
            d = "的得"
            """, name: "sys.toml")
        let userPath = scratchDir.appendingPathComponent("user.toml").path
        let store = PinnedCharStore(sysPath: sysPath, userPath: userPath)
        XCTAssertEqual(store.pinnedChars(for: "d"), ["的", "得"])

        store.pin("得", forPinyin: "d")
        // user: ["得"]，sys: ["的", "得"] → merge 后 ["得", "的"]
        XCTAssertEqual(store.pinnedChars(for: "d"), ["得", "的"])
    }

    func testUnpinUserRemovesFromUserNotSys() throws {
        let sysPath = try writeTOML(
            """
            [pinned]
            d = "得"
            """, name: "sys.toml")
        let userPath = try writeTOML(
            """
            [pinned]
            d = "的得"
            """, name: "user.toml")
        let store = PinnedCharStore(sysPath: sysPath, userPath: userPath)
        XCTAssertEqual(store.pinnedChars(for: "d"), ["的", "得"])

        store.unpinUser("的", forPinyin: "d")
        // user: ["得"]，sys: ["得"] → merge 去重 ["得"]
        XCTAssertEqual(store.pinnedChars(for: "d"), ["得"])

        // 即使把 user 层「得」也删除，sys 层「得」仍然在
        store.unpinUser("得", forPinyin: "d")
        XCTAssertEqual(store.pinnedChars(for: "d"), ["得"])
    }

    // MARK: - 持久化

    func testPinPersistsAcrossReload() throws {
        let userPath = scratchDir.appendingPathComponent("user.toml").path
        let store = PinnedCharStore(sysPath: nil, userPath: userPath)
        store.pin("的", forPinyin: "d")
        store.pin("地", forPinyin: "d")  // 现在 user: ["地", "的"]

        let reloaded = PinnedCharStore(sysPath: nil, userPath: userPath)
        XCTAssertEqual(reloaded.pinnedChars(for: "d"), ["地", "的"])
    }

    func testUnpinUserPersistsAcrossReload() throws {
        let userPath = try writeTOML(
            """
            [pinned]
            d = "的地得"
            """, name: "user.toml")
        let store = PinnedCharStore(sysPath: nil, userPath: userPath)
        store.unpinUser("地", forPinyin: "d")

        let reloaded = PinnedCharStore(sysPath: nil, userPath: userPath)
        XCTAssertEqual(reloaded.pinnedChars(for: "d"), ["的", "得"])
    }
}
