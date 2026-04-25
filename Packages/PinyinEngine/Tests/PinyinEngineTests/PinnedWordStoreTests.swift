import XCTest

@testable import PinyinEngine

final class PinnedWordStoreTests: XCTestCase {

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

    // MARK: - 解析：单字符串简写

    func testParsesSingleStringValueAsSingletonArray() {
        let store = PinnedWordStore(
            toml: """
                [pinned]
                zhongguo = "中国"
                """)
        XCTAssertEqual(store.pinnedWords(for: "zhongguo"), ["中国"])
    }

    // MARK: - 解析：数组语法

    func testParsesArrayValueWithMultipleEntries() {
        let store = PinnedWordStore(
            toml: """
                [pinned]
                zhonggong = ["中共", "重工"]
                """)
        XCTAssertEqual(store.pinnedWords(for: "zhonggong"), ["中共", "重工"])
    }

    func testParsesSingleElementArray() {
        let store = PinnedWordStore(
            toml: """
                [pinned]
                zhongguo = ["中国"]
                """)
        XCTAssertEqual(store.pinnedWords(for: "zhongguo"), ["中国"])
    }

    func testCommentsAndBlankLines() {
        let store = PinnedWordStore(
            toml: """
                # leading comment
                [pinned]

                # mid-section comment
                zhongguo = ["中国"]
                zhonggong = ["中共", "重工"]
                """)
        XCTAssertEqual(store.pinnedWords(for: "zhongguo"), ["中国"])
        XCTAssertEqual(store.pinnedWords(for: "zhonggong"), ["中共", "重工"])
    }

    func testIgnoresOtherSections() {
        let store = PinnedWordStore(
            toml: """
                [other]
                foo = "bar"

                [pinned]
                zhongguo = ["中国"]

                [another]
                baz = "qux"
                """)
        XCTAssertEqual(store.pinnedWords(for: "zhongguo"), ["中国"])
        XCTAssertEqual(store.pinnedWords(for: "foo"), [])
    }

    func testMissingPinyinReturnsEmpty() {
        let store = PinnedWordStore(
            toml: """
                [pinned]
                zhongguo = ["中国"]
                """)
        XCTAssertEqual(store.pinnedWords(for: "zzz"), [])
    }

    // MARK: - 双层 init

    func testDualLayerMergesUserAndSys() throws {
        let sysPath = try writeTOML(
            """
            [pinned]
            zhongguo = ["中国"]
            zhonggong = ["重工"]
            """, name: "sys.toml")
        let userPath = try writeTOML(
            """
            [pinned]
            zhonggong = ["中共"]
            """, name: "user.toml")
        let store = PinnedWordStore(sysPath: sysPath, userPath: userPath)

        // user 在前、sys 在后，去重保留首次出现位置
        XCTAssertEqual(store.pinnedWords(for: "zhonggong"), ["中共", "重工"])
        // sys-only pinyin 仍可查到
        XCTAssertEqual(store.pinnedWords(for: "zhongguo"), ["中国"])
    }

    func testDualLayerSysOnlyWhenUserNil() throws {
        let sysPath = try writeTOML(
            """
            [pinned]
            zhongguo = ["中国"]
            """, name: "sys.toml")
        let store = PinnedWordStore(sysPath: sysPath, userPath: nil)
        XCTAssertEqual(store.pinnedWords(for: "zhongguo"), ["中国"])
    }

    func testDualLayerUserOnlyWhenSysNil() throws {
        let userPath = try writeTOML(
            """
            [pinned]
            woshi = ["我是"]
            """, name: "user.toml")
        let store = PinnedWordStore(sysPath: nil, userPath: userPath)
        XCTAssertEqual(store.pinnedWords(for: "woshi"), ["我是"])
    }

    func testUserOverridesSysSameWord() throws {
        // 同词同拼音在两层各出现一次 —— 合并后只出现一次（用户层位置）。
        let sysPath = try writeTOML(
            """
            [pinned]
            zhongguo = ["中国"]
            """, name: "sys.toml")
        let userPath = try writeTOML(
            """
            [pinned]
            zhongguo = ["中国"]
            """, name: "user.toml")
        let store = PinnedWordStore(sysPath: sysPath, userPath: userPath)
        XCTAssertEqual(store.pinnedWords(for: "zhongguo"), ["中国"])
    }

    // MARK: - 写操作

    func testPinInsertsAtUserHead() throws {
        let userPath = scratchDir.appendingPathComponent("user.toml").path
        let store = PinnedWordStore(sysPath: nil, userPath: userPath)
        store.pin("中国", forPinyin: "zhongguo")
        XCTAssertEqual(store.pinnedWords(for: "zhongguo"), ["中国"])
    }

