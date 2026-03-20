import Foundation

/// 引擎输入事件
public enum EngineEvent {
    case letter(Character)
    case number(Int)
    case space
    case enter
    case backspace
    case esc
    case bracket(pickLast: Bool)
}

/// 引擎当前状态
public struct EngineState {
    public let buffer: String
    public let candidates: [String]
    public let committedText: String?

    public static let idle = EngineState(buffer: "", candidates: [], committedText: nil)
}

/// PinyinEngine 核心逻辑
/// 严格遵循「DESIGN.md」中的状态机蓝图实现。
public class PinyinEngine {
    // 模拟词库（增加日文支持）
    private let baseDictionary: [String: [String]] = [
        "a": ["啊", "阿", "呵"],
        "paixu": ["排序"],
        "wode": ["我的"],
        "xiangfa": ["想法"],
        "pinyin": ["拼音"],
        "cihui": ["词汇"],
        "zixia": ["紫霞", "子夏", "自下"],
        "jiaohu": ["交互"],
        "jisuan": ["计算"],
        "shi": [
            "是", "时", "事", "十", "使", "实", "市", "世", "式", "师", "试", "视", "史", "石", "食", "室", "始",
            "示", "士", "适",
        ],
        // 日文测试数据 (前缀 j)
        "jsaki": ["咲"],
        "jshia": ["幸せ"],
        "jtabe": ["食べる"],
    ]

    // 内部状态
    private var buffer: String = ""
    private var candidates: [String] = []

    public init() {}

    /// 处理输入事件并返回新的状态快照
    public func process(_ event: EngineEvent) -> EngineState {
        var committedText: String? = nil

        switch event {
        case .letter(let char):
            buffer.append(char.lowercased())
            updateCandidates()

        case .backspace:
            if !buffer.isEmpty {
                buffer.removeLast()
                updateCandidates()
            }

        case .esc:
            reset()

        case .enter:
            if !buffer.isEmpty {
                committedText = buffer
                reset()
            }

        case .space:
            if let first = candidates.first {
                committedText = first
                reset()
            } else if !buffer.isEmpty {
                // 如果没有候选词，空格上屏原始 Buffer
                committedText = buffer
                reset()
            }

        case .number(let index):
            let actualIndex = index - 1
            if actualIndex >= 0 && actualIndex < candidates.count {
                committedText = candidates[actualIndex]
                reset()
            }

        case .bracket(let pickLast):
            if let first = candidates.first {
                committedText = pickCharacter(from: first, pickLast: pickLast)
                reset()
            }
        }

        return EngineState(
            buffer: buffer,
            candidates: candidates,
            committedText: committedText
        )
    }

    // MARK: - 内部辅助

    private func updateCandidates() {
        if buffer.isEmpty {
            candidates = []
            return
        }

        // 逻辑：直接从词库查询
        // 未来这里会处理：j/vj 前缀的特殊分发，以及拼音切分
        candidates = baseDictionary[buffer] ?? []
    }

    private func reset() {
        buffer = ""
        candidates = []
    }

    private func pickCharacter(from candidate: String, pickLast: Bool) -> String? {
        guard !candidate.isEmpty else { return nil }
        return pickLast ? String(candidate.last!) : String(candidate.first!)
    }

    // 兼容旧接口
    public func getCandidates(for pinyin: String) -> [String] {
        return baseDictionary[pinyin.lowercased()] ?? []
    }

    public func pickCharacter(from candidate: String, pickLast: Bool) -> String {
        return pickLast ? String(candidate.last!) : String(candidate.first!)
    }
}
