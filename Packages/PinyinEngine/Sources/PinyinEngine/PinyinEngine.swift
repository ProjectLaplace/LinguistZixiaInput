import Foundation

/// 组合项：可以是确定的文本、待处理的拼音、自动匹配的预览，或字面块。
/// 复合缓冲区架构的核心，支持「以词定字」后的持续组词以及大小写混输。
public enum ComposingItem: Equatable {
    case text(String)
    case pinyin(String)
    /// 自动匹配的预览项：显示候选汉字，但仍可通过 Tab 聚焦后替换
    case provisional(pinyin: String, candidate: String)
    /// 字面块：连续大写字母聚合为一个不参与拼音切分的英文片段，
    /// 提交时按原样保留（如 API、USA），与相邻拼音段在中英边界自动加空格。
    case literal(String)

    /// 是否为活跃的拼音输入项
    public var isPinyin: Bool {
        if case .pinyin = self { return true }
        return false
    }

    /// 是否为字面块
    public var isLiteral: Bool {
        if case .literal = self { return true }
        return false
    }

    /// 是否为可编辑项（拼音或预览）。字面块由大写聚合规则维护，不参与 Tab 聚焦与候选选词。
    public var isEditable: Bool {
        switch self {
        case .pinyin, .provisional: return true
        case .text, .literal: return false
        }
    }

    /// 获取该项的原始拼音（仅对拼音和预览项有效）
    public var sourcePinyin: String? {
        switch self {
        case .pinyin(let s): return s
        case .provisional(let pinyin, _): return pinyin
        case .text, .literal: return nil
        }
    }

    /// 获取该项的显示文本内容
    public var content: String {
        switch self {
        case .text(let s), .pinyin(let s), .literal(let s): return s
        case .provisional(_, let candidate): return candidate
        }
    }

    /// 判定相邻两项之间是否应当插入一个空格分隔（用于 marked text 渲染与 commit 字符串拼接）。
    ///
    /// 规则按相邻项的语义类别判定：
    /// - 拼音段 / 预览段 ↔ 字面块：始终补空格（混输边界，与产品要求的 `xian'zai API` 呈现一致）。
    /// - 已确认 .text ↔ 拼音段 / 预览段：不补空格（拼音此时仍处可编辑状态，最终归宿为中文）。
    /// - 已确认 .text ↔ 字面块、或两个已确认 .text 相邻：按内容首末字符判定中↔拉边界，
    ///   出现「中文 ↔ 拉丁字母 / 数字」边界时补空格；同向拼接时不补。
    /// - 同类拼音段 / 同类预览段 / 字面块两两相邻：实际不会发生（聚合规则保证），不补。
    public static func needsSeparatorSpace(before prev: ComposingItem, after next: ComposingItem)
        -> Bool
    {
        let prevEditable = prev.isEditable
        let nextEditable = next.isEditable
        let prevLiteral = prev.isLiteral
        let nextLiteral = next.isLiteral

        // 拼音 / 预览 ↔ 字面块：恒补空格
        if (prevEditable && nextLiteral) || (prevLiteral && nextEditable) {
            return true
        }

        // 与拼音 / 预览相邻的 .text：不补空格（保留现状）
        if prevEditable || nextEditable {
            return false
        }

        // 此时两侧均为 .text 或 .literal，按内容首末字符判中↔拉边界
        guard let lastCh = prev.content.last, let firstCh = next.content.first else {
            return false
        }
        let lastLatin = isLatinBoundaryCharacter(lastCh)
        let firstLatin = isLatinBoundaryCharacter(firstCh)
        let lastHan = isHanBoundaryCharacter(lastCh)
        let firstHan = isHanBoundaryCharacter(firstCh)
        return (lastLatin && firstHan) || (lastHan && firstLatin)
    }

    /// 是否为参与中↔拉边界判定的拉丁字符（ASCII 字母或数字）。
    private static func isLatinBoundaryCharacter(_ ch: Character) -> Bool {
        guard ch.isASCII else { return false }
        return ch.isLetter || ch.isNumber
    }

    /// 是否为参与中↔拉边界判定的中文字符（CJK 汉字范围）。
    private static func isHanBoundaryCharacter(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic
        }
    }
}

/// 输入序列中的原始片段：拼音段（小写字母 / 撇号）或字面块（连续大写字母聚合）。
/// 引擎内部按输入顺序维护片段列表，驱动混输组词时按片段类型分别处理。
internal enum RawSpan: Equatable {
    case pinyin(String)
    case literal(String)

    var isLiteral: Bool {
        if case .literal = self { return true }
        return false
    }

    /// 片段长度（字符数）。用于退格按字符回退。
    var length: Int {
        switch self {
        case .pinyin(let s), .literal(let s): return s.count
        }
    }

    /// 在尾部追加一个字符；若类型不匹配返回 nil（调用方需新建片段）。
    func appending(_ char: Character) -> RawSpan? {
        switch self {
        case .pinyin(let s):
            guard !char.isUppercase else { return nil }
            return .pinyin(s + String(char))
        case .literal(let s):
            guard char.isUppercase else { return nil }
            return .literal(s + String(char))
        }
    }

