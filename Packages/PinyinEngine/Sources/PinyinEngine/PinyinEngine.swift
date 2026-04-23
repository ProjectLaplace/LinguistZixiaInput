import Foundation

/// Conversion 路径诊断结果：一条切分路径的完整评分明细。
///
/// 术语参见 Conversion.md。chunk = DFS 切分单元（合法音节或裸声母），
/// segment = 路径段（对应一次词库命中），word = ≥2 字且 freq ≥ 10000 的词库条目。
public struct ConversionResult {
    /// 路径段：每段对应一次词库命中的 (word, pinyin, freq) 三元组
    public let segments: [(word: String, pinyin: String, frequency: Int)]
    /// 原始输入的切分单元序列（chunks），含合法音节和裸声母，与输入字符一一对应
    public let chunks: [String]
    /// 组合文本（所有 word 拼接）
    public let text: String
    /// 词段平均 log(freq)
    public let wordFreqAvg: Double
    /// 词覆盖率（被词覆盖的字数 / 总字数）
    public let wordCoverage: Double
    /// pathScore = wordFreqAvg + 4 * wordCoverage
    public let pathScore: Double
    /// 路径段总数（含反作弊：低频多字词段按 word.count 计入）
    public let segmentCount: Int
    /// 所有段 log(freq) 之和
    public let totalFreqSum: Double