    func testPinMovesExistingToHead() throws {
        let userPath = try writeTOML(
            """
            [pinned]
            zhonggong = ["重工", "中共"]
            """, name: "user.toml")
        let store = PinnedWordStore(sysPath: nil, userPath: userPath)
        store.pin("中共", forPinyin: "zhonggong")
        XCTAssertEqual(store.pinnedWords(for: "zhonggong"), ["中共", "重工"])
    }

    func testPinCopiesSysOnlyWordIntoUser() throws {
        // sys 层有「重工」，user 层没有 —— pin 后应在 user 层队首出现。
        let sysPath = try writeTOML(
            """
            [pinned]
            zhonggong = ["中共", "重工"]
            """, name: "sys.toml")
        let userPath = scratchDir.appendingPathComponent("user.toml").path
        let store = PinnedWordStore(sysPath: sysPath, userPath: userPath)
        XCTAssertEqual(store.pinnedWords(for: "zhonggong"), ["中共", "重工"])

        store.pin("重工", forPinyin: "zhonggong")
        // user: ["重工"]，sys: ["中共", "重工"] → merge ["重工", "中共"]
        XCTAssertEqual(store.pinnedWords(for: "zhonggong"), ["重工", "中共"])
    }

    func testUnpinUserRemovesFromUserNotSys() throws {
        let sysPath = try writeTOML(
            """
            [pinned]
            zhonggong = ["重工"]
            """, name: "sys.toml")
        let userPath = try writeTOML(
            """
            [pinned]
            zhonggong = ["中共", "重工"]
            """, name: "user.toml")
        let store = PinnedWordStore(sysPath: sysPath, userPath: userPath)
        XCTAssertEqual(store.pinnedWords(for: "zhonggong"), ["中共", "重工"])

        store.unpinUser("中共", forPinyin: "zhonggong")
        // user: ["重工"]，sys: ["重工"] → ["重工"]
        XCTAssertEqual(store.pinnedWords(for: "zhonggong"), ["重工"])

        // 即使把 user 层「重工」也删除，sys 层「重工」仍然在
        store.unpinUser("重工", forPinyin: "zhonggong")
        XCTAssertEqual(store.pinnedWords(for: "zhonggong"), ["重工"])
    }

    // MARK: - 持久化

    func testPinPersistsAcrossReload() throws {
        let userPath = scratchDir.appendingPathComponent("user.toml").path
        let store = PinnedWordStore(sysPath: nil, userPath: userPath)
        store.pin("中国", forPinyin: "zhongguo")
        store.pin("中共", forPinyin: "zhonggong")
        store.pin("重工", forPinyin: "zhonggong")  // 现在 user["zhonggong"] = ["重工", "中共"]

        let reloaded = PinnedWordStore(sysPath: nil, userPath: userPath)
        XCTAssertEqual(reloaded.pinnedWords(for: "zhongguo"), ["中国"])
        XCTAssertEqual(reloaded.pinnedWords(for: "zhonggong"), ["重工", "中共"])
    }

    func testUnpinUserPersistsAcrossReload() throws {
        let userPath = try writeTOML(
            """
            [pinned]
            zhonggong = ["中共", "重工"]
            """, name: "user.toml")
        let store = PinnedWordStore(sysPath: nil, userPath: userPath)
        store.unpinUser("中共", forPinyin: "zhonggong")

        let reloaded = PinnedWordStore(sysPath: nil, userPath: userPath)
        XCTAssertEqual(reloaded.pinnedWords(for: "zhonggong"), ["重工"])
    }

    func testSerializationRoundTripStable() throws {
        // 写出 → 读回 → 再写出，文件内容应稳定。
        let userPath = scratchDir.appendingPathComponent("user.toml").path
        let store = PinnedWordStore(sysPath: nil, userPath: userPath)
        store.pin("中共", forPinyin: "zhonggong")
        store.pin("重工", forPinyin: "zhonggong")  // user: ["重工", "中共"]
        store.pin("中国", forPinyin: "zhongguo")

        let firstDump = try String(contentsOfFile: userPath, encoding: .utf8)

        // 重载并触发一次原子写回（pin 一个已在队首的项 —— 内容不变但会刷盘）
        let reloaded = PinnedWordStore(sysPath: nil, userPath: userPath)
        reloaded.pin("重工", forPinyin: "zhonggong")
        let secondDump = try String(contentsOfFile: userPath, encoding: .utf8)

        XCTAssertEqual(firstDump, secondDump)
    }

    func testSerializationUsesArrayFormEvenForSingletons() throws {
        // 单条目也应输出 `key = ["..."]`，保证读写对称。
        let userPath = scratchDir.appendingPathComponent("user.toml").path
        let store = PinnedWordStore(sysPath: nil, userPath: userPath)
        store.pin("中国", forPinyin: "zhongguo")

        let dump = try String(contentsOfFile: userPath, encoding: .utf8)
        XCTAssertTrue(
            dump.contains("zhongguo = [\"中国\"]"),
            "Expected array form, got: \(dump)")
    }
}