    /// 删除尾部一个字符；空串返回 nil（调用方应将该片段从列表移除）。
    func droppingLast() -> RawSpan? {
        switch self {
        case .pinyin(let s):
            let next = String(s.dropLast())
            return next.isEmpty ? nil : .pinyin(next)
        case .literal(let s):
            let next = String(s.dropLast())
            return next.isEmpty ? nil : .literal(next)
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
    /// 在候选列表中循环移动激活候选（不提交）。配合 [ ] 在长串场景下选字组词。
    case cycleActiveCandidate(backward: Bool)
    case punctuation(Character)
    /// 诊断：记录当前拼音 + 候选 + Conversion 路径到 glitch 日志（marker 启用时）。
    /// 不改变组合状态，仅触发日志写入与 UI 反馈。
    case logGlitch
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
    /// 当前激活的候选索引（在 candidates 列表中的位置）。
    /// 默认为 0（首选）；通过 Ctrl+Tab 等导航事件可游走到其他候选。
    /// bracket 等基于「当前候选」的操作以此为准。
    public let activeCandidateIndex: Int
    /// 本轮事件是否触发了 glitch 日志写入（供 UI 显示"已记录"反馈）
    public let glitchLogged: Bool

    /// 组合缓冲区的完整拼接字符串（用于 UI 调试）
    public var fullDisplayBuffer: String {
        items.map { $0.content }.joined()
    }

    /// 初始空闲状态
    public static let idle = EngineState(
        items: [], candidates: [], committedText: nil, mode: .pinyin,
        focusedSegmentIndex: nil, activeCandidateIndex: 0, glitchLogged: false)
}

/// PinyinEngine 核心逻辑
/// 采用复合缓冲区（Composite Buffer）设计，支持多阶段组词与临时模式扩展。
public class PinyinEngine {
    // 词库：物理分离，SQLite 支持
    private var zhStore: DictionaryStore?
    private var jaStore: DictionaryStore?
    private var userDict: UserDictionary?
    private var pinnedChars: PinnedCharStore?
    private var pinnedWords: PinnedWordStore?
    private var customPhrases: CustomPhraseStore?

    // 内部状态管理
    private var composingItems: [ComposingItem] = []
    private var candidates: [String] = [] {
        didSet {
            activeCandidateIndex = 0
            partialConsumedPinyin = [:]
            mixedFirstSpanCandidates = []
            mixedFirstLiteralCandidates = []
        }
    }
    private var currentMode: InputMode = .pinyin
    /// 当前激活候选索引；任何对 candidates 的赋值会经 didSet 归零
    private var activeCandidateIndex: Int = 0

    // 自动切分状态
    /// 原始输入序列：按输入顺序排列的拼音段与字面块。
    /// 拼音段对应连续小写字母（含撇号），字面块对应连续大写字母聚合而成的英文片段。
    /// 不含字面块时与单一拼音串等价；含字面块时驱动混输组词流程。
    private var rawSpans: [RawSpan] = []

    /// 当前正在输入的完整拼音串：所有拼音段按顺序拼接。
    /// 字面块**不参与**该串，但仍出现在 `rawSpans` 中。
    /// 用作纯拼音路径（v 命令、glitch 日志、撇号语义判定等）的兼容接口。
    private var rawPinyin: String {
        get {
            rawSpans.compactMap { span -> String? in
                if case .pinyin(let s) = span { return s }
                return nil
            }.joined()
        }
        set {
            // 写入语义：丢弃所有现有 span，重置为单一拼音段（或空）。
            // 仅供既有路径（compose 模式回填、`confirmFirstSegment` 等纯拼音流程）使用，
            // 这些路径不会与字面块共存。
            if newValue.isEmpty {
                rawSpans = []
            } else {
                rawSpans = [.pinyin(newValue)]
            }
        }
    }

    private var focusIndex: Int? = nil  // 聚焦的可编辑段索引，nil = 末尾

    /// 候选文本到该候选实际消耗的拼音段的映射。仅在候选未覆盖整个 cleanPinyin 时登记；
    /// 未登记的候选默认覆盖整串拼音，被选中时进入 `finalizeAllPinyin`；
    /// 已登记的候选被选中时进入 `confirmFirstSegment`，按记录的拼音段截除 rawPinyin 后继续组词。
    private var partialConsumedPinyin: [String: String] = [:]

    /// 混输态首拼音段备选集合：登记 `rebuildMixedComposition` 为首拼音段产出的候选文本。
    /// 选中时走 `confirmMixedFirstSpanIntoComposingText`，把首拼音段译文确认进
    /// 预编辑文本（marked text）继续组词，不直接写出到宿主文档；与纯拼音模式
    /// 选 pos 2+ 走 `confirmFirstSegment` 的语义保持一致。pos 1 整句候选不登记，
    /// 仍走 `finalizeAllPinyin` 整串提交语义。
    private var mixedFirstSpanCandidates: Set<String> = []

    /// 混输态首字面块候选集合：当 `rawSpans` 第一个 chunk 为 `.literal` 时，
    /// `rebuildMixedComposition` 把字面块本身作为 pos 2 候选登记于此。
    /// 选中时走 `confirmMixedFirstLiteralIntoComposingText`，将字面块作为一个
    /// 离散步骤推进预编辑文本，余下 spans 重建组词；与首拼音段路径对仗。
    private var mixedFirstLiteralCandidates: Set<String> = []

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
    /// 注意：' 不在此集合中：有活跃拼音时作为分隔符，由 InputController 层特殊处理。
    public static let confirmPunctuationChars: Set<Character> = [
        ",", ".", ";", ":", "?", "!", "\\",
        "(", ")", "{", "}", "<", ">", "\"",
        "~", "$", "^", "_", "`",
    ]

    /// 使用 Bundle 内置词库初始化
    public init() {
        let variant = Self.persistedZhDictVariant() ?? "zh_dict"
        loadDictionaries(zhVariant: variant)
        currentZhDictVariant = variant
        userDict = UserDictionary()
        pinnedChars = PinnedCharStore.loadDefault()
        pinnedWords = PinnedWordStore.loadDefault()
        customPhrases = CustomPhraseStore.loadDefault()
    }

    /// 使用指定的词库文件路径初始化
    public init(zhDictPath: String, jaDictPath: String) {
        zhStore = DictionaryStore(path: zhDictPath)
        jaStore = DictionaryStore(path: jaDictPath)
    }

    /// 使用指定的词库文件路径、用户词典路径、固顶字/词和自定义短语初始化（用于测试）
    public init(
        zhDictPath: String, jaDictPath: String, userDictPath: String,
        pinnedChars: PinnedCharStore? = nil,
        pinnedWords: PinnedWordStore? = nil,
        customPhrases: CustomPhraseStore? = nil
    ) {
        zhStore = DictionaryStore(path: zhDictPath)
        jaStore = DictionaryStore(path: jaDictPath)
        userDict = UserDictionary(path: userDictPath)
        self.pinnedChars = pinnedChars
        self.pinnedWords = pinnedWords
        self.customPhrases = customPhrases
    }

    // MARK: - 词库加载

    /// 当前加载的中文词库变体（对应 `zhDictVariants` 里的文件名前缀）。
    public private(set) var currentZhDictVariant: String = "zh_dict"

    /// 可切换的中文词库变体（按循环顺序）。`zh_dict` 始终存在；其余备用词库仅在
    /// 已随 bundle 打包时才会出现在列表中，使默认构建（仅 ship `zh_dict`）启动时
    /// 不会因找不到文件而崩溃。
    /// - `zh_dict`：shipped 默认（rime-ice default 预设）
    /// - `zh_dict_ice_full`：rime-ice full 预设，词汇更全
    /// - `zh_dict_frost_default`：rime-frost default 预设，另一维护线
    /// - `zh_dict_frost_full`：rime-frost full 预设
    public static var zhDictVariants: [String] {
        let optional: [String] = [
            "zh_dict_ice_full", "zh_dict_frost_default", "zh_dict_frost_full",
        ]
        .filter { Bundle.module.url(forResource: $0, withExtension: "db") != nil }
        return ["zh_dict"] + optional
    }

    /// `UserDefaults` 中保存当前词库变体的键名。轻量软状态，不写入配置文件。
    private static let zhDictVariantDefaultsKey = "zhDictVariant"

    /// 读取上次保存的词库变体，校验仍在 `zhDictVariants` 列表内才返回；
    /// 缺失或失效（旧版本写入的过时变体）时返回 nil，由调用方回退到默认。
    private static func persistedZhDictVariant() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: zhDictVariantDefaultsKey),
            zhDictVariants.contains(raw)
        else { return nil }
        return raw
    }

    /// 运行时切换中文词库。失败返回 false，保留原 store 不变。
    /// 成功时将变体写入 `UserDefaults`，供下次进程启动恢复。
    /// - Parameter variant: `zhDictVariants` 里的文件名前缀（不含 `.db`）
    @discardableResult
    public func switchZhDict(variant: String) -> Bool {
        guard let url = Bundle.module.url(forResource: variant, withExtension: "db") else {
            return false
        }
        guard let newStore = DictionaryStore(path: url.path) else {
            return false
        }
        zhStore = newStore
        currentZhDictVariant = variant
        UserDefaults.standard.set(variant, forKey: Self.zhDictVariantDefaultsKey)
        return true
    }

