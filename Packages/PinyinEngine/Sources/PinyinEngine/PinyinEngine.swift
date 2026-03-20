import Foundation

/// 组合项：可以是确定的文本，也可以是待处理的拼音。
/// 复合缓冲区架构的核心，支持「以词定字」后的持续组词。
public enum ComposingItem: Equatable {
    case text(String)
    case pinyin(String)

    /// 是否为拼音项
    public var isPinyin: Bool {
        if case .pinyin = self { return true }
        return false
    }

    /// 获取该项的显示文本内容
    public var content: String {
        switch self {
        case .text(let s), .pinyin(let s): return s
        }
    }
}

/// 引擎输入事件：由 UI 层将物理按键映射后传入
public enum EngineEvent {
    case letter(Character)
    case number(Int)
    case space
    case enter
    case backspace
    case esc
    case bracket(pickLast: Bool)
}

/// 输入模式：中文为默认持久模式，临时模式在提交后自动回退
public enum InputMode: String {
    case pinyin = "中文"
    case transient = "日文"
}

/// 引擎当前状态：只读快照，供 UI 层订阅并渲染
public struct EngineState {
    /// 当前复合缓冲区中的所有项
    public let items: [ComposingItem]
    /// 针对最后一段拼音生成的候选词列表
    public let candidates: [String]
    /// 本轮交互产生的上屏文本（如有）
    public let committedText: String?
    /// 当前引擎所处的输入模式
    public let mode: InputMode

    /// 组合缓冲区的完整拼接字符串（用于 UI 调试）
    public var fullDisplayBuffer: String {
        items.map { $0.content }.joined()
    }

    /// 初始空闲状态
    public static let idle = EngineState(
        items: [], candidates: [], committedText: nil, mode: .pinyin)
}

/// PinyinEngine 核心逻辑
/// 采用复合缓冲区（Composite Buffer）设计，支持多阶段组词与临时模式扩展。
public class PinyinEngine {
    // 词库映射：物理分离
    private var zhDictionary: [String: [String]] = [:]
    private var jaDictionary: [String: [String]] = [:]

    // 内部状态管理
    private var composingItems: [ComposingItem] = []
    private var candidates: [String] = []
    private var currentMode: InputMode = .pinyin

    public init() {
        loadDictionaries()
    }

    // MARK: - 词库加载

    /// 从本地资源加载 JSON 词库
    private func loadDictionaries() {
        zhDictionary = loadJSON(named: "zh_dict")
        jaDictionary = loadJSON(named: "ja_dict")
    }

    private func loadJSON(named name: String) -> [String: [String]] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return dict
    }

    // MARK: - 核心处理入口

    /// 引擎逻辑主入口：处理输入事件并驱动状态转移
    /// - Parameter event: 外部按键事件
    /// - Returns: 处理后的引擎状态快照
    public func process(_ event: EngineEvent) -> EngineState {
        var committedText: String? = nil

        switch event {
        case .letter(let char):
            handleLetter(char)

        case .backspace:
            handleBackspace()

        case .esc:
            resetAll()

        case .enter:
            // Enter 键逻辑：上屏当前缓冲区内所有内容的原文
            if !composingItems.isEmpty {
                committedText = composingItems.map { $0.content }.joined()
                resetAll()
            }

        case .space:
            // Space 键逻辑：确认当前候选并尝试整体上屏
            if let first = candidates.first {
                finalizeLastPinyin(with: first)
                committedText = composingItems.map { $0.content }.joined()
                resetAll()
            } else if !composingItems.isEmpty {
                // 无候选时，空格行为等同于回车，上屏原文
                committedText = composingItems.map { $0.content }.joined()
                resetAll()
            }

        case .number(let index):
            // 数字选词逻辑：将当前拼音段坍缩为确定的文字，但不立即上屏，允许继续组词
            let actualIndex = index - 1
            if actualIndex >= 0 && actualIndex < candidates.count {
                finalizeLastPinyin(with: candidates[actualIndex])
            }

        case .bracket(let pickLast):
            // 以词定字逻辑：取首个候选词的指定字符，暂存在 Buffer 中
            if let first = candidates.first,
                let char = pickCharacter(from: first, pickLast: pickLast)
            {
                finalizeLastPinyin(with: char)
            }
        }

        return EngineState(
            items: composingItems,
            candidates: candidates,
            committedText: committedText,
            mode: currentMode
        )
    }

    // MARK: - 内部私有逻辑

    /// 处理字母按键：涉及模式切换与拼音段追加
    private func handleLetter(_ char: Character) {
        let lowerChar = char.lowercased()

        // 分段模式切换：在 Buffer 为空或处于段落边界（刚定完字）时，'i' 作为开关
        let isAtSegmentBoundary = composingItems.isEmpty || !composingItems.last!.isPinyin
        if isAtSegmentBoundary && lowerChar == "i" {
            currentMode = (currentMode == .pinyin) ? .transient : .pinyin
            return
        }

        // 如果最后一段不是拼音（或者是空的），则开辟新的拼音段
        if composingItems.isEmpty || !composingItems.last!.isPinyin {
            composingItems.append(.pinyin(lowerChar))
        } else {
            // 否则在当前拼音段末尾追加
            if case .pinyin(let existing) = composingItems.removeLast() {
                composingItems.append(.pinyin(existing + lowerChar))
            }
        }
        updateCandidates()
    }

    /// 处理退格逻辑：支持按字符逐位删除已确定的文字或拼音
    private func handleBackspace() {
        guard !composingItems.isEmpty else { return }

        var last = composingItems.removeLast()
        switch last {
        case .pinyin(let s):
            if s.count > 1 {
                composingItems.append(.pinyin(String(s.dropLast())))
            }
        case .text(let s):
            if s.count > 1 {
                composingItems.append(.text(String(s.dropLast())))
            }
        }
        updateCandidates()
    }

    /// 将当前缓冲区末尾的拼音段「坍缩」为确定的文本
    private func finalizeLastPinyin(with text: String) {
        guard let last = composingItems.last, case .pinyin = last else { return }
        composingItems.removeLast()
        composingItems.append(.text(text))
        candidates = []  // 定字后清空当前段落的候选列表
    }

    /// 更新候选词列表：根据当前模式从对应词库检索
    private func updateCandidates() {
        guard let last = composingItems.last else {
            candidates = []
            return
        }

        switch last {
        case .pinyin(let s):
            let dict = (currentMode == .pinyin) ? zhDictionary : jaDictionary
            candidates = dict[s] ?? []
        case .text:
            candidates = []
        }
    }

    /// 重置所有状态：包括清空缓冲区和自动回退临时模式
    private func resetAll() {
        composingItems = []
        candidates = []
        if currentMode == .transient { currentMode = .pinyin }
    }

    /// 以词定字辅助：截取首尾字符
    private func pickCharacter(from candidate: String, pickLast: Bool) -> String? {
        guard !candidate.isEmpty else { return nil }
        return pickLast ? String(candidate.last!) : String(candidate.first!)
    }

    // MARK: - 兼容性接口

    /// 兼容旧版调用接口
    public func getCandidates(for pinyin: String) -> [String] {
        let dict = (currentMode == .pinyin) ? zhDictionary : jaDictionary
        return dict[pinyin.lowercased()] ?? []
    }
}
