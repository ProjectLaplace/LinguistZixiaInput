import XCTest

@testable import PinyinEngine

final class ConversionTests: XCTestCase {

    private var store: DictionaryStore!

    override func setUp() {
        super.setUp()
        let zhPath = Bundle.module.url(forResource: "zh_dict", withExtension: "db")!.path
        store = DictionaryStore(path: zhPath)
    }

    // MARK: - DFS 前缀剪枝

    /// 没有任何词条以累积拼音开头时，DFS 不再延伸，也不对其后的裸声母做展开查询。
    /// 测试词库中 `shijian` 之后不存在更长的词条，`guanl` 部分只应从各自的起点重新查询。
    /// 不剪枝时此输入执行 2538 次查询，剪枝后为 142 次；上限留出余量，只防止退回逐层穷举。
    func testComposeStopsExtendingPathsNoEntryCanContinue() {
        _ = Conversion.compose("shijianguanl", store: store)

        XCTAssertLessThanOrEqual(store.stats.statements, 300)
    }

    /// 剪枝只省去不可能命中的查询，组词结果不变。期望值取自剪枝前的实现（eb008b3 之前）
    /// 在同一测试词库上的输出，覆盖多音节路径、裸声母展开（gangcd、xiangf）与歧义切分
    /// （jianchayixiane 中 xia+ne 与 xian+e、xian 的单音节与 xi+an）。
    func testPruningLeavesComposedResultsUnchanged() {
        let expected: [(input: String, text: String, chunks: [String])] = [
            ("gangcd", "刚才的", ["gang", "c", "d"]),
            ("gangcaide", "刚才的", ["gang", "cai", "de"]),
            ("xiangf", "想法", ["xiang", "f"]),
            ("jianchayixiane", "检查一下呢", ["jian", "cha", "yi", "xia", "ne"]),
            ("jianchayixia", "检查一下", ["jian", "cha", "yi", "xia"]),
            ("xianzai", "现在", ["xian", "zai"]),
            ("xian", "西安", ["xian"]),
            ("kaifajishu", "开发技术", ["kai", "fa", "ji", "shu"]),
            ("rengongzhineng", "人工智能", ["ren", "gong", "zhi", "neng"]),
            ("ziranyuyan", "自然语言", ["zi", "ran", "yu", "yan"]),
            ("shishenme", "是什么", ["shi", "shen", "me"]),
            ("qianpianyilv", "千篇一律", ["qian", "pian", "yi", "lv"]),
            ("yixingyiyi", "一心一意", ["yi", "xing", "yi", "yi"]),
            ("hulve", "忽略", ["hu", "lve"]),
            ("wodexiangfa", "我的想法", ["wo", "de", "xiang", "fa"]),
            ("tamashuo", "他妈说", ["ta", "ma", "shuo"]),
            ("jingquepipei", "精确匹配", ["jing", "que", "pi", "pei"]),
        ]

        for (input, text, chunks) in expected {
            let result = Conversion.compose(input, store: store)
            XCTAssertEqual(result?.text, text, input)
            XCTAssertEqual(result?.chunks, chunks, input)
        }
    }
}