    /// 从 Bundle 资源加载 SQLite 词库。`zhVariant` 由 init 校验后传入。
    private func loadDictionaries(zhVariant: String) {
        if let url = Bundle.module.url(forResource: zhVariant, withExtension: "db") {
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

    /// 当前引擎状态的只读快照，不触发任何 event。
    /// 用于 `pinCandidate` / `unpinCandidate` 这类内部修改候选后、调用方需重新读取 state 的场景。
    public var currentState: EngineState {
        EngineState(
            items: composingItems,
            candidates: candidates,
            committedText: nil,
            mode: currentMode,
            focusedSegmentIndex: focusIndex,
            activeCandidateIndex: activeCandidateIndex,
            glitchLogged: false
        )
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
        "vtime": { vCommandISODateTime() },
        "vti": { vCommandISODateTime() },
        "vtimeu": { vCommandISODateTimeUTC() },
        "vtiu": { vCommandISODateTimeUTC() },
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
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func vCommandISODateTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: Date())
    }

    private static func vCommandISODateTimeUTC() -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        // 「'Z'」为字面量 Z（Zulu time 标记），与格式 token「Z」（输出数字偏移）区分
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
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
        return
            "\(hex[i..<o(8)])-\(hex[o(8)..<o(12)])-\(hex[o(12)..<o(16)])-\(hex[o(16)..<o(20)])-\(hex[o(20)..<o(32)])"
    }

    private static func vCommandPassword(length: Int) -> String {
        let chars = Array(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%&*-_=+")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    private func processInternal(_ event: EngineEvent) -> EngineState {
        var committedText: String? = nil
        var glitchLogged = false

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

        case .cycleActiveCandidate(let backward):
            handleCycleActiveCandidate(backward: backward)

        case .punctuation(let char):
            committedText = handlePunctuation(char)

        case .logGlitch:
            glitchLogged = handleLogGlitch()
        }

        return EngineState(
            items: composingItems,
            candidates: candidates,
            committedText: committedText,
            mode: currentMode,
            focusedSegmentIndex: focusIndex,
            activeCandidateIndex: activeCandidateIndex,
            glitchLogged: glitchLogged
        )
    }

    /// 诊断：把当前 rawPinyin + 候选 + Conversion 路径写入 glitch 日志。
    /// 仅当 marker 启用 + rawPinyin 非空 + 拼音模式时才记录并返回 true。
    private func handleLogGlitch() -> Bool {
        guard !rawPinyin.isEmpty, currentMode == .pinyin else { return false }
        guard GlitchLogger.shared.isEnabled else { return false }

        let cleanPinyin = rawPinyin.lowercased().replacingOccurrences(of: "'", with: "")
        let conv = zhStore.flatMap {
            Conversion.compose(
                cleanPinyin, store: $0, pinnedChars: pinnedChars, pinnedWords: pinnedWords)
        }

        GlitchLogger.shared.log(
            pinyin: cleanPinyin,
            candidates: candidates,
            conv: conv
        )
        return true
    }

    // MARK: - 字母输入

    /// 处理字母按键：涉及模式切换、拼音追加、字面块聚合与自动切分。
    ///
    /// 大写字母（含 Caps Lock 触发）被聚合为字面块嵌入整句组词流程，
    /// 不参与拼音切分但保留在最终候选字符串里。
    /// 字面块与拼音段在中英边界自动加空格，与 macOS 系统拼音的混输行为对齐。
    private func handleLetter(_ char: Character) {
        // 分段模式切换：在 Buffer 为空或处于段落边界（刚定完字）时，小写 'i' 作为开关。
        // 大写 I 必须走字面块路径，不应触发日文 transient 模式。
        let isAtSegmentBoundary =
            composingItems.isEmpty
            || (!composingItems.last!.isEditable)
        if isAtSegmentBoundary && char == "i" {
            currentMode = (currentMode == .pinyin) ? .transient : .pinyin
            return
        }

        // Tab 聚焦模式下不追加字母，退出聚焦回到末尾
        focusIndex = nil

        appendCharToRawSpans(char)

        rebuildFromRawPinyin()
    }

    /// 把一个字母追加到 `rawSpans` 末尾。大写归入字面块，小写（及撇号等）归入拼音段；
    /// 类型不匹配时新开一个片段，从而实现连续大写自然聚合。
    ///
    /// 例外：当大写字母与既有 raw 串拼接后仍能命中某个自定义短语前缀时，
    /// 退回到拼音段路径，保持 customPhrases 对大小写敏感短语名（如 `XL0`）的支持。
    private func appendCharToRawSpans(_ char: Character) {
        if char.isUppercase, !shouldOpenLiteralSpan(for: char) {
            // 大写字母让步给 customPhrases 短语续输：作为拼音段字符追加。
            // 由于 RawSpan.pinyin.appending 拒绝大写，此处需直接绕过 appending 守卫。
            if let last = rawSpans.last, case .pinyin(let s) = last {
                rawSpans[rawSpans.count - 1] = .pinyin(s + String(char))
            } else {
                rawSpans.append(.pinyin(String(char)))
            }
            return
        }

        if let last = rawSpans.last, let merged = last.appending(char) {
            rawSpans[rawSpans.count - 1] = merged
            return
        }
        if char.isUppercase {
            rawSpans.append(.literal(String(char)))
        } else {
            rawSpans.append(.pinyin(String(char)))
        }
    }

    /// 判定大写字母是否应开启字面块。当任何已注册自定义短语以「当前 raw 串 + 该字符」为前缀时，
    /// 视为短语续输继续累积，不开字面块；否则进入字面块路径。
    private func shouldOpenLiteralSpan(for char: Character) -> Bool {
        guard let phrases = customPhrases else { return true }
        let prefix = rawSpansConcatenated() + String(char)
        return !phrases.hasPhrasePrefix(prefix)
    }

    /// 把所有 `rawSpans` 按原始字符顺序拼接成单一字符串（含字面块大写、拼音小写、撇号等原样）。
    /// 仅用于 customPhrase 前缀查询；拼音切分链路另有 `rawPinyin` 视图。
    private func rawSpansConcatenated() -> String {
        rawSpans.map { span -> String in
            switch span {
            case .pinyin(let s), .literal(let s): return s
            }
        }.joined()
    }

    // MARK: - 退格

