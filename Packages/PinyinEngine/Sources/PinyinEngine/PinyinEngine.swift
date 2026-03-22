import Foundation

/// 组合项：可以是确定的文本、待处理的拼音、或自动匹配的预览。
/// 复合缓冲区架构的核心，支持「以词定字」后的持续组词。
public enum ComposingItem: Equatable {
    case text(String)
    case pinyin(String)
    /// 自动匹配的预览项：显示候选汉字，但仍可通过 Tab 聚焦后替换
    case provisional(pinyin: String, candidate: String)

    /// 是否为活跃的拼音输入项
    public var isPinyin: Bool {
        if case .pinyin = self { return true }
        return false
    }

    /// 是否为可编辑项（拼音或预览）
    public var isEditable: Bool {
        switch self {
        case .pinyin, .provisional: return true
        case .text: return false
        }
    }

    /// 获取该项的原始拼音（仅对拼音和预览项有效）
    public var sourcePinyin: String? {
        switch self {
        case .pinyin(let s): return s
        case .provisional(let pinyin, _): return pinyin
        case .text: return nil
        }
    }

    /// 获取该项的显示文本内容
    public var content: String {
        switch self {
        case .text(let s), .pinyin(let s): return s
        case .provisional(_, let candidate): return candidate
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
    case tab(backward: Bool)
    case punctuation(Character)
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
    /// 针对当前聚焦段生成的候选词列表
    public let candidates: [String]
    /// 本轮交互产生的上屏文本（如有）
    public let committedText: String?
    /// 当前引擎所处的输入模式
    public let mode: InputMode
    /// 当前聚焦的可编辑段索引（在可编辑段中的序号，nil 表示末尾）
    public let focusedSegmentIndex: Int?

    /// 组合缓冲区的完整拼接字符串（用于 UI 调试）
    public var fullDisplayBuffer: String {
        items.map { $0.content }.joined()
    }

    /// 初始空闲状态
    public static let idle = EngineState(
        items: [], candidates: [], committedText: nil, mode: .pinyin,
        focusedSegmentIndex: nil)
}

/// PinyinEngine 核心逻辑
/// 采用复合缓冲区（Composite Buffer）设计，支持多阶段组词与临时模式扩展。
public class PinyinEngine {
    // 词库：物理分离，SQLite 支持
    private var zhStore: DictionaryStore?
    private var jaStore: DictionaryStore?
    private var userDict: UserDictionary?

    // 内部状态管理
    private var composingItems: [ComposingItem] = []
    private var candidates: [String] = []
    private var currentMode: InputMode = .pinyin

    // 自动切分状态
    private var rawPinyin: String = ""  // 当前正在输入的完整拼音串
    private var originalPinyin: String = ""  // 用于学习的完整拼音（Tab 模式下 rawPinyin 会被修改）
    private var focusIndex: Int? = nil  // 聚焦的可编辑段索引，nil = 末尾

    // 全角标点状态
    private var doubleQuoteOpen = false  // " 的开闭状态
    private var singleQuoteOpen = false  // ' 的开闭状态

    /// 半角→全角标点映射表
    private static let punctuationMap: [Character: String] = [
        ",": "，", ".": "。", ";": "；", ":": "：",
        "?": "？", "!": "！", "\\": "、",
        "(": "（", ")": "）", "{": "「", "}": "」",
        "<": "《", ">": "》",
        "~": "～", "$": "￥",
        "^": "……", "_": "——",
        "`": "·",
    ]

    /// 使用 Bundle 内置词库初始化
    public init() {
        loadDictionaries()
        userDict = UserDictionary()
    }

    /// 使用指定的词库文件路径初始化
    public init(zhDictPath: String, jaDictPath: String) {
        zhStore = DictionaryStore(path: zhDictPath)
        jaStore = DictionaryStore(path: jaDictPath)
    }

    /// 使用指定的词库文件路径和用户词典路径初始化（用于测试）
    public init(zhDictPath: String, jaDictPath: String, userDictPath: String) {
        zhStore = DictionaryStore(path: zhDictPath)
        jaStore = DictionaryStore(path: jaDictPath)
        userDict = UserDictionary(path: userDictPath)
    }

    // MARK: - 词库加载

    /// 从 Bundle 资源加载 SQLite 词库
    private func loadDictionaries() {
        if let url = Bundle.module.url(forResource: "zh_dict", withExtension: "db") {
            zhStore = DictionaryStore(path: url.path)
        }
        if let url = Bundle.module.url(forResource: "ja_dict", withExtension: "db") {
            jaStore = DictionaryStore(path: url.path)
        }
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
            if !composingItems.isEmpty {
                committedText = rawContentForCommit()
                resetAll()
            }

        case .space:
            committedText = handleSpace()

        case .number(let index):
            handleNumber(index)

        case .bracket(let pickLast):
            handleBracket(pickLast: pickLast)

        case .tab(let backward):
            handleTab(backward: backward)

        case .punctuation(let char):
            committedText = handlePunctuation(char)
        }

        return EngineState(
            items: composingItems,
            candidates: candidates,
            committedText: committedText,
            mode: currentMode,
            focusedSegmentIndex: focusIndex
        )
    }

    // MARK: - 字母输入

    /// 处理字母按键：涉及模式切换、拼音追加与自动切分
    private func handleLetter(_ char: Character) {
        let lowerChar = char.lowercased()

        // 分段模式切换：在 Buffer 为空或处于段落边界（刚定完字）时，'i' 作为开关
        let isAtSegmentBoundary = composingItems.isEmpty
            || (!composingItems.last!.isEditable)
        if isAtSegmentBoundary && lowerChar == "i" {
            currentMode = (currentMode == .pinyin) ? .transient : .pinyin
            return
        }

        // 如果当前没有活跃的拼音输入（上次是 .text），开始新的拼音串
        if rawPinyin.isEmpty && !composingItems.isEmpty && !composingItems.last!.isEditable {
            // Starting a new pinyin segment after confirmed text
        }

        // Tab 聚焦模式下不追加字母，退出聚焦回到末尾
        focusIndex = nil

        rawPinyin += lowerChar
        originalPinyin = rawPinyin
        rebuildFromRawPinyin()
    }

    // MARK: - 退格

    /// 处理退格逻辑
    private func handleBackspace() {
        // 如果在 Tab 聚焦模式，退格退出聚焦
        if focusIndex != nil {
            focusIndex = nil
            rebuildFromRawPinyin()
            return
        }

        if !rawPinyin.isEmpty {
            // 删除拼音串末尾字符
            rawPinyin = String(rawPinyin.dropLast())
            if rawPinyin.isEmpty {
                // 拼音全部删完，移除所有可编辑项
                composingItems.removeAll { $0.isEditable }
                candidates = []
            } else {
                rebuildFromRawPinyin()
            }
        } else if !composingItems.isEmpty {
            // 没有活跃拼音，删除最后一个已确定的文字
            let last = composingItems.removeLast()
            if case .text(let s) = last, s.count > 1 {
                composingItems.append(.text(String(s.dropLast())))
            }
            candidates = []
        }
    }

    // MARK: - 空格提交

    /// 处理空格键：确认候选并上屏
    private func handleSpace() -> String? {
        guard !composingItems.isEmpty else { return nil }

        if let first = candidates.first {
            if focusIndex != nil {
                // Tab 聚焦模式：只确认聚焦段，不上屏
                confirmFocusedSegment(with: first)
                return nil
            } else {
                // 正常模式：用候选替换整个拼音串，然后上屏全部
                let pinyinForLearn = originalPinyin.replacingOccurrences(of: "'", with: "")
                finalizeAllPinyin(with: first)
                let result = composingItems.map { $0.content }.joined()
                learnPhrase(pinyin: pinyinForLearn, word: result)
                resetAll()
                return result
            }
        } else if !composingItems.isEmpty {
            // 无候选时（包括 Tab 模式全部确认后），上屏已组合的内容
            let pinyinForLearn = originalPinyin.replacingOccurrences(of: "'", with: "")
            let result = composingItems.map { $0.content }.joined()
            learnPhrase(pinyin: pinyinForLearn, word: result)
            resetAll()
            return result
        }
        return nil
    }

    // MARK: - 数字选词

    /// 处理数字选词
    private func handleNumber(_ index: Int) {
        let actualIndex = index - 1
        guard actualIndex >= 0 && actualIndex < candidates.count else { return }

        if focusIndex != nil {
            // Tab 聚焦模式：确认聚焦段
            confirmFocusedSegment(with: candidates[actualIndex])
        } else {
            // 正常模式：用候选替换整个拼音串，不上屏
            finalizeAllPinyin(with: candidates[actualIndex])
        }
    }

    // MARK: - 以词定字

    /// 处理以词定字
    private func handleBracket(pickLast: Bool) {
        guard let first = candidates.first,
            let char = pickCharacter(from: first, pickLast: pickLast)
        else { return }

        if focusIndex != nil {
            confirmFocusedSegment(with: char)
        } else {
            finalizeAllPinyin(with: char)
        }
    }

    // MARK: - Tab 导航

    /// 处理 Tab 键：在可编辑段之间移动焦点
    private func handleTab(backward: Bool) {
        let editableIndices = composingItems.indices.filter { composingItems[$0].isEditable }
        guard !editableIndices.isEmpty else { return }

        if let current = focusIndex {
            // 已在聚焦模式，移动焦点
            if let pos = editableIndices.firstIndex(of: current) {
                let next =
                    backward
                    ? (pos - 1 + editableIndices.count) % editableIndices.count
                    : (pos + 1) % editableIndices.count
                focusIndex = editableIndices[next]
            }
        } else {
            // 进入聚焦模式：聚焦目标段，不修改其他段
            focusIndex = backward ? editableIndices.last! : editableIndices.first!
        }

        updateCandidatesForFocus()
    }

    // MARK: - 全角标点

    /// 处理标点输入：缓冲区非空时先提交，再输出全角标点
    private func handlePunctuation(_ char: Character) -> String? {
        let fullWidth = mapToFullWidth(char)

        if composingItems.isEmpty {
            // 缓冲区为空，直接输出全角标点
            return fullWidth
        } else {
            // 缓冲区非空：先用首选候选提交缓冲区，再追加标点
            let pinyinForLearn = originalPinyin.replacingOccurrences(of: "'", with: "")
            var result = ""
            if let first = candidates.first {
                finalizeAllPinyin(with: first)
                result = composingItems.map { $0.content }.joined()
                learnPhrase(pinyin: pinyinForLearn, word: result)
            } else {
                result = composingItems.map { $0.content }.joined()
                learnPhrase(pinyin: pinyinForLearn, word: result)
            }
            resetAll()
            return result + fullWidth
        }
    }

    /// 将半角字符映射为全角，处理引号开闭状态
    private func mapToFullWidth(_ char: Character) -> String {
        if char == "\"" {
            doubleQuoteOpen.toggle()
            return doubleQuoteOpen ? "\u{201C}" : "\u{201D}"  // " "
        }
        if char == "'" {
            singleQuoteOpen.toggle()
            return singleQuoteOpen ? "\u{2018}" : "\u{2019}"  // ' '
        }
        return Self.punctuationMap[char] ?? String(char)
    }

    // MARK: - 自动切分与重建

    /// 根据 rawPinyin 重建可编辑的 composingItems
    private func rebuildFromRawPinyin() {
        // 保留前面已确定的 .text 项
        let confirmedPrefix = composingItems.filter { !$0.isEditable }
        composingItems = confirmedPrefix

        guard !rawPinyin.isEmpty else {
            candidates = []
            return
        }

        // 先用 PinyinSplitter 做默认切分（用于显示）
        let (defaultSyllables, remainder) = PinyinSplitter.splitPartial(rawPinyin)

        if defaultSyllables.count > 1 || (defaultSyllables.count == 1 && !remainder.isEmpty) {
            for syllable in defaultSyllables {
                composingItems.append(.pinyin(syllable))
            }
            if !remainder.isEmpty {
                composingItems.append(.pinyin(remainder))
            }
        } else {
            composingItems.append(.pinyin(rawPinyin))
        }

        // 候选词：优先整串匹配
        updateCandidatesWholeString(defaultSyllables: defaultSyllables, remainder: remainder)
    }

    /// 更新候选词：系统整串 → 用户词典 → 统一 DP 组词 → 前缀 → 末段兜底
    private func updateCandidatesWholeString(defaultSyllables: [String], remainder: String) {
        let store = (currentMode == .pinyin) ? zhStore : jaStore

        // 1. 整串精确匹配（去掉 apostrophe，规范化 ü）
        let cleanPinyin = Self.normalizePinyin(rawPinyin.replacingOccurrences(of: "'", with: ""))
        var wholeMatches = store?.candidates(for: cleanPinyin) ?? []

        let hasApostrophe = rawPinyin.contains("'")

        // 用户用撇号显式分隔时，按音节数过滤整串匹配结果
        if hasApostrophe && defaultSyllables.count > 1 {
            wholeMatches = wholeMatches.filter { $0.count == defaultSyllables.count }
        }

        // 2. 用户词典匹配（精确 + 前缀），紧随系统整串之后
        var userResults: [String] = []
        if let userDict = userDict {
            userResults = userDict.candidates(for: cleanPinyin)
            if userResults.isEmpty && !remainder.isEmpty {
                userResults = userDict.candidatesWithPrefix(cleanPinyin)
            }
        }

        // 3. 统一 DP 组词（同时优化音节切分和词库匹配）
        // 仅影响候选词，不改变 composingItems 的显示切分
        var composed: String? = nil
        if remainder.isEmpty && defaultSyllables.count > 1 {
            if let result = unifiedCompose(cleanPinyin, store: store) {
                composed = result.text
            }
        }

        // 4. 合并：系统整串 → 用户词典（去重）
        var result = wholeMatches
        let wholeSet = Set(wholeMatches)
        for word in userResults where !wholeSet.contains(word) {
            result.append(word)
        }

        // 5. 自动组合候选仅在没有任何真实匹配时作为兜底
        if result.isEmpty {
            if let composed = composed {
                result.append(composed)
            }
        }

        // 6. 如果都没有，尝试前缀匹配（末尾音节不完整时）
        if result.isEmpty && !remainder.isEmpty {
            result = store?.candidatesWithPrefix(cleanPinyin) ?? []
        }

        // 7. 如果仍然没有，尝试最后一个活跃段的候选
        if result.isEmpty {
            if let lastPinyin = composingItems.last?.sourcePinyin {
                result = store?.candidates(for: Self.normalizePinyin(lastPinyin)) ?? []
            }
        }

        candidates = result
    }

    /// 为 Tab 聚焦段更新候选词
    private func updateCandidatesForFocus() {
        guard let idx = focusIndex, idx < composingItems.count else {
            let (syllables, remainder) = PinyinSplitter.splitPartial(rawPinyin)
            updateCandidatesWholeString(defaultSyllables: syllables, remainder: remainder)
            return
        }

        let item = composingItems[idx]
        guard let pinyin = item.sourcePinyin else {
            candidates = []
            return
        }

        let store = (currentMode == .pinyin) ? zhStore : jaStore
        candidates = store?.candidates(for: Self.normalizePinyin(pinyin)) ?? []
    }

    // MARK: - 确认与提交辅助

    /// 将整个拼音串替换为一个确定的文本（正常模式下选词/以词定字）
    private func finalizeAllPinyin(with text: String) {
        // 移除所有可编辑项
        composingItems.removeAll { $0.isEditable }
        composingItems.append(.text(text))
        rawPinyin = ""
        focusIndex = nil
        candidates = []
    }

    /// 确认 Tab 聚焦段的候选，然后移动焦点或退出聚焦
    private func confirmFocusedSegment(with text: String) {
        guard let idx = focusIndex, idx < composingItems.count else { return }

        composingItems[idx] = .text(text)

        // 从 rawPinyin 中移除已确认段的拼音
        rebuildRawPinyinFromItems()

        // 如果没有更多可编辑段，退出聚焦模式
        let editableIndices = composingItems.indices.filter { composingItems[$0].isEditable }
        if editableIndices.isEmpty {
            focusIndex = nil
            candidates = []
        } else {
            // 移动到下一个可编辑段
            focusIndex = editableIndices.first { $0 > idx } ?? editableIndices.first
            updateCandidatesForFocus()
        }
    }

    /// 从 composingItems 中残存的可编辑项重建 rawPinyin
    private func rebuildRawPinyinFromItems() {
        rawPinyin = composingItems.compactMap { $0.sourcePinyin }.joined()
    }

    /// 获取用于 Enter 上屏的原文（拼音原文 + 已确定文本）
    private func rawContentForCommit() -> String {
        composingItems.map {
            switch $0 {
            case .text(let s): return s
            case .pinyin(let s): return s
            case .provisional(let pinyin, _): return pinyin
            }
        }.joined()
    }

    /// 重置所有状态：包括清空缓冲区和自动回退临时模式
    private func resetAll() {
        composingItems = []
        candidates = []
        rawPinyin = ""
        originalPinyin = ""
        focusIndex = nil
        if currentMode == .transient { currentMode = .pinyin }
    }

    /// 以词定字辅助：截取首尾字符
    private func pickCharacter(from candidate: String, pickLast: Bool) -> String? {
        guard !candidate.isEmpty else { return nil }
        return pickLast ? String(candidate.last!) : String(candidate.first!)
    }

    /// 将拼音中 u 作为 ü 的替代写法规范化为 v（仅限 l/n 声母后的 ue→ve）
    private static func normalizePinyin(_ pinyin: String) -> String {
        var result = pinyin
        result = result.replacingOccurrences(of: "lue", with: "lve")
        result = result.replacingOccurrences(of: "nue", with: "nve")
        return result
    }

    // MARK: - 用户词典学习

    /// 将多字词保存到用户词典（仅当内容全为汉字且系统词库中不存在时才学习）
    private func learnPhrase(pinyin: String, word: String) {
        guard word.count > 1,
              word.allSatisfy({ !$0.isASCII })
        else { return }
        // 系统词库已有的词不重复存入用户词典
        let store = (currentMode == .pinyin) ? zhStore : jaStore
        if let store = store, store.candidates(for: pinyin).contains(word) { return }
        userDict?.save(pinyin: pinyin, word: word)
    }

    // MARK: - 统一切分组词 DP

    /// 统一音节切分与词库组词的单趟 DP。
    /// 直接在原始拼音字符串上操作，同时决定音节边界和短语匹配。
    /// 使用词频对数之和作为评分，选择整体最自然的组合。
    ///
    /// 例如 "jianchayixiane":
    ///   两阶段法: split→["jian","cha","yi","xian","e"] → 检查仪限额
    ///   统一 DP:  检查(580k)+一下(501k)+呢(高频) >> 检查仪(4k)+限额(138k)
    ///
    /// - Parameters:
    ///   - input: 原始拼音字符串（不含撇号，已小写）
    ///   - store: 词库
    /// - Returns: (组词结果, 音节切分) 或 nil（无法完全覆盖）
    private func unifiedCompose(_ input: String, store: DictionaryStore?)
        -> (text: String, syllables: [String])?
    {
        guard let store = store, !input.isEmpty else { return nil }

        let chars = Array(input)
        let n = chars.count

        struct DPState {
            var words: [String]
            var syllables: [String]
            var multiCharScore: Double  // 多字词 log(freq) 之和
            var multiCharCount: Int     // 多字词数量（用于计算平均分）
            var totalScore: Double      // 全部词 log(freq) 之和（次排序键）
            var sylCount: Int
        }

        var dp: [DPState?] = Array(repeating: nil, count: n + 1)
        dp[n] = DPState(words: [], syllables: [], multiCharScore: 0, multiCharCount: 0, totalScore: 0, sylCount: 0)

        // 从右往左填 DP
        for pos in stride(from: n - 1, through: 0, by: -1) {
            enumeratePhrases(chars: chars, from: pos, store: store) {
                word, frequency, syllables, endPos in
                guard let rest = dp[endPos] else { return }

                let wordScore = log(Double(max(frequency, 1)))
                let isMultiChar = word.count >= 2
                let multiCharScore = (isMultiChar ? wordScore : 0) + rest.multiCharScore
                let multiCharCount = (isMultiChar ? 1 : 0) + rest.multiCharCount
                let totalScore = wordScore + rest.totalScore
                let totalSyls = syllables.count + rest.sylCount

                // 多字词平均分：偏好更少但更高质量的多字词匹配
                let avgMulti = multiCharCount > 0
                    ? multiCharScore / Double(multiCharCount) : -1

                let candidate = DPState(
                    words: [word] + rest.words,
                    syllables: syllables + rest.syllables,
                    multiCharScore: multiCharScore,
                    multiCharCount: multiCharCount,
                    totalScore: totalScore,
                    sylCount: totalSyls)

                if let existing = dp[pos] {
                    let existingAvgMulti = existing.multiCharCount > 0
                        ? existing.multiCharScore / Double(existing.multiCharCount) : -1
                    // 主键：多字词平均频分越高越好
                    // 次键：总频分之和越高越好
                    if avgMulti > existingAvgMulti
                        || (avgMulti == existingAvgMulti
                            && totalScore > existing.totalScore)
                    {
                        dp[pos] = candidate
                    }
                } else {
                    dp[pos] = candidate
                }
            }
        }

        guard let best = dp[0] else { return nil }
        return (best.words.joined(), best.syllables)
    }

    /// 枚举从 pos 开始的所有合法短语：用 DFS 尝试连续音节组合并查词库。
    /// 每找到一个词库匹配就回调 (word, frequency, syllables, endPos)。
    private func enumeratePhrases(
        chars: [Character], from startPos: Int, store: DictionaryStore,
        callback: (String, Int, [String], Int) -> Void
    ) {
        let n = chars.count
        let maxSyl = PinyinSplitter.maxSyllableLength

        func dfs(_ curPos: Int, _ accPinyin: String, _ accSyllables: [String]) {
            guard curPos < n else { return }

            let remaining = n - curPos
            let maxLen = min(remaining, maxSyl)

            for sylLen in 1...maxLen {
                let syllable = String(chars[curPos..<(curPos + sylLen)])
                let normalized = Self.normalizePinyin(syllable)
                guard PinyinSplitter.validSyllables.contains(normalized)
                    || PinyinSplitter.validSyllables.contains(syllable)
                else { continue }

                let newPinyin = accPinyin + normalized
                let newSyllables = accSyllables + [syllable]
                let newPos = curPos + sylLen

                // 查词库，获取词和词频
                if let top = store.topCandidate(for: newPinyin) {
                    callback(top.word, top.frequency, newSyllables, newPos)
                }

                // 继续延伸，尝试更长的短语
                dfs(newPos, newPinyin, newSyllables)
            }
        }

        dfs(startPos, "", [])
    }

    // MARK: - 兼容性接口

    /// 兼容旧版调用接口
    public func getCandidates(for pinyin: String) -> [String] {
        let store = (currentMode == .pinyin) ? zhStore : jaStore
        return store?.candidates(for: pinyin.lowercased()) ?? []
    }
}
