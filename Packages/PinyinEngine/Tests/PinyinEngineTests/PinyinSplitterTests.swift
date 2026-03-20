import XCTest

@testable import PinyinEngine

final class PinyinSplitterTests: XCTestCase {

    // MARK: - Basic Syllables

    func testSingleSyllable() {
        XCTAssertEqual(PinyinSplitter.split("wo"), ["wo"])
        XCTAssertEqual(PinyinSplitter.split("ni"), ["ni"])
        XCTAssertEqual(PinyinSplitter.split("shi"), ["shi"])
        XCTAssertEqual(PinyinSplitter.split("zhi"), ["zhi"])
    }

    func testTwoSyllableWord() {
        XCTAssertEqual(PinyinSplitter.split("women"), ["wo", "men"])
        XCTAssertEqual(PinyinSplitter.split("pinyin"), ["pin", "yin"])
        XCTAssertEqual(PinyinSplitter.split("beijing"), ["bei", "jing"])
    }

    func testMultiSyllable() {
        XCTAssertEqual(PinyinSplitter.split("shijian"), ["shi", "jian"])
        XCTAssertEqual(PinyinSplitter.split("ziguang"), ["zi", "guang"])
        XCTAssertEqual(PinyinSplitter.split("pengyou"), ["peng", "you"])
        XCTAssertEqual(PinyinSplitter.split("lvxing"), ["lv", "xing"])
    }

    func testLongPhrase() {
        XCTAssertEqual(
            PinyinSplitter.split("womenshishui"),
            ["wo", "men", "shi", "shui"]
        )
        XCTAssertEqual(
            PinyinSplitter.split("rengongzhineng"),
            ["ren", "gong", "zhi", "neng"]
        )
    }

    // MARK: - Apostrophe Hard Split

    func testApostropheSplit() {
        // xi'an should split as xi + an, not xian
        XCTAssertEqual(PinyinSplitter.split("xi'an"), ["xi", "an"])
    }

    func testWithoutApostropheGreedyMatch() {
        // Without apostrophe, xian matches as one syllable
        XCTAssertEqual(PinyinSplitter.split("xian"), ["xian"])
    }

    func testMultipleApostrophes() {
        XCTAssertEqual(PinyinSplitter.split("pi'ao"), ["pi", "ao"])
    }

    // MARK: - Edge Cases

    func testEmptyString() {
        XCTAssertEqual(PinyinSplitter.split(""), [])
    }

    func testNonPinyinReturnsNil() {
        XCTAssertNil(PinyinSplitter.split("xyz"))
        XCTAssertNil(PinyinSplitter.split("vvv"))
    }

    func testSingleValidSyllable() {
        XCTAssertEqual(PinyinSplitter.split("a"), ["a"])
        XCTAssertEqual(PinyinSplitter.split("e"), ["e"])
        XCTAssertEqual(PinyinSplitter.split("er"), ["er"])
    }

    func testCaseInsensitive() {
        XCTAssertEqual(PinyinSplitter.split("BeiJing"), ["bei", "jing"])
        XCTAssertEqual(PinyinSplitter.split("WOMEN"), ["wo", "men"])
    }

    // MARK: - Greedy Longest Match Behavior

    func testGreedyPrefersLonger() {
        // "chang" should match as one syllable, not "ch" + "ang"
        XCTAssertEqual(PinyinSplitter.split("chang"), ["chang"])
        // "zhuang" should match as one syllable
        XCTAssertEqual(PinyinSplitter.split("zhuang"), ["zhuang"])
        // "shuang" should match as one syllable
        XCTAssertEqual(PinyinSplitter.split("shuang"), ["shuang"])
    }

    func testGreedyWithFollowingSyllable() {
        // "shangdian" = shang + dian, not sha + ng + dian
        XCTAssertEqual(PinyinSplitter.split("shangdian"), ["shang", "dian"])
        // "zhuangshi" = zhuang + shi
        XCTAssertEqual(PinyinSplitter.split("zhuangshi"), ["zhuang", "shi"])
    }

    // MARK: - Syllable Table Coverage

    func testZhChShInitials() {
        XCTAssertEqual(PinyinSplitter.split("zhongguo"), ["zhong", "guo"])
        XCTAssertEqual(PinyinSplitter.split("chuang"), ["chuang"])
        XCTAssertEqual(PinyinSplitter.split("shuijiao"), ["shui", "jiao"])
    }

    func testYWInitials() {
        XCTAssertEqual(PinyinSplitter.split("yuyan"), ["yu", "yan"])
        XCTAssertEqual(PinyinSplitter.split("wangluo"), ["wang", "luo"])
    }

    func testSpecialSyllables() {
        XCTAssertEqual(PinyinSplitter.split("nver"), ["nv", "er"])
        XCTAssertEqual(PinyinSplitter.split("lve"), ["lve"])
    }
}