    /// 处理退格逻辑。从 `rawSpans` 末尾片段逐字符回退；末尾片段为字面块时，
    /// 按字符删除字面块内容，删空后整块消失，回到原退格路径继续删除前一片段。
    private func handleBackspace() {
        // 如果在 Tab 聚焦模式，退格退出聚焦
        if focusIndex != nil {
            focusIndex = nil
            rebuildFromRawPinyin()
            return
        }

        if !rawSpans.isEmpty {
            let last = rawSpans.removeLast()
            if let trimmed = last.droppingLast() {
                rawSpans.append(trimmed)
            }
            if rawSpans.isEmpty {
                // 输入串全部删完，移除所有由 rawSpans 派生的项（可编辑拼音段与字面块），保留已确认 .text
                composingItems.removeAll { $0.isEditable || $0.isLiteral }
                candidates = []
            } else {
                rebuildFromRawPinyin()
            }
        } else if !composingItems.isEmpty {
            // 没有活跃输入，删除最后一个已确定的文字
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

        if !candidates.isEmpty {
            // 提交活跃候选（用户可能已通过 ←→、⌘⇧[]、⇧+digit 切换 activeCandidateIndex；
            // 未切换时该索引为 0，行为与提交首选一致）
            let safeIndex =
                (0..<candidates.count).contains(activeCandidateIndex) ? activeCandidateIndex : 0
            let active = candidates[safeIndex]
            if focusIndex != nil {
                // Tab 聚焦模式：确认聚焦段，可能自动提交
                return confirmFocusedSegment(with: active)
            } else {
                // 正常模式：用候选替换整个拼音串，然后提交全部
                finalizeAllPinyin(with: active)
                let result = joinedCommitText(composingItems)
                resetAll()
                return result
            }
        } else if !composingItems.isEmpty {
            // 无候选时（包括 Tab 模式全部确认后），提交缓冲区内容
            let result = joinedCommitText(composingItems)
            resetAll()
            return result
        }
        return nil
    }

    // MARK: - 数字选词

    /// 处理数字选词
    private func handleNumber(_ index: Int) -> String? {
        // 自定义短语续输模式：当 rawPinyin 中含有 0（作为短语名标识）且追加当前
        // 数字键后能够匹配到已注册短语时，将数字作为短语名的一部分（如 sz0 + 1
        // → sz01，用于输入带圈数字）；否则按常规选词逻辑处理。
        // 混输态（含字面块）下短语续输不参与，避免把数字续到字面块的拼音段后
        // 反而抹掉已聚合的字面块。
        if rawPinyin.contains("0") && !rawSpans.contains(where: { $0.isLiteral }) {
            // 短语名大小写敏感（xl0 与 XL0 是两个独立短语），不做 lowercase 归一
            let extended = rawPinyin + String(index)
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
        }

        // 整串方案与部分方案的判定依据为候选实际消耗的拼音段，与候选位置无关。
        // 部分方案的候选登记在 partialConsumedPinyin 中（包括 4b 注入的首词、首段补充候选等）；
        // 未登记者视为整串方案，覆盖全部 cleanPinyin。
        let candidateText = candidates[actualIndex]
        // 混输态首字面块方案：当 `rawSpans` 首个 chunk 为 `.literal` 时，pos 2 是
        // 字面块本身。选中时仅截除该字面块并以 `.text` 推进预编辑文本，余下 spans
        // 重建组词；与首拼音段路径对仗，让用户像逐段选拼音那样把字面块作为独立
        // 步骤推进。
        if mixedFirstLiteralCandidates.contains(candidateText) {
            confirmMixedFirstLiteralIntoComposingText(with: candidateText)
            return nil
        }
        // 混输态首拼音段方案：登记在 `mixedFirstSpanCandidates`，把首段 + 前置字面块
        // 确认进预编辑文本（marked text）继续组词，不直接写出到宿主文档。
        if mixedFirstSpanCandidates.contains(candidateText) {
            confirmMixedFirstSpanIntoComposingText(with: candidateText)
            return nil
        }
        if let consumed = partialConsumedPinyin[candidateText] {
            confirmFirstSegment(with: candidateText, consumedPinyin: consumed)
            return nil
        } else {
            finalizeAllPinyin(with: candidateText)
            let result = joinedCommitText(composingItems)
            resetAll()
            return result
        }
    }

    /// 混输态选中首拼音段备选：把首段译文确认进预编辑文本（`composingItems`），
    /// 继续基于剩余 spans 组词；不直接提交到宿主文档。与纯拼音模式选 pos 2+
    /// 走 `confirmFirstSegment` 的语义保持一致 —— 用户视角下都是先在 marked text
    /// 内累积已确认部分，待整体确认（空格 / 数字选 pos 1 / Enter）时再一并提交，
    /// 从而保证最终 commit 字符串能够按完整边界规则（含中↔拉空格）整体处理。
    ///
    /// 调用约束：本函数仅在候选派发命中 `mixedFirstSpanCandidates` 时进入，而该
    /// 集合仅在 `rawSpans.first == .pinyin` 时注册（参见 `rebuildMixedComposition`）。
    /// 因此进入时 `rawSpans.first` 必为 `.pinyin`，可直接 `removeFirst()`；
    /// 字面块前缀已由独立的 `confirmMixedFirstLiteralIntoComposingText` 路径处理。
    private func confirmMixedFirstSpanIntoComposingText(with text: String) {
        // 已确认前缀（前序 .text）保留；移除当前 rawSpans 派生的可编辑 / 字面块项
        let confirmedPrefix = composingItems.filter { !$0.isEditable && !$0.isLiteral }
        composingItems = confirmedPrefix
        composingItems.append(.text(text))

        rawSpans.removeFirst()
        focusIndex = nil

        if rawSpans.isEmpty {
            candidates = []
        } else {
            rebuildFromRawPinyin()
        }
    }

    /// 混输态选中首字面块：把字面块作为一个独立 chunk 推进预编辑文本
    /// （`composingItems`），余下 spans 重建组词；与 `confirmMixedFirstSpanIntoComposingText`
    /// 对仗。语义上让用户像选拼音候选那样把字面块作为离散步骤推进。
    ///
    /// 实现细节：以 `.text(literalContent)` 推入 composingItems，与前面已确认的
    /// `.text` 之间的中↔拉边界空格由 `joinedCommitText` / `needsSeparatorSpace`
    /// 在最终拼接时自动处理，无需在此手动注入。
    private func confirmMixedFirstLiteralIntoComposingText(with text: String) {
        guard let first = rawSpans.first, case .literal(let literal) = first,
            literal == text
        else { return }

        // 已确认前缀（前序 .text）保留；移除当前 rawSpans 派生的可编辑 / 字面块项
        let confirmedPrefix = composingItems.filter { !$0.isEditable && !$0.isLiteral }
        composingItems = confirmedPrefix
        composingItems.append(.text(literal))

        // 截除已确认的首字面块，余下 spans 重建
        rawSpans.removeFirst()
        focusIndex = nil

        if rawSpans.isEmpty {
            candidates = []
        } else {
            rebuildFromRawPinyin()
        }
    }

    // MARK: - 以词定字

    /// 处理以词定字
    private func handleBracket(pickLast: Bool) -> String? {
        guard activeCandidateIndex < candidates.count else { return nil }
        // 混输态下候选是整句合成（含字面块原文），以词定字语义对应「首/末拼音段
        // 取首/末字 + 陪同字面块」，独立于 active candidate，由专属路径处理。
        if rawSpans.contains(where: { $0.isLiteral }) {
            return handleMixedBracket(pickLast: pickLast)
        }
        let active = candidates[activeCandidateIndex]
        guard let char = pickCharacter(from: active, pickLast: pickLast) else { return nil }

        if focusIndex != nil {
            return confirmFocusedSegment(with: char)
        }

        // 普通模式：消耗激活候选所对应的音节（按汉字字数估算 = 音节数）。
        // 若消耗后仍有音节剩余 → compose 模式：选中字进缓冲区，剩余拼音继续匹配；
        // 否则 → 直接提交（候选覆盖了全部输入，没有可继续的部分）。
        let consumeCount = active.count
        let (allSyllables, remainder) = PinyinSplitter.splitPartial(rawPinyin)

        if remainder.isEmpty && consumeCount < allSyllables.count {
            let remainingPinyin = allSyllables[consumeCount...].joined()
            composingItems.append(.text(char))
            rawPinyin = remainingPinyin
            focusIndex = nil
            rebuildFromRawPinyin()
            return nil
        }

        // 直接提交：选中的字与已确认的 .text 项一并提交，未选中的部分丢弃。
        finalizeAllPinyin(with: char)
        let result = joinedCommitText(composingItems)
        resetAll()
        return result
    }

    /// 混输态以词定字：先把首个 `.pinyin` 段之前的所有前置字面块逐个确认为
    /// 已确认 `.text`（按原顺序追加到预编辑文本前缀），再对该首拼音段按 `[` / `]`
    /// 取首选的首字或末字，整段消耗后亦以 `.text` 追加。
    ///
    /// 字面块在混输输入中天然构成词边界，故每个拼音段都是独立的「词」单位 ——
    /// 不论 `[` 还是 `]` 都以「首拼音段」为对象，二者的差异仅在于从该段首选
    /// 汉字串里选首字还是末字。
    ///
    /// 提交语义：取字后若 `rawSpans` 不再含 `.pinyin` 段（空，或仅剩字面块），
    /// 则将预编辑文本与剩余字面块一并直接提交到宿主文档（中↔拉边界空格由
    /// `joinedCommitText` 统一处理），并重置全部状态；若仍含 `.pinyin` 段，则
    /// 保留 buffer 继续组词。
    private func handleMixedBracket(pickLast: Bool) -> String? {
        let store = (currentMode == .pinyin) ? zhStore : jaStore

        // 1. 定位首个 `.pinyin` 段；若已无拼音段（仅字面块），无可操作目标，原状返回
        guard
            let targetIdx = rawSpans.indices.first(where: { !rawSpans[$0].isLiteral }),
            case .pinyin(let raw) = rawSpans[targetIdx]
        else {
            return nil
        }

        // 2. 对目标段求首选并按 `[` / `]` 取首字 / 末字；候选缺失时原状返回，
        //    避免在已对前置字面块做修改前就因取字失败而留下半成品状态
        let cleaned = raw.lowercased().replacingOccurrences(of: "'", with: "")
        let normalized = Self.normalizePinyin(cleaned)
        let topCandidate: String?
        if let conv = store.flatMap({
            Conversion.compose(
                normalized, store: $0, pinnedChars: pinnedChars, pinnedWords: pinnedWords)
        }) {
            topCandidate = conv.text
        } else {
            topCandidate = (store?.candidates(for: normalized) ?? []).first
        }
        guard let topText = topCandidate,
            let char = pickCharacter(from: topText, pickLast: pickLast)
        else { return nil }

        // 3. 收纳已确认前缀（前序 .text），随后按顺序追加：前置字面块 → picked char
        var confirmedPrefix = composingItems.filter { !$0.isEditable && !$0.isLiteral }
        for span in rawSpans[..<targetIdx] {
            if case .literal(let s) = span {
                confirmedPrefix.append(.text(s))
            }
        }
        confirmedPrefix.append(.text(char))
        composingItems = confirmedPrefix

        // 4. 移除已确认的前置字面块与目标拼音段；后续 spans（中置字面块、后续拼音段）保留
        rawSpans.removeSubrange(...targetIdx)
        focusIndex = nil

        // 5. 若已无拼音段（rawSpans 为空或仅剩字面块），把预编辑文本与剩余字面块
        //    一并直接提交：将剩余字面块作为 `.literal` 项追加，由 `joinedCommitText`
        //    统一按中↔拉边界规则插入空格
        if !rawSpans.contains(where: { !$0.isLiteral }) {
            for span in rawSpans {
                if case .literal(let s) = span {
                    composingItems.append(.literal(s))
                }
            }
            let result = joinedCommitText(composingItems)
            resetAll()
            return result
        }

        rebuildFromRawPinyin()
        return nil
    }

    // MARK: - Tab 导航

    /// 处理 Tab 键：在可编辑段之间移动焦点。
    /// 混输态下字面块（`.literal`）不属于可编辑项，editable 序列天然只剩拼音段，
    /// 焦点自然在拼音段之间循环；边界规则与纯拼音模式一致。
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

    /// 在候选列表中循环移动激活候选（不提交）。
    /// 候选数 ≤ 1 时无效；移动到边界时绕回另一端。
    private func handleCycleActiveCandidate(backward: Bool) {
        guard candidates.count > 1 else { return }
        let n = candidates.count
        if backward {
            activeCandidateIndex = (activeCandidateIndex - 1 + n) % n
        } else {
            activeCandidateIndex = (activeCandidateIndex + 1) % n
        }
    }

    // MARK: - 全角标点

    /// 处理标点输入：
    /// - 缓冲区为空时，直接提交全角标点。
    /// - 缓冲区有候选时，确认活跃候选 + 提交全角标点。
    /// - 缓冲区有内容但无候选时，提交缓冲区原始内容 + 全角标点。
    private func handlePunctuation(_ char: Character) -> String? {
        let fullWidth = mapToFullWidth(char)

        if composingItems.isEmpty {
            return fullWidth
        } else {
            var result = ""
            if !candidates.isEmpty {
                // 确认活跃候选（用户可能已通过 ←→、⌘⇧[]、⇧+digit 切换 activeCandidateIndex；
                // 未切换时该索引为 0，行为与确认首选一致）
                let safeIndex =
                    (0..<candidates.count).contains(activeCandidateIndex) ? activeCandidateIndex : 0
                finalizeAllPinyin(with: candidates[safeIndex])
                result = joinedCommitText(composingItems)
            } else {
                result = joinedCommitText(composingItems)
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

    /// 根据 rawSpans 重建可编辑的 composingItems。
    /// - 纯拼音输入：与历史路径完全一致（基于 `rawPinyin` 切分 + 候选生成）。
    /// - 含字面块的混输输入：按片段顺序对每个拼音段单独 compose 得 chunks，
    ///   字面块作为 `.literal` 直接嵌入，候选合成为单条整句方案。
    private func rebuildFromRawPinyin() {
        // 保留前面已确定的 .text 项；移除所有 rawSpans 派生的项
        let confirmedPrefix = composingItems.filter { !$0.isEditable && !$0.isLiteral }
        composingItems = confirmedPrefix

        guard !rawSpans.isEmpty else {
            candidates = []
            return
        }

        // 混输路径：含任一字面块时，走简化的整句合成流程，
        // 不与首段补充候选 / 部分方案 / 固顶字等高级路径耦合。
        if rawSpans.contains(where: { $0.isLiteral }) {
            rebuildMixedComposition()
            return
        }

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
            Conversion.compose(
                cleanPinyin, store: $0, pinnedChars: pinnedChars, pinnedWords: pinnedWords)
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
            // Conversion 未覆盖的尾部（理论上不应发生，此处保留作为 fallback）
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

    /// 更新候选词：精确匹配 → Conversion 组词 → 首段补充候选 → 前缀 → 末段 fallback
    private func updateCandidatesWholeString(defaultSyllables: [String], remainder: String) {
        let _ucStart = CFAbsoluteTimeGetCurrent()
        let store = (currentMode == .pinyin) ? zhStore : jaStore

        // 0. 自定义短语：rawPinyin 完全匹配短语名时，短语候选置顶
        let cleanPinyin = Self.normalizePinyin(
            rawPinyin.lowercased().replacingOccurrences(of: "'", with: ""))
        // 短语名大小写敏感（xl0 与 XL0 是两个独立短语），phrase 查询不走拼音的
        // lowercase 归一链，沿用原始 rawPinyin 仅做 ü 规范化与撇号剥离
        let phraseKey = Self.normalizePinyin(
            rawPinyin.replacingOccurrences(of: "'", with: ""))
        let customResults = customPhrases?.phrases(for: phraseKey) ?? []

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

        // 3a. 多音节场景下应用固顶词，把 pinned words 提到候选列表前。
        //     单音节由后续 applyPinnedChars 负责单字提顶，避免在单音节路径上插入多字词。
        if currentMode == .pinyin && defaultSyllables.count >= 2 {
            result = applyPinnedWords(for: cleanPinyin, to: result)
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

        // 部分方案登记表：候选文本到该候选消耗的拼音段。未登记的候选视为整串方案。
        // 被选中时分别进入 `confirmFirstSegment`（部分方案）或 `finalizeAllPinyin`（整串方案）。
        var partial: [String: String] = [:]

        // 4b. 首词候选注入：长串输入（≥4 音节）时，独立查最长前缀词作为第二候选，
        //     与 Conversion 的最优切分解耦（完整词典下 Conversion 可能挑单字段）。
        //     该候选仅覆盖首部若干音节，登记为部分方案；选中后保留剩余拼音继续组词。
        if defaultSyllables.count >= 4,
            remainder.isEmpty || remainderIsBareInitial,
            !result.isEmpty,
            let firstWord = findLongestPrefixWord(syllables: defaultSyllables, store: store),
            firstWord.text != result.first
        {
            result.insert(firstWord.text, at: 1)
            partial[firstWord.text] = firstWord.pinyin
        }

        // 5. 首段补充候选：从 Conversion 结果或 PinyinSplitter 获取首段拼音，
        //    追加该拼音的其他候选，方便用户快速替换首词继续组词
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

            for text in filtered {
                partial[text] = firstPinyin
            }
            result.append(contentsOf: filtered)

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
                for text in singleFiltered {
                    partial[text] = firstFullSyllable
                }
                result.append(contentsOf: singleFiltered)
            }
        }

        // 6. 前缀匹配 fallback：精确匹配和 Conversion 都无结果时，用前缀匹配补充候选。
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

        // 8. Garbage 尾 fallback：用户输入了既非音节也非声母的无效尾段
        //    （典型是孤立韵母 u/i/v，如 wuwuu 末尾的 u），Conversion 与前缀匹配都跳过此类 case。
        //    用 syllables 部分组词，把每条候选 + remainder 原文拼成合成候选，
        //    使用户至少可选取「中文+残留字符」的提交，避免因候选空被 handleSpace
        //    回退为 commit 原始 ASCII 串。
        if result.isEmpty && !remainder.isEmpty && !remainderIsBareInitial
            && !defaultSyllables.isEmpty
        {
            let truncated = defaultSyllables.joined()
            var truncatedResult = store?.candidates(for: truncated) ?? []
            if truncatedResult.isEmpty && defaultSyllables.count > 1 {
                if let conv = unifiedCompose(truncated, store: store) {
                    truncatedResult = [conv.text]
                }
            }
            if currentMode == .pinyin {
                truncatedResult = applyPinnedChars(for: truncated, to: truncatedResult)
            }
            result = truncatedResult.prefix(9).map { $0 + remainder }
        }

        // 固顶字：单音节（含不完整前缀）时，将固顶字插入候选列表最前面
        if currentMode == .pinyin && defaultSyllables.count <= 1 {
            result = applyPinnedChars(for: cleanPinyin, to: result)
        }

        // 自定义短语置顶（去重）。短语本身覆盖整个 phraseKey，视作整串方案；
        // 与第 5、6 步同文本的部分方案登记发生冲突时，移除原登记。
        if !customResults.isEmpty {
            let customSet = Set(customResults)
            for text in customSet {
                partial.removeValue(forKey: text)
            }
            result = customResults + result.filter { !customSet.contains($0) }
        }

        candidates = result
        partialConsumedPinyin = partial

        let _ucElapsed = (CFAbsoluteTimeGetCurrent() - _ucStart) * 1000
        Profiler.record(
            "updateCandidates", elapsed: _ucElapsed, detail: "updateCandidates(\(rawPinyin))")
        if _ucElapsed >= Profiler.thresholdMs {
            Profiler.event(
                "updateCandidates(\(rawPinyin)): \(String(format: "%.1f", _ucElapsed))ms")
        }
    }

    /// 混输重建：按 rawSpans 顺序对各拼音段单独 compose，字面块原样嵌入。
    /// 候选区结构：pos 1 = 整句合成方案；pos 2+ 取决于 rawSpans 首个 chunk：
    /// - 首 chunk 为 `.pinyin`：pos 2+ = 首拼音段的备选（多字词 + 单字），
    ///   与纯拼音模式同构。备选登记于 `mixedFirstSpanCandidates`，选中时走
    ///   `confirmMixedFirstSpanIntoComposingText`。
    /// - 首 chunk 为 `.literal`：pos 2 = 字面块本身（仅一项，字面块没有备选）。
    ///   登记于 `mixedFirstLiteralCandidates`，选中时走
    ///   `confirmMixedFirstLiteralIntoComposingText` 把字面块作为离散步骤推进
    ///   预编辑文本，与拼音段路径对仗。
    /// 整句候选 pos 1 永远保留，作为「跳到底」的快捷选项。
    private func rebuildMixedComposition() {
        let store = (currentMode == .pinyin) ? zhStore : jaStore

        // 段级合成结果：每段对应展示串（pinyin chunks 切分原始字符）与提交文本（中文或字面块原文）。
        struct SpanRender {
            let items: [ComposingItem]
            let commitText: String
            let kind: Kind
            enum Kind { case pinyin, literal }
        }

        var renders: [SpanRender] = []
        for span in rawSpans {
            switch span {
            case .literal(let s):
                renders.append(
                    SpanRender(items: [.literal(s)], commitText: s, kind: .literal))
            case .pinyin(let raw):
                let cleaned = raw.lowercased().replacingOccurrences(of: "'", with: "")
                let normalized = Self.normalizePinyin(cleaned)
                let convResult = store.flatMap {
                    Conversion.compose(
                        normalized, store: $0, pinnedChars: pinnedChars, pinnedWords: pinnedWords)
                }

                var pinyinItems: [ComposingItem] = []
                if let conv = convResult, !conv.chunks.isEmpty {
                    var offset = raw.startIndex
                    for chunk in conv.chunks {
                        while offset < raw.endIndex && raw[offset] == "'" {
                            offset = raw.index(after: offset)
                        }
                        let end = raw.index(offset, offsetBy: chunk.count)
                        pinyinItems.append(.pinyin(String(raw[offset..<end])))
                        offset = end
                    }
                    if offset < raw.endIndex {
                        pinyinItems.append(.pinyin(String(raw[offset...])))
                    }
                } else {
                    // compose 失败 fallback：整段作为一个拼音项
                    pinyinItems.append(.pinyin(raw))
                }

                let commitText = convResult?.text ?? cleaned
                renders.append(
                    SpanRender(items: pinyinItems, commitText: commitText, kind: .pinyin))
            }
        }

        // 1. composingItems：按 SpanRender 顺序展开
        for render in renders {
            composingItems.append(contentsOf: render.items)
        }

        // 2. 整句候选：拼接各段 commit 文本，相邻段类型不同处补一个空格（中英边界）
        var sentence = ""
        for (idx, render) in renders.enumerated() {
            if idx > 0 {
                let prev = renders[idx - 1]
                if prev.kind != render.kind {
                    sentence += " "
                }
            }
            sentence += render.commitText
        }

        // 3. 首 chunk 备选：按首个 chunk 的类型分派为 pos 2+。
        //    - 首 chunk 为 .pinyin：生成多字词 + 单字备选，登记到 `mixedFirstSpanCandidates`。
        //    - 首 chunk 为 .literal：以字面块本身作为唯一备选，登记到 `mixedFirstLiteralCandidates`。
        //    与整句候选去重；纯字面块 buffer（仅一段 .literal）下整句 = 字面块，
        //    去重后 pos 2 自然合并入 pos 1，候选区只剩一条，避免视觉冗余。
        var firstChunkCandidates: [String] = []
        switch rawSpans.first {
        case .pinyin(let raw):
            firstChunkCandidates = generateFirstSpanCandidates(forRaw: raw, store: store)
        case .literal(let s):
            firstChunkCandidates = [s]
        case .none:
            break
        }

        var combined: [String] = sentence.isEmpty ? [] : [sentence]
        let existing = Set(combined)
        let firstChunkFiltered = firstChunkCandidates.filter { !existing.contains($0) }
        combined.append(contentsOf: firstChunkFiltered)

        candidates = combined
        switch rawSpans.first {
        case .pinyin:
            mixedFirstSpanCandidates = Set(firstChunkFiltered)
        case .literal:
            mixedFirstLiteralCandidates = Set(firstChunkFiltered)
        case .none:
            break
        }
    }

    /// 为单一拼音段（混输态首段）生成备选列表：精确匹配 + Conversion 整词 + 首音节单字。
    /// 精简版本，与 `updateCandidatesWholeString` 中的同构逻辑对齐，但不耦合 partial 登记、
    /// 用户词典、自定义短语、固顶字等纯拼音路径专属机制。
    private func generateFirstSpanCandidates(forRaw raw: String, store: DictionaryStore?)
        -> [String]
    {
        let cleaned = raw.lowercased().replacingOccurrences(of: "'", with: "")
        let normalized = Self.normalizePinyin(cleaned)
        guard !normalized.isEmpty else { return [] }

        var result: [String] = []
        var seen: Set<String> = []
        let push: (String) -> Void = { text in
            guard !seen.contains(text) else { return }
            seen.insert(text)
            result.append(text)
        }

        // 整串精确匹配
        for word in store?.candidates(for: normalized) ?? [] {
            push(word)
        }

        // Conversion 多音节整段
        let (syllables, remainder) = PinyinSplitter.splitPartial(normalized)
        if syllables.count > 1, remainder.isEmpty {
            if let conv = store.flatMap({
                Conversion.compose(
                    normalized, store: $0, pinnedChars: pinnedChars, pinnedWords: pinnedWords)
            }) {
                push(conv.text)
            }
        }

        // 首音节单字 fallback：多音节时把第一音节的字典候选追加，方便用户回退选首字
        if syllables.count > 1, remainder.isEmpty {
            let firstSyl = Self.normalizePinyin(syllables[0])
            if firstSyl != normalized {
                for word in store?.candidates(for: firstSyl) ?? [] {
                    push(word)
                }
            }
        }

        return result
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

    /// 将固顶词插入候选列表最前面，去除重复。
    /// 与 `applyPinnedChars` 平行；在多音节路径上把 pinnedWords 提顶。
    private func applyPinnedWords(for pinyin: String, to candidates: [String]) -> [String] {
        guard let pinned = pinnedWords?.pinnedWords(for: pinyin), !pinned.isEmpty else {
            return candidates
        }
        let pinnedSet = Set(pinned)
        return pinned + candidates.filter { !pinnedSet.contains($0) }
    }

    // MARK: - 确认与提交辅助

    /// 将整个输入串替换为一个确定的文本（正常模式下选词/以词定字）。
    /// 混输态下候选已是整句合成结果（含字面块原文），同样以单一 .text 替换所有派生项。
    private func finalizeAllPinyin(with text: String) {
        // 移除所有由 rawSpans 派生的项（可编辑拼音段与字面块）
        composingItems.removeAll { $0.isEditable || $0.isLiteral }
        composingItems.append(.text(text))
        rawSpans = []
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
            let result = joinedCommitText(composingItems)
            resetAll()
            return result
        } else {
            // 移动到下一个可编辑段
            focusIndex = editableIndices.first { $0 > idx } ?? editableIndices.first
            updateCandidatesForFocus()
            return nil
        }
    }

    /// 确认部分方案候选：将候选写入已确认文本，截除 rawPinyin 中对应的拼音段，剩余继续组词。
    /// 参数 `consumedPinyin` 取自 `partialConsumedPinyin` 中的登记值，与候选实际覆盖范围一一对应。
    private func confirmFirstSegment(with text: String, consumedPinyin: String) {
        guard !consumedPinyin.isEmpty else { return }

        let cleanRaw = rawPinyin.lowercased().replacingOccurrences(of: "'", with: "")
        let normalizedRaw = Self.normalizePinyin(cleanRaw)

        guard normalizedRaw.hasPrefix(consumedPinyin) else { return }

        let remainingNormalized = String(normalizedRaw.dropFirst(consumedPinyin.count))

        // 重建：confirmed text + 剩余拼音继续组词
        let confirmedPrefix = composingItems.filter { !$0.isEditable }
        composingItems = confirmedPrefix
        composingItems.append(.text(text))
        rawPinyin = remainingNormalized
        focusIndex = nil

        if rawPinyin.isEmpty {
            candidates = []
        } else {
            rebuildFromRawPinyin()
        }
    }

    /// 从 composingItems 中残存的可编辑项与字面块重建 rawSpans。
    /// 纯拼音路径（无字面块）：折叠为单一 `.pinyin` 段，与历史行为一致。
    /// 混输路径：按 composingItems 顺序拼装，保留字面块作为独立 `.literal` span，
    /// 避免 Tab 聚焦确认后字面块结构丢失。
    private func rebuildRawPinyinFromItems() {
        guard composingItems.contains(where: { $0.isLiteral }) else {
            rawPinyin = composingItems.compactMap { $0.sourcePinyin }.joined()
            return
        }
        var newSpans: [RawSpan] = []
        var pendingPinyin = ""
        for item in composingItems {
            switch item {
            case .literal(let s):
                if !pendingPinyin.isEmpty {
                    newSpans.append(.pinyin(pendingPinyin))
                    pendingPinyin = ""
                }
                newSpans.append(.literal(s))
            case .pinyin(let s):
                pendingPinyin += s
            case .provisional(let pinyin, _):
                pendingPinyin += pinyin
            case .text:
                // 已确认段不进 rawSpans；它出现在已 Tab 聚焦确认的位置时
                // 充当字面块前后的「断点」，需 flush pending 避免相邻拼音段意外合并
                if !pendingPinyin.isEmpty {
                    newSpans.append(.pinyin(pendingPinyin))
                    pendingPinyin = ""
                }
            }
        }
        if !pendingPinyin.isEmpty {
            newSpans.append(.pinyin(pendingPinyin))
        }
        rawSpans = newSpans
    }

    /// 获取用于 Enter 提交的原文（拼音原文 + 已确定文本 + 字面块原样）。
    /// 边界空格规则统一走 `ComposingItem.needsSeparatorSpace`，与候选区呈现及
    /// 整串提交字符串一致。
    private func rawContentForCommit() -> String {
        joinedCommitText(composingItems)
    }

    /// 把一组 composingItems 拼接为最终 commit 字符串。
    /// 边界空格依据 `ComposingItem.needsSeparatorSpace`：拼音 / 预览段与字面块
    /// 相邻时必补；已确认 .text 与字面块、或两个 .text 相邻时按内容首末字符判定
    /// 中↔拉边界；其余不补。
    private func joinedCommitText(_ items: [ComposingItem]) -> String {
        var result = ""
        var previous: ComposingItem? = nil
        for item in items {
            let text: String
            switch item {
            case .text(let s), .pinyin(let s), .literal(let s): text = s
            case .provisional(let pinyin, _): text = pinyin
            }
            guard !text.isEmpty else { continue }
            if let prev = previous,
                ComposingItem.needsSeparatorSpace(before: prev, after: item)
            {
                result += " "
            }
            result += text
            previous = item
        }
        return result
    }

    /// 重置所有状态：包括清空缓冲区和自动回退临时模式
    private func resetAll() {
        composingItems = []
        candidates = []
        rawSpans = []
        focusIndex = nil
        if currentMode == .transient { currentMode = .pinyin }
    }

    /// 以词定字辅助：截取首尾字符
    private func pickCharacter(from candidate: String, pickLast: Bool) -> String? {
        guard !candidate.isEmpty else { return nil }
        return pickLast ? String(candidate.last!) : String(candidate.first!)
    }

    /// 在词典中查找首词候选：自最长前缀（音节数为 syllables.count - 1）起逐级缩短，
    /// 返回首个字数 ≥2 的命中。仅用于长串输入的首词注入。
    /// 返回值附带对应的拼音段（已规范化），供调用方登记为部分方案候选的消耗范围。
    private func findLongestPrefixWord(syllables: [String], store: DictionaryStore?)
        -> (text: String, pinyin: String)?
    {
        guard syllables.count >= 2 else { return nil }
        for prefixLen in stride(from: syllables.count - 1, through: 2, by: -1) {
            let prefix = Self.normalizePinyin(syllables[0..<prefixLen].joined())
            guard let cands = store?.candidates(for: prefix) else { continue }
            if let multi = cands.first(where: { $0.count >= 2 }) {
                return (multi, prefix)
            }
        }
        return nil
    }

    /// 将拼音中 u 作为 ü 的替代写法规范化为 v（仅限 l/n 声母后的 ue→ve）
    public static func normalizePinyin(_ pinyin: String) -> String {
        var result = pinyin
        result = result.replacingOccurrences(of: "lue", with: "lve")
        result = result.replacingOccurrences(of: "nue", with: "nve")
        return result
    }

    // MARK: - Conversion 包装

    /// 实例方法包装：调 Conversion.compose 并加 profiling。
    /// engine 内部主路径，外部调用请用 Conversion.compose。
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
        return Conversion.compose(
            input, store: store, pinnedChars: pinnedChars, pinnedWords: pinnedWords)
    }

    // MARK: - Pin / Unpin 候选（IMK 集成接口）

    /// 把第 N 个候选 pin 到当前拼音的用户层队首。
    /// - Returns: 是否成功执行；以下情形返回 false 且不修改状态：
    ///   - 当前模式不是中文（仅中文拼音支持 pin）
    ///   - 缓冲区为空、含已确认文本段、或处于 Tab 聚焦状态
    ///   - 候选索引越界
    /// 单字候选 → 走 PinnedCharStore；多字候选 → 走 PinnedWordStore。
    /// 写入后立即重算候选，让 IMK 获取新的列表（pinned 项会置顶）。
    @discardableResult
    public func pinCandidate(atIndex index: Int) -> Bool {
        guard let pinyin = pinnableContext(forIndex: index) else { return false }
        let candidate = candidates[index]

        if candidate.count == 1 {
            pinnedChars?.pin(candidate, forPinyin: pinyin)
        } else {
            pinnedWords?.pin(candidate, forPinyin: pinyin)
        }
        rebuildFromRawPinyin()
        return true
    }

    /// 把第 N 个候选设为 active（不提交）。配合 `[` `]` 在任意候选上取首/末字。
    /// 索引越界返回 false，调用方可据此进入 fallback 路径（例如让 ⇧<num> 归入标点）。
    @discardableResult
    public func setActiveCandidate(atIndex index: Int) -> Bool {
        guard index >= 0 && index < candidates.count else { return false }
        activeCandidateIndex = index
        return true
    }

    /// 把第 N 个候选从用户层移除（不影响 sys 层）。
    /// 守卫与索引规则同 `pinCandidate`；候选不在用户层时 store 内部静默跳过。
    @discardableResult
    public func unpinCandidate(atIndex index: Int) -> Bool {
        guard let pinyin = pinnableContext(forIndex: index) else { return false }
        let candidate = candidates[index]

        if candidate.count == 1 {
            pinnedChars?.unpinUser(candidate, forPinyin: pinyin)
        } else {
            pinnedWords?.unpinUser(candidate, forPinyin: pinyin)
        }
        rebuildFromRawPinyin()
        return true
    }

    /// 校验 pin/unpin 的前置条件并返回用作 pinyin key 的规范化字符串。
    /// 仅在「拼音模式 + 缓冲区无已确认文本 + Tab 未聚焦 + 索引合法」时返回非 nil。
    /// 多音节会被自动切分成多个 .pinyin 段，所以不限制段数；只要求所有段都是
    /// 未确认的拼音输入或字面块（没有 .text 前缀），且至少存在一个拼音段。
    ///
    /// 混输态（rawSpans 含字面块）下的 pin 语义：
    /// - 整句候选（pos 1）：合成结果含字面块原文，与单一拼音键无对应关系，拒绝；
    /// - 字面块候选（命中 `mixedFirstLiteralCandidates`）：字面块本身没有 pinyin，拒绝；
    /// - 首拼音段备选（命中 `mixedFirstSpanCandidates`）：取首拼音段规范化 pinyin 作 key，
    ///   与纯拼音模式 pin 首段补充候选的语义一致。
    private func pinnableContext(forIndex index: Int) -> String? {
        guard currentMode == .pinyin else { return nil }
        guard !composingItems.isEmpty else { return nil }
        // 已存在 .text 前缀（部分确认状态）时不允许 pin；字面块属于 rawSpans 派生项，允许通过
        guard composingItems.allSatisfy({ $0.isEditable || $0.isLiteral }) else { return nil }
        guard focusIndex == nil else { return nil }
        guard index >= 0 && index < candidates.count else { return nil }

        // 混输态：仅允许 pin 命中首拼音段备选的候选，pin key 取首拼音段的规范化 pinyin
        if rawSpans.contains(where: { $0.isLiteral }) {
            let candidate = candidates[index]
            guard mixedFirstSpanCandidates.contains(candidate) else { return nil }
            guard case .pinyin(let firstRaw) = rawSpans.first else { return nil }
            let cleanFirst = Self.normalizePinyin(
                firstRaw.lowercased().replacingOccurrences(of: "'", with: ""))
            return cleanFirst.isEmpty ? nil : cleanFirst
        }

        let cleanPinyin = Self.normalizePinyin(
            rawPinyin.lowercased().replacingOccurrences(of: "'", with: ""))
        guard !cleanPinyin.isEmpty else { return nil }
        return cleanPinyin
    }

    // MARK: - 兼容性接口

    /// 兼容旧版调用接口
    public func getCandidates(for pinyin: String) -> [String] {
        let store = (currentMode == .pinyin) ? zhStore : jaStore
        return store?.candidates(for: pinyin.lowercased()) ?? []
    }
}
