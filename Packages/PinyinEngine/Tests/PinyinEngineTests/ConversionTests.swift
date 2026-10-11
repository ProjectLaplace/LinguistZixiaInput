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
}
