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

/// 输入模式：中文为默认持久模式，临时模式在提交后自动回退
public enum InputMode: String {
    case pinyin = "中文"
    case transient = "日文"  // 当前扩展仅支持日文，未来可改为「扩展」
}

/// 引擎当前状态
public struct EngineState {
    public let buffer: String
    public let candidates: [String]
    public let committedText: String?
    public let mode: InputMode

    public static let idle = EngineState(
        buffer: "", candidates: [], committedText: nil, mode: .pinyin)
}

/// PinyinEngine 核心逻辑
public class PinyinEngine {
    private var zhDictionary: [String: [String]] = [:]
    private var jaDictionary: [String: [String]] = [:]

    // 内部状态
    private var buffer: String = ""
    private var candidates: [String] = []
    private var currentMode: InputMode = .pinyin

    public init() {
        loadDictionaries()
    }

    private func loadDictionaries() {
        zhDictionary = loadJSON(named: "zh_dict")
        jaDictionary = loadJSON(named: "ja_dict")
    }

    private func loadJSON(named name: String) -> [String: [String]] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else {
            return [:]
        }
        return dict
    }

    /// 处理输入事件并返回新的状态快照
    public func process(_ event: EngineEvent) -> EngineState {
        var committedText: String? = nil

        switch event {
        case .letter(let char):
            let lowerChar = char.lowercased()
            // 模式切换：仅在 Buffer 为空时，按下 'i' 切换
            if buffer.isEmpty && lowerChar == "i" {
                currentMode = (currentMode == .pinyin) ? .transient : .pinyin
            } else {
                buffer.append(lowerChar)
                updateCandidates()
            }

        case .backspace:
            if !buffer.isEmpty {
                buffer.removeLast()
                updateCandidates()
            }

        case .esc:
            resetBuffer()

        case .enter:
            if !buffer.isEmpty {
                committedText = buffer
                finalizeCommit()
            }

        case .space:
            if let first = candidates.first {
                committedText = first
                finalizeCommit()
            } else if !buffer.isEmpty {
                committedText = buffer
                finalizeCommit()
            }

        case .number(let index):
            let actualIndex = index - 1
            if actualIndex >= 0 && actualIndex < candidates.count {
                committedText = candidates[actualIndex]
                finalizeCommit()
            }

        case .bracket(let pickLast):
            if let first = candidates.first {
                committedText = pickCharacter(from: first, pickLast: pickLast)
                finalizeCommit()
            }
        }

        return EngineState(
            buffer: buffer,
            candidates: candidates,
            committedText: committedText,
            mode: currentMode
        )
    }

    private func updateCandidates() {
        if buffer.isEmpty {
            candidates = []
            return
        }
        let dict = (currentMode == .pinyin) ? zhDictionary : jaDictionary
        candidates = dict[buffer] ?? []
    }

    /// 核心逻辑：提交上屏后，若是临时模式则自动回退
    private func finalizeCommit() {
        buffer = ""
        candidates = []
        if currentMode == .transient {
            currentMode = .pinyin
        }
    }

    private func resetBuffer() {
        buffer = ""
        candidates = []
    }

    private func pickCharacter(from candidate: String, pickLast: Bool) -> String? {
        guard !candidate.isEmpty else { return nil }
        return pickLast ? String(candidate.last!) : String(candidate.first!)
    }

    // 兼容旧接口
    public func getCandidates(for pinyin: String) -> [String] {
        let dict = (currentMode == .pinyin) ? zhDictionary : jaDictionary
        return dict[pinyin.lowercased()] ?? []
    }
}