    public init(
        segments: [(word: String, pinyin: String, frequency: Int)],
        chunks: [String] = [],
        text: String,
        wordFreqAvg: Double,
        wordCoverage: Double,
        pathScore: Double,
        segmentCount: Int,
        totalFreqSum: Double
    ) {
        self.segments = segments
        self.chunks = chunks
        self.text = text
        self.wordFreqAvg = wordFreqAvg
        self.wordCoverage = wordCoverage
        self.pathScore = pathScore
        self.segmentCount = segmentCount
        self.totalFreqSum = totalFreqSum
    }
}

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
    /// 本轮交互产生的待提交文本（如有）
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
    private var pinnedChars: PinnedCharStore?
    private var customPhrases: CustomPhraseStore?

    // 内部状态管理
    private var composingItems: [ComposingItem] = []
    private var candidates: [String] = []
    private var currentMode: InputMode = .pinyin

    // 自动切分状态
    private var rawPinyin: String = ""  // 当前正在输入的完整拼音串

    private var focusIndex: Int? = nil  // 聚焦的可编辑段索引，nil = 末尾
    private var firstSegmentCandidateStart: Int = 0  // 首段补充候选在 candidates 中的起始位置
    private var firstSegmentPinyin: String = ""  // 首段拼音（用于部分确认后截断 rawPinyin）

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

    /// 可触发「确认首选 + 提交标点」的标点字符集。
    /// 当缓冲区有候选时，这些字符会先确认首选候选再追加全角标点一并提交；
    /// 缓冲区为空时，直接提交全角标点。
    /// 注意：' 不在此集合中——有活跃拼音时作为分隔符，由 InputController 层特殊处理。
    public static let confirmPunctuationChars: Set<Character> = [
        ",", ".", ";", ":", "?", "!", "\\",
        "(", ")", "{", "}", "<", ">", "\"",
        "~", "$", "^", "_", "`",
    ]

    /// 使用 Bundle 内置词库初始化
    public init() {
        loadDictionaries()
        userDict = UserDictionary()
        pinnedChars = PinnedCharStore.loadDefault()
        customPhrases = CustomPhraseStore.loadDefault()
    }

    /// 使用指定的词库文件路径初始化
    public init(zhDictPath: String, jaDictPath: String) {
        zhStore = DictionaryStore(path: zhDictPath)
        jaStore = DictionaryStore(path: jaDictPath)
    }

    /// 使用指定的词库文件路径、用户词典路径、固顶字和自定义短语初始化（用于测试）
    public init(
        zhDictPath: String, jaDictPath: String, userDictPath: String,
        pinnedChars: PinnedCharStore? = nil,
        customPhrases: CustomPhraseStore? = nil
    ) {
        zhStore = DictionaryStore(path: zhDictPath)
        jaStore = DictionaryStore(path: jaDictPath)
        userDict = UserDictionary(path: userDictPath)
        self.pinnedChars = pinnedChars
        self.customPhrases = customPhrases
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
        Profiler.measure("process(\(event))", statsLabel: "process") {
            processInternal(event)
        }
    }

    /// v 开头内置命令：名称 → 结果生成闭包
    private static let vCommands: [String: () -> String] = [
        "vprofile": { Profiler.summary() },
        "vct": { BuildInfo.version },
        "vver": { BuildInfo.version },
        "vdate": {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        },
        "vtime": {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: Date())
        },
        "vdatetime": { vCommandDateTime() },
        "vdt": { vCommandDateTime() },
        "vcdate": {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "yyyy年M月d日"
            return f.string(from: Date())
        },
        "vweek": {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "EEEE"
            return f.string(from: Date())
        },
        "vuuid": { vCommandUUIDv7() },
        "vts": {
            String(Int(Date().timeIntervalSince1970))
        },
        "vpwd": { vCommandPassword(length: 16) },
        "vpin": {
            (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
        },
    ]

    private static func vCommandDateTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    private static func vCommandUUIDv7() -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)
        // 48-bit timestamp (ms)
        bytes[0] = UInt8((now >> 40) & 0xFF)
        bytes[1] = UInt8((now >> 32) & 0xFF)
        bytes[2] = UInt8((now >> 24) & 0xFF)
        bytes[3] = UInt8((now >> 16) & 0xFF)
        bytes[4] = UInt8((now >> 8) & 0xFF)
        bytes[5] = UInt8(now & 0xFF)
        // Random bytes for the rest
        for i in 6..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        // Version 7
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        // Variant 10xx
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let i = hex.startIndex
        func o(_ n: Int) -> String.Index { hex.index(i, offsetBy: n) }
        return "\(hex[i..<o(8)])-\(hex[o(8)..<o(12)])-\(hex[o(12)..<o(16)])-\(hex[o(16)..<o(20)])-\(hex[o(20)..<o(32)])"
    }

    private static func vCommandPassword(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%&*-_=+")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    private func processInternal(_ event: EngineEvent) -> EngineState {
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
            committedText = handleNumber(index)

        case .bracket(let pickLast):
            committedText = handleBracket(pickLast: pickLast)

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
        // 分段模式切换：在 Buffer 为空或处于段落边界（刚定完字）时，'i' 作为开关
        let isAtSegmentBoundary =
            composingItems.isEmpty
            || (!composingItems.last!.isEditable)
        if isAtSegmentBoundary && char.lowercased() == "i" {
            currentMode = (currentMode == .pinyin) ? .transient : .pinyin
            return
        }

        // 如果当前没有活跃的拼音输入（上次是 .text），开始新的拼音串
        if rawPinyin.isEmpty && !composingItems.isEmpty && !composingItems.last!.isEditable {
            // Starting a new pinyin segment after confirmed text
        }

        // Tab 聚焦模式下不追加字母，退出聚焦回到末尾
        focusIndex = nil

        // 保留原始大小写，拼音匹配时各处自行 lowercase
        rawPinyin += String(char)

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

    /// 处理空格键：确认候选并提交
    private func handleSpace() -> String? {
        guard !composingItems.isEmpty else { return nil }

        // v 开头内置命令：空格确认后提交结果
        if let vCommand = Self.vCommands[rawPinyin.lowercased()] {
            let result = vCommand()
            resetAll()
            return result
        }

        if let first = candidates.first {
            if focusIndex != nil {
                // Tab 聚焦模式：确认聚焦段，可能自动提交
                return confirmFocusedSegment(with: first)
            } else {
                // 正常模式：用候选替换整个拼音串，然后提交全部
                finalizeAllPinyin(with: first)
                let result = composingItems.map { $0.content }.joined()
                resetAll()
                return result
            }
        } else if !composingItems.isEmpty {
            // 无候选时（包括 Tab 模式全部确认后），提交缓冲区内容
            let result = composingItems.map { $0.content }.joined()
            resetAll()
            return result
        }
        return nil
    }

    // MARK: - 数字选词

    /// 处理数字选词
    private func handleNumber(_ index: Int) -> String? {
        // 自定义短语模式：rawPinyin 含 _ 且追加数字后能匹配到短语时，
        // 数字作为短语名的一部分（紫光惯例：sz_1、bq_2）。
        // 否则正常选词（如 dw_ 展开后用数字从候选列表选择）。
        if rawPinyin.contains("_") {
            let extended = rawPinyin.lowercased() + String(index)
            if customPhrases?.hasPhrase(extended) == true {
                rawPinyin += String(index)
                rebuildFromRawPinyin()
                return nil
            }
        }

        let actualIndex = index - 1
        guard actualIndex >= 0 && actualIndex < candidates.count else { return nil }

        if focusIndex != nil {
            // Tab 聚焦模式：确认聚焦段，可能自动提交
            return confirmFocusedSegment(with: candidates[actualIndex])
        } else if firstSegmentCandidateStart > 0 && actualIndex >= firstSegmentCandidateStart {
            // 首段补充候选：只确认首段，剩余拼音继续组词
            confirmFirstSegment(with: candidates[actualIndex])
            return nil
        } else {
            // 正常模式：用候选替换整个拼音串并提交
            finalizeAllPinyin(with: candidates[actualIndex])
            let result = composingItems.map { $0.content }.joined()
            resetAll()
            return result
        }
    }

    // MARK: - 以词定字

    /// 处理以词定字
    private func handleBracket(pickLast: Bool) -> String? {
        guard let first = candidates.first,
            let char = pickCharacter(from: first, pickLast: pickLast)
        else { return nil }

        if focusIndex != nil {
            return confirmFocusedSegment(with: char)
        } else {
            finalizeAllPinyin(with: char)
            return nil
        }
    }

    // MARK: - Tab 导航

    /// 处理 Tab 键：在可编辑段之间移动焦点
    private func handleTab(backward: Bool) {
        let editableIndices = composingItems.indices.filter { composingItems[$0].isEditable }
        guard !editableIndices.isEmpty else { return }

        if let current = focusIndex {
            // 已在聚焦模式，移动焦点（到头则停止）
            if let pos = editableIndices.firstIndex(of: current) {
                if backward {
                    guard pos > 0 else { return }
                    focusIndex = editableIndices[pos - 1]
                } else {
                    guard pos < editableIndices.count - 1 else { return }
                    focusIndex = editableIndices[pos + 1]
                }
            }
        } else {
            // 进入聚焦模式：backward 跳过末尾段（它已是活跃输入段），聚焦倒数第二个
            if backward && editableIndices.count >= 2 {
                focusIndex = editableIndices[editableIndices.count - 2]
            } else {
                focusIndex = backward ? editableIndices.last! : editableIndices.first!
            }
        }

        updateCandidatesForFocus()
    }

    // MARK: - 全角标点

    /// 处理标点输入：
    /// - 缓冲区为空时，直接提交全角标点。
    /// - 缓冲区有候选时，确认首选候选 + 提交全角标点。
    /// - 缓冲区有内容但无候选时，提交缓冲区原始内容 + 全角标点。
    private func handlePunctuation(_ char: Character) -> String? {
        let fullWidth = mapToFullWidth(char)

        if composingItems.isEmpty {
            return fullWidth
        } else {
            var result = ""
            if let first = candidates.first {
                finalizeAllPinyin(with: first)
                result = composingItems.map { $0.content }.joined()
            } else {
                result = composingItems.map { $0.content }.joined()
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

        // 先用 PinyinSplitter 做默认切分（用于候选匹配）
        let (defaultSyllables, remainder) = PinyinSplitter.splitPartial(rawPinyin)

        // 尝试用 Conversion 切分来构建 composingItems（Conversion 的切分更准确，考虑了词典）
        let store = (currentMode == .pinyin) ? zhStore : jaStore
        let cleanPinyin = rawPinyin.lowercased().replacingOccurrences(of: "'", with: "")
        let convResult = store.flatMap {
            Self.compose(cleanPinyin, store: $0, pinnedChars: pinnedChars)
        }

        if let conv = convResult {
            // Conversion 成功：用 chunks 的长度从 rawPinyin 截取原始片段
            // chunks 保留裸声母原始形式（如 "j" 而非展开后的 "ji"），与输入字符一一对应
            var offset = rawPinyin.startIndex
            for chunk in conv.chunks {
                while offset < rawPinyin.endIndex && rawPinyin[offset] == "'" {
                    offset = rawPinyin.index(after: offset)
                }
                let end = rawPinyin.index(offset, offsetBy: chunk.count)
                composingItems.append(.pinyin(String(rawPinyin[offset..<end])))
                offset = end
            }
            // Conversion 未覆盖的尾部（理论上不应发生，但兜底）
            if offset < rawPinyin.endIndex {
                while offset < rawPinyin.endIndex && rawPinyin[offset] == "'" {
                    offset = rawPinyin.index(after: offset)
                }
                if offset < rawPinyin.endIndex {
                    composingItems.append(.pinyin(String(rawPinyin[offset...])))
                }
            }
        } else {
            // Conversion 无结果：fallback 到 splitPartial
            if defaultSyllables.count > 1
                || (defaultSyllables.count == 1 && !remainder.isEmpty)
            {
                var offset = rawPinyin.startIndex
                for syllable in defaultSyllables {
                    while offset < rawPinyin.endIndex && rawPinyin[offset] == "'" {
                        offset = rawPinyin.index(after: offset)
                    }
                    let end = rawPinyin.index(offset, offsetBy: syllable.count)
                    composingItems.append(.pinyin(String(rawPinyin[offset..<end])))
                    offset = end
                }
                if !remainder.isEmpty {
                    while offset < rawPinyin.endIndex && rawPinyin[offset] == "'" {
                        offset = rawPinyin.index(after: offset)
                    }
                    composingItems.append(.pinyin(String(rawPinyin[offset...])))
                }
            } else {
                composingItems.append(.pinyin(rawPinyin))
            }
        }

        // 候选词：优先整串匹配
        updateCandidatesWholeString(defaultSyllables: defaultSyllables, remainder: remainder)
    }

    /// 更新候选词：精确匹配 → Conversion 组词 → 首段补充候选 → 前缀 → 末段兜底
    private func updateCandidatesWholeString(defaultSyllables: [String], remainder: String) {
        let _ucStart = CFAbsoluteTimeGetCurrent()
        let store = (currentMode == .pinyin) ? zhStore : jaStore

        // 0. 自定义短语：rawPinyin 完全匹配短语名时，短语候选置顶
        let cleanPinyin = Self.normalizePinyin(
            rawPinyin.lowercased().replacingOccurrences(of: "'", with: ""))
        let customResults = customPhrases?.phrases(for: cleanPinyin) ?? []

        // 1. 整串精确匹配（去掉 apostrophe，规范化 ü）
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

        // 3. 合并：系统整串 → 用户词典（去重）
        var result = wholeMatches
        let wholeSet = Set(wholeMatches)
        for word in userResults where !wholeSet.contains(word) {
            result.append(word)
        }

        // 4. 有精确匹配时跳过 Conversion；无精确匹配时用 Conversion 组词
        //    触发条件：多音节且无精确匹配。remainder 为裸声母时也触发（如 gangcd → gang+c, remainder=d）
        let remainderIsBareInitial =
            !remainder.isEmpty && PinyinSplitter.validInitials.contains(remainder)
        let shouldRunConversion =
            result.isEmpty && defaultSyllables.count > 1
            && (remainder.isEmpty || remainderIsBareInitial)
        var convResult: ConversionResult? = nil
        if shouldRunConversion {
            convResult = unifiedCompose(cleanPinyin, store: store)
            if let composed = convResult {
                result.append(composed.text)
            }
        }

        // 5. 首段补充候选：从 Conversion 结果或 PinyinSplitter 获取首段拼音，
        //    追加该拼音的其他候选，方便用户快速替换首词继续组词
        firstSegmentCandidateStart = 0
        firstSegmentPinyin = ""
        if (remainder.isEmpty || remainderIsBareInitial) && defaultSyllables.count > 1 {
            // 确定首段拼音：优先用 Conversion 结果的第一个词对应的音节
            let firstPinyin: String
            if let conv = convResult, !conv.segments.isEmpty {
                firstPinyin = conv.segments[0].pinyin
            } else {
                // 没有 Conversion 结果，用 PinyinSplitter 的第一个音节
                firstPinyin = Self.normalizePinyin(defaultSyllables[0])
            }

            // 精确匹配优先；无结果时 fallback 到前缀匹配（裸声母缩写场景）
            var firstSegCandidates = store?.candidates(for: firstPinyin) ?? []
            if firstSegCandidates.isEmpty {
                firstSegCandidates = store?.candidatesWithPrefix(firstPinyin) ?? []
                // 前缀匹配时限制字数与 Conversion 首段一致，避免引入不相关的长词
                if let conv = convResult, !conv.segments.isEmpty {
                    let wordLen = conv.segments[0].word.count
                    firstSegCandidates = firstSegCandidates.filter { $0.count == wordLen }
                }
            }
            // 固顶字也应用到首段补充候选
            if currentMode == .pinyin {
                firstSegCandidates = applyPinnedChars(for: firstPinyin, to: firstSegCandidates)
            }
            // 去掉已在主候选中出现的、以及与 Conversion 首词相同的
            let existingSet = Set(result)
            let filtered = firstSegCandidates.filter { !existingSet.contains($0) }

            if !filtered.isEmpty {
                firstSegmentCandidateStart = result.count
                firstSegmentPinyin = firstPinyin
                result.append(contentsOf: filtered)
            }

            // 首个完整音节的单字候选（如 gangcd → gang 的「刚」「港」「钢」等）
            let firstFullSyllable = Self.normalizePinyin(defaultSyllables[0])
            if firstFullSyllable != firstPinyin {
                var singleCharCandidates = store?.candidates(for: firstFullSyllable) ?? []
                if currentMode == .pinyin {
                    singleCharCandidates = applyPinnedChars(
                        for: firstFullSyllable, to: singleCharCandidates)
                }
                let existingAfter = Set(result)
                let singleFiltered = singleCharCandidates.filter { !existingAfter.contains($0) }
                result.append(contentsOf: singleFiltered)
            }
        }

        // 6. 前缀匹配兜底：精确匹配和 Conversion 都无结果时，用前缀匹配补充候选。
        //    两种触发场景：
        //    a) 音节不完整（remainder 不为空），如 b → ba, bai, ban... / xiangf → xiangfa...
        //    b) 单音节但词库无精确条目（如 n 是合法音节但词库无 pinyin='n'）
        //    单字限制：仅当无完整音节时（纯声母如 b/d），限制为单字，
        //    防止声母前缀匹配出「版权」等词；有完整音节时（如 xiangf）不限制。
        if result.isEmpty && (!remainder.isEmpty || defaultSyllables.count == 1) {
            // 纯声母时加大 limit，因为后续会过滤掉多字词只留单字
            let prefixLimit = defaultSyllables.isEmpty ? 100 : 9
            let prefixResults = store?.candidatesWithPrefix(cleanPinyin, limit: prefixLimit) ?? []
            result =
                defaultSyllables.isEmpty
                ? prefixResults.filter { $0.count == 1 }
                : prefixResults
        }

        // 7. 如果仍然没有，尝试最后一个活跃段的候选
        if result.isEmpty {
            if let lastPinyin = composingItems.last?.sourcePinyin {
                result = store?.candidates(for: Self.normalizePinyin(lastPinyin)) ?? []
            }
        }

        // 固顶字：单音节（含不完整前缀）时，将固顶字插入候选列表最前面
        if currentMode == .pinyin && defaultSyllables.count <= 1 {
            result = applyPinnedChars(for: cleanPinyin, to: result)
        }

        // 自定义短语置顶（去重）
        if !customResults.isEmpty {
            let customSet = Set(customResults)
            result = customResults + result.filter { !customSet.contains($0) }
        }

        candidates = result

        let _ucElapsed = (CFAbsoluteTimeGetCurrent() - _ucStart) * 1000
        Profiler.record(
            "updateCandidates", elapsed: _ucElapsed, detail: "updateCandidates(\(rawPinyin))")
        if _ucElapsed >= Profiler.thresholdMs {
            Profiler.event(
                "updateCandidates(\(rawPinyin)): \(String(format: "%.1f", _ucElapsed))ms")
        }
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
        let normalizedPinyin = Self.normalizePinyin(pinyin)
        var result = store?.candidates(for: normalizedPinyin) ?? []
        if currentMode == .pinyin {
            result = applyPinnedChars(for: normalizedPinyin, to: result)
        }
        candidates = result
    }

    /// 将固顶字插入候选列表最前面，去除重复
    private func applyPinnedChars(for pinyin: String, to candidates: [String]) -> [String] {
        guard let pinned = pinnedChars?.pinnedChars(for: pinyin), !pinned.isEmpty else {
            return candidates
        }
        let pinnedSet = Set(pinned)
        return pinned + candidates.filter { !pinnedSet.contains($0) }
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

    /// 确认 Tab 聚焦段的候选，然后移动焦点或自动提交
    /// 返回提交文本（所有段已确认时），nil 表示继续编辑
    @discardableResult
    private func confirmFocusedSegment(with text: String) -> String? {
        guard let idx = focusIndex, idx < composingItems.count else { return nil }

        composingItems[idx] = .text(text)

        // 从 rawPinyin 中移除已确认段的拼音
        rebuildRawPinyinFromItems()

        // 如果没有更多可编辑段，自动提交
        let editableIndices = composingItems.indices.filter { composingItems[$0].isEditable }
        if editableIndices.isEmpty {
            let result = composingItems.map { $0.content }.joined()
            resetAll()
            return result
        } else {
            // 移动到下一个可编辑段
            focusIndex = editableIndices.first { $0 > idx } ?? editableIndices.first
            updateCandidatesForFocus()
            return nil
        }
    }

    /// 确认首段候选：只替换首段拼音为选中文字，剩余拼音继续组词
    private func confirmFirstSegment(with text: String) {
        guard !firstSegmentPinyin.isEmpty else { return }

        // 将首段确认为 .text，截掉 rawPinyin 中对应的首段拼音
        let cleanRaw = rawPinyin.lowercased().replacingOccurrences(of: "'", with: "")
        let normalizedRaw = Self.normalizePinyin(cleanRaw)
        let normalizedFirst = firstSegmentPinyin  // 已经 normalized

        guard normalizedRaw.hasPrefix(normalizedFirst) else { return }

        // 更新 rawPinyin：移除首段拼音（在原始 rawPinyin 中定位）
        // 需要从原始 rawPinyin 中去掉对应长度的字符
        let remainingNormalized = String(normalizedRaw.dropFirst(normalizedFirst.count))

        // 重建：confirmed text + 剩余拼音继续组词
        let confirmedPrefix = composingItems.filter { !$0.isEditable }
        composingItems = confirmedPrefix
        composingItems.append(.text(text))
        rawPinyin = remainingNormalized
        focusIndex = nil
        firstSegmentCandidateStart = 0
        firstSegmentPinyin = ""

        if rawPinyin.isEmpty {
            candidates = []
        } else {
            rebuildFromRawPinyin()
        }
    }

    /// 从 composingItems 中残存的可编辑项重建 rawPinyin
    private func rebuildRawPinyinFromItems() {
        rawPinyin = composingItems.compactMap { $0.sourcePinyin }.joined()
    }

    /// 获取用于 Enter 提交的原文（拼音原文 + 已确定文本）
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
        focusIndex = nil
        firstSegmentCandidateStart = 0
        firstSegmentPinyin = ""
        if currentMode == .transient { currentMode = .pinyin }
    }

    /// 以词定字辅助：截取首尾字符
    private func pickCharacter(from candidate: String, pickLast: Bool) -> String? {
        guard !candidate.isEmpty else { return nil }
        return pickLast ? String(candidate.last!) : String(candidate.first!)
    }

    /// 将拼音中 u 作为 ü 的替代写法规范化为 v（仅限 l/n 声母后的 ue→ve）
    public static func normalizePinyin(_ pinyin: String) -> String {
        var result = pinyin
        result = result.replacingOccurrences(of: "lue", with: "lve")
        result = result.replacingOccurrences(of: "nue", with: "nve")
        return result
    }

    // MARK: - Conversion 切分组词 DP

    /// Conversion 核心：统一音节切分与词库组词的单趟 DP。
    /// 直接在原始拼音字符串上操作，同时决定音节边界和短语匹配。
    /// 使用词频对数之和作为评分，选择整体最自然的组合。
    ///
    /// 例如 "jianchayixiane":
    ///   两阶段法: split→["jian","cha","yi","xian","e"] → 检查仪限额
    ///   Conversion:  检查(580k)+一下(501k)+呢(高频) >> 检查仪(4k)+限额(138k)
    ///
    /// 对拼音串执行 Conversion 切分并返回最优路径的评分明细。
    /// 这是引擎和 eval 工具共用的唯一 Conversion 实现。
    ///
    /// 术语定义参见 Conversion.md。
    public static func compose(
        _ input: String, store: DictionaryStore, pinnedChars: PinnedCharStore? = nil
    ) -> ConversionResult? {
        let chars = Array(input)
        let n = chars.count
        guard n > 0 else { return nil }

        /// Conversion DP 填表的中间状态。字段含义与 ConversionResult 一致，但额外保留了
        /// wordFreqSum / wordCount / wordCharCount（用于累加），以及 charCount（分母）。
        struct ConversionState {
            var segments: [(word: String, pinyin: String, frequency: Int)]
            var chunks: [String]  // DFS 切分单元序列（含合法音节和裸声母）
            var wordFreqSum: Double  // 词段 log(freq) 之和
            var wordCount: Int  // 词段数量（word.count >= 2 且 freq >= 10000）
            var wordCharCount: Int  // 被词段覆盖的字数
            var totalFreqSum: Double  // 所有段 log(freq) 之和
            var segmentCount: Int  // 路径段总数（含反作弊：低频多字词按 word.count 计入）
            var charCount: Int  // 产出字数（= 所有段 word.count 之和）
            var chunkCount: Int  // DFS 切分单元数（越少越好，避免 gang→ga+ng）
        }

        // 路径比较顺序（参见 Conversion.md "比较顺序"）：
        // 主键：pathScore = wordFreqAvg + 4 · wordCoverage
        // 次键：segmentCount 越小越好（避免 jiao 被拆成 ji+a+o）
        // 三键：chunkCount 越小越好（避免 gang 被拆成 ga+ng）
        //        原则：系统应优先选更紧凑的切分，用户可用 ' 主动拆分，
        //        但无法反向合并系统已拆开的音节。
        // 末键：totalFreqSum 越大越好
        //
        // α=4 的直觉：wordCoverage 从 0.8→1.0（+0.2）等价于 wordFreqAvg 提升 0.8。
        // 让高质量多字词（log=13）能压过低质量全覆盖（avg=9），
        // 同时同质量下全覆盖（精确+匹配）胜过有单字填充的（景区+饿+匹配）。
        func isBetter(_ a: ConversionState, than b: ConversionState) -> Bool {
            func pathScore(_ s: ConversionState) -> Double {
                let wordFreqAvg =
                    s.wordCount > 0
                    ? s.wordFreqSum / Double(s.wordCount) : -1
                let wordCoverage =
                    s.charCount > 0
                    ? Double(s.wordCharCount) / Double(s.charCount) : 0
                return wordFreqAvg + 4.0 * wordCoverage
            }
            let aScore = pathScore(a)
            let bScore = pathScore(b)
            if aScore != bScore { return aScore > bScore }
            if a.segmentCount != b.segmentCount { return a.segmentCount < b.segmentCount }
            if a.chunkCount != b.chunkCount { return a.chunkCount < b.chunkCount }
            return a.totalFreqSum > b.totalFreqSum
        }

        var dp: [ConversionState?] = Array(repeating: nil, count: n + 1)
        dp[n] = ConversionState(
            segments: [], chunks: [], wordFreqSum: 0, wordCount: 0,
            wordCharCount: 0, totalFreqSum: 0, segmentCount: 0, charCount: 0, chunkCount: 0)

        // 从右往左填 DP
        for pos in stride(from: n - 1, through: 0, by: -1) {
            enumeratePhrases(chars: chars, from: pos, store: store, pinnedChars: pinnedChars) {
                word, frequency, chunks, endPos in
                guard let rest = dp[endPos] else { return }

                let segmentFreq = log(Double(max(frequency, 1)))
                // 低频多字词（freq < 10000）视为噪声，不计入词段评分和覆盖率
                // 例如「的脚」(5555) 不应作为词段提升 wordCoverage
                let isWord = word.count >= 2 && frequency >= 10000
                let wordFreqSum = (isWord ? segmentFreq : 0) + rest.wordFreqSum
                let wordCount = (isWord ? 1 : 0) + rest.wordCount
                // 用 word.count（字数 = 真实音节数）而非 chunks.count（DFS 切分数）
                // DFS 可能把 "yixia" 切成 ["yi","xi","a"]（3 段），但一下只有 2 个音节
                let wordChars = word.count
                let wordCharCount = (isWord ? wordChars : 0) + rest.wordCharCount
                let totalFreqSum = segmentFreq + rest.totalFreqSum
                // 反作弊：低频多字词按字数计入段数，避免垃圾词（如「的脚」）
                // 通过"减少段数"获益（段数是次键，越小越好）
                let segmentContribution = (!isWord && word.count >= 2) ? word.count : 1
                let segmentCount = segmentContribution + rest.segmentCount
                let charCount = wordChars + rest.charCount

                let pinyinStr = chunks.joined()
                let candidate = ConversionState(
                    segments: [(word, pinyinStr, frequency)] + rest.segments,
                    chunks: chunks + rest.chunks,
                    wordFreqSum: wordFreqSum,
                    wordCount: wordCount,
                    wordCharCount: wordCharCount,
                    totalFreqSum: totalFreqSum,
                    segmentCount: segmentCount,
                    charCount: charCount,
                    chunkCount: chunks.count + rest.chunkCount)

                if let existing = dp[pos] {
                    if isBetter(candidate, than: existing) {
                        dp[pos] = candidate
                    }
                } else {
                    dp[pos] = candidate
                }
            }
        }

        guard let best = dp[0] else { return nil }
        let wordFreqAvg =
            best.wordCount > 0
            ? best.wordFreqSum / Double(best.wordCount) : -1
        let wordCoverage =
            best.charCount > 0
            ? Double(best.wordCharCount) / Double(best.charCount) : 0
        return ConversionResult(
            segments: best.segments,
            chunks: best.chunks,
            text: best.segments.map { $0.word }.joined(),
            wordFreqAvg: wordFreqAvg,
            wordCoverage: wordCoverage,
            pathScore: wordFreqAvg + 4.0 * wordCoverage,
            segmentCount: best.segmentCount,
            totalFreqSum: best.totalFreqSum)
    }

    private func unifiedCompose(_ input: String, store: DictionaryStore?)
        -> ConversionResult?
    {
        let _ucStart = CFAbsoluteTimeGetCurrent()
        defer {
            let _ucElapsed = (CFAbsoluteTimeGetCurrent() - _ucStart) * 1000
            Profiler.record(
                "unifiedCompose", elapsed: _ucElapsed, detail: "unifiedCompose(\(input))")
            if _ucElapsed >= Profiler.thresholdMs {
                Profiler.event("unifiedCompose(\(input)): \(String(format: "%.1f", _ucElapsed))ms")
            }
        }
        guard let store = store, !input.isEmpty else { return nil }
        return Self.compose(input, store: store, pinnedChars: pinnedChars)
    }

    /// 枚举从 pos 开始的所有合法短语：用 DFS 尝试连续音节组合并查词库。
    /// 每找到一个词库匹配就回调 (word, frequency, chunks, endPos)。
    /// chunks 是 DFS 切分单元序列（合法音节或裸声母），与输入字符一一对应。
    /// 支持裸声母展开：当位置上的字符是合法声母但不构成完整音节时，
    /// 展开为该声母的所有合法音节，查词库取 top 单字参与评分。
    private static func enumeratePhrases(
        chars: [Character], from startPos: Int, store: DictionaryStore,
        pinnedChars: PinnedCharStore? = nil,
        callback: (String, Int, [String], Int) -> Void
    ) {
        let n = chars.count
        let maxSyl = PinyinSplitter.maxSyllableLength

        func dfs(_ curPos: Int, _ accPinyin: String, _ accSyllables: [String]) {
            guard curPos < n else { return }

            let remaining = n - curPos
            let maxLen = min(remaining, maxSyl)
            var foundSyllable = false

            for sylLen in 1...maxLen {
                let syllable = String(chars[curPos..<(curPos + sylLen)])
                let normalized = Self.normalizePinyin(syllable)
                guard
                    PinyinSplitter.validSyllables.contains(normalized)
                        || PinyinSplitter.validSyllables.contains(syllable)
                else { continue }

                foundSyllable = true
                let newPinyin = accPinyin + normalized
                let newSyllables = accSyllables + [syllable]
                let newPos = curPos + sylLen

                // 查词库，获取词和词频
                if var top = store.topCandidate(for: newPinyin) {
                    // 单字匹配时，固顶字替代词库默认字
                    if top.word.count == 1,
                        let pinned = pinnedChars?.pinnedChars(for: newPinyin),
                        let first = pinned.first
                    {
                        top.word = first
                    }
                    callback(top.word, top.frequency, newSyllables, newPos)
                }

                // 继续延伸，尝试更长的短语
                dfs(newPos, newPinyin, newSyllables)
            }

            // 裸声母展开：当前位置无法构成完整音节时，
            // 检查是否为合法声母，展开为所有合法音节查词库候选。
            // - 顶层（accPinyin 为空）：仅取单字，避免裸声母直接映射到多字词
            // - DFS 递归内（accPinyin 非空）：允许多字词，利用上下文短语匹配
            //   如 gang+c 展开为 gangcai → 刚才（高频双字词胜过 gang→刚 + c→从）
            // 不继续 DFS 延伸，避免组合爆炸。
            if !foundSyllable {
                let isTopLevel = accPinyin.isEmpty
                // 尝试双字母声母（zh/ch/sh），再尝试单字母声母
                for initialLen in [2, 1] {
                    guard initialLen <= remaining else { continue }
                    let initial = String(chars[curPos..<(curPos + initialLen)])
                    guard let expansions = PinyinSplitter.syllablesForInitial[initial] else {
                        continue
                    }

                    // 碎片化防护：若前一音节尾 + 裸声母首字符可组成另一合法音节，
                    // 说明用户输入更自然地解读为更长的单一音节，裸声母展开应跳过。
                    // 例：["gan"] + "g" → "gang" 合法 → 阻止 gan+g(→ga)=尴尬 的虚假匹配
                    //     ["yo","n"] + "g" → "ng" 合法 → 阻止 yo+n+g(→gan)=永安
                    if let lastSyl = accSyllables.last, let firstChar = initial.first {
                        let combined = lastSyl + String(firstChar)
                        if PinyinSplitter.validSyllables.contains(combined) {
                            continue
                        }
                    }

                    let newPos = curPos + initialLen
                    for expanded in expansions {
                        let expandedPinyin = accPinyin + expanded
                        if var top = store.topCandidate(for: expandedPinyin) {
                            // 顶层展开只取单字；递归内允许多字词（有短语上下文）
                            if !isTopLevel || top.word.count == 1 {
                                // 单字匹配时，固顶字替代词库默认字
                                // 优先用原始声母查固顶字（如 h → "哈"），
                                // 再 fallback 到展开后的完整音节
                                if top.word.count == 1 {
                                    let pinnedForInitial =
                                        pinnedChars?.pinnedChars(for: initial) ?? []
                                    let pinnedForExpanded =
                                        pinnedChars?.pinnedChars(for: expandedPinyin) ?? []
                                    if let first = pinnedForInitial.first ?? pinnedForExpanded.first
                                    {
                                        top.word = first
                                    }
                                }
                                callback(
                                    top.word, top.frequency, accSyllables + [initial], newPos)
                            }
                        }
                    }
                    break  // 优先双字母声母，匹配到就不再尝试单字母
                }
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
