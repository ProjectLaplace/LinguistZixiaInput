import XCTest

@testable import PinyinEngine

final class PinnedLookupTests: XCTestCase {

    func testAllEmpty() {
        XCTAssertEqual(
            PinnedLookupHelper.merge(user: [], sys: [], candidates: []),
            [])
    }

    func testUserOnly() {
        XCTAssertEqual(
            PinnedLookupHelper.merge(user: ["的", "地"], sys: [], candidates: []),
            ["的", "地"])
    }

    func testSysOnly() {
        XCTAssertEqual(
            PinnedLookupHelper.merge(user: [], sys: ["啊", "阿"], candidates: []),
            ["啊", "阿"])
    }

    func testCandidatesOnly() {
        XCTAssertEqual(
            PinnedLookupHelper.merge(user: [], sys: [], candidates: ["大", "打", "答"]),
            ["大", "打", "答"])
    }

    func testUserAndSysNoOverlap() {
        XCTAssertEqual(
            PinnedLookupHelper.merge(user: ["的"], sys: ["啊"], candidates: []),
            ["的", "啊"])
    }

    func testThreeWayConcatenation() {
        XCTAssertEqual(
            PinnedLookupHelper.merge(user: ["的"], sys: ["啊"], candidates: ["大", "打"]),
            ["的", "啊", "大", "打"])
    }

    func testUserOverridesSysSameItem() {
        // 同一项在 user 与 sys 都出现，仅在 user 位置保留一次。
        XCTAssertEqual(
            PinnedLookupHelper.merge(user: ["的"], sys: ["的", "地"], candidates: []),
            ["的", "地"])
    }

    func testSysOverridesCandidates() {
        XCTAssertEqual(
            PinnedLookupHelper.merge(user: [], sys: ["大"], candidates: ["打", "大", "答"]),
            ["大", "打", "答"])
    }

    func testUserOverridesCandidatesSkippingSys() {
        // user 与 candidates 重复但 sys 没该项 —— 仍然只保留在 user 位置。
        XCTAssertEqual(
            PinnedLookupHelper.merge(user: ["大"], sys: ["啊"], candidates: ["打", "大"]),
            ["大", "啊", "打"])
    }

    func testWithinSourceDuplicatesKeepFirst() {
        // 同一数组内有重复项 —— 保留首次出现的。
        XCTAssertEqual(
            PinnedLookupHelper.merge(
                user: ["的", "地", "的"],
                sys: ["啊", "啊"],
                candidates: ["大", "打", "大"]),
            ["的", "地", "啊", "大", "打"])
    }

    func testRelativeOrderPreserved() {
        // 三个数组各自的相对顺序都不应被打乱。
        XCTAssertEqual(
            PinnedLookupHelper.merge(
                user: ["a", "b", "c"],
                sys: ["d", "e"],
                candidates: ["f", "g", "h"]),
            ["a", "b", "c", "d", "e", "f", "g", "h"])
    }
}
