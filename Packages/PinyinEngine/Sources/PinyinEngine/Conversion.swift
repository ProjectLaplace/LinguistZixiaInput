import Foundation

/// Conversion 路径诊断结果：一条切分路径的完整评分明细。
///
/// 术语参见 Conversion.md。chunk = DFS 切分单元（合法音节或裸声母），
/// segment = 路径段（对应一次词库命中），word = ≥2 字且 freq ≥ `ScoringConfig.wordNoiseFloor` 的词库条目。
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
    /// 最终 pathScore（完整公式见 `ScoringConfig`）
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

/// Conversion 评分参数。控制 pathScore 公式与词/噪声判定阈值。
///
/// pathScore 公式：
///   pathScore = wordFreqAvg
///             + coverageWeight       · wordCoverage
///             + syllableGreedyWeight · avgSyllableLength
///             + wordLengthWeight     · avgWordLength
///             - singleCharPenalty    · singleCharCount
///
/// - `coverageWeight`：被多字词覆盖的字数占比权重。
/// - `wordNoiseFloor`：多字词（`count ≥ 2`）频率低于此值视为词典噪声，不计入
///   `wordFreqSum`/`wordCount`/`wordCharCount`。只有频率在 noise floor 之上的多字词
///   才贡献 coverage。阈值下的多字词段落入反作弊路径（segmentCount 按 word.count 计）。
/// - `syllableGreedyWeight`：音节贪心权重，奖励平均音节长度更长的切分
///   （例 zi+xia 均长 2.5 > zi+xi+a 均长 1.67）。
/// - `wordLengthWeight`：多字词长度权重，奖励使用更长词典条目的路径
///   （例 [输入法] 平均 3 字 > [输入]+[法] 平均 1.5 字）。单字不计入平均。
/// - `singleCharPenalty`：单字惩罚，对每段单字扣分，避免单字高频（如「发」
///   f=3.9M）虚高的 log(freq) 压过多字词选择。
public struct ScoringConfig {
    public var coverageWeight: Double
    public var wordNoiseFloor: Int
    public var syllableGreedyWeight: Double
    public var wordLengthWeight: Double
    public var singleCharPenalty: Double

    public init(
        coverageWeight: Double = 3.0,
        wordNoiseFloor: Int = 5000,
        syllableGreedyWeight: Double = 1.0,
        wordLengthWeight: Double = 1.0,
        singleCharPenalty: Double = 2.0
    ) {
        self.coverageWeight = coverageWeight
        self.wordNoiseFloor = wordNoiseFloor
        self.syllableGreedyWeight = syllableGreedyWeight
        self.wordLengthWeight = wordLengthWeight
        self.singleCharPenalty = singleCharPenalty
    }

    public static let `default` = ScoringConfig()
}

/// Conversion 模块：把罗马化拼音/罗马字通过切分 + 词库 + 评分转换为最优汉字路径。
///
/// 详细设计与术语定义参见 Conversion.md。
public enum Conversion {

    // MARK: - 公开入口

    /// 主入口：对原始拼音串执行 Conversion 搜索，返回最优路径。
    ///
    /// 例如 "jianchayixiane":
    ///   两阶段法: split→["jian","cha","yi","xian","e"] → 检查仪限额
    ///   Conversion:  检查(580k)+一下(501k)+呢(高频) >> 检查仪(4k)+限额(138k)
    public static func compose(
        _ input: String, store: DictionaryStore, pinnedChars: PinnedCharStore? = nil,
        config: ScoringConfig = .default
    ) -> ConversionResult? {
        let chars = Array(input)
        let n = chars.count
        guard n > 0 else { return nil }

        // DP: dp[pos] = 从 pos 开始到末尾的最优状态
        var dp: [State?] = Array(repeating: nil, count: n + 1)
        dp[n] = State.empty(config: config)

        // 从右往左填 DP
        for pos in stride(from: n - 1, through: 0, by: -1) {
            enumeratePhrases(chars: chars, from: pos, store: store, pinnedChars: pinnedChars) {
                word, frequency, chunks, endPos in
                guard let rest = dp[endPos] else { return }

                // 把新段 prepend 到 rest 上（从右往左 DP 的自然顺序）
                let candidate = State.segment(
                    word: word, frequency: frequency, chunks: chunks, config: config
                ).concat(rest)

                if let existing = dp[pos] {
                    if candidate.isBetter(than: existing) {
                        dp[pos] = candidate
                    }
                } else {
                    dp[pos] = candidate
                }
            }
        }

        return dp[0]?.toResult()
    }

    /// 按指定音节组切分查词库评分，用于对比 compose 结果（eval 工具用）。
    ///
    /// 每个 group 先作为完整拼音查词库（命中则作为一段加入）。未命中则 fallback：
    /// 用 PinyinSplitter 切分为音节，每音节作为单字段加入。任一 group 无法匹配返回 nil。
    ///
    /// 例：`["jingque", "biaoyi"]` → 精确(jingque) + 表姨(biaoyi)（后者若词库无则按 biao+yi 单字）
    public static func scoreSplit(
        _ groups: [String], store: DictionaryStore, config: ScoringConfig = .default
    ) -> ConversionResult? {
        var acc = State.empty(config: config)

        for group in groups {
            let normalized = PinyinEngine.normalizePinyin(group)

            if let top = store.topCandidate(for: normalized) {
                acc = acc.concat(
                    .segment(
                        word: top.word, frequency: top.frequency, chunks: [normalized],
                        config: config))
                continue
            }

            // Fallback：切分为音节后逐字查词库
            guard let syllables = PinyinSplitter.split(normalized) else {
                return nil
            }
            var matched = false
            for syl in syllables {
                if let top = store.topCandidate(for: syl) {
                    acc = acc.concat(
                        .segment(
                            word: top.word, frequency: top.frequency, chunks: [syl],
                            config: config))
                    matched = true
                }
            }
            if !matched { return nil }
        }

        return acc.toResult()
    }

    // MARK: - 内部状态

    /// Conversion 累积状态：对应 ConversionResult 的可变版本，支持组合。
    /// 通过 `segment(word:frequency:chunks:config:)` 构造单段状态，通过 `concat(_:)` 拼接。
    fileprivate struct State {
        var segments: [(word: String, pinyin: String, frequency: Int)]
        var chunks: [String]
        var wordFreqSum: Double
        var wordCount: Int
        var wordCharCount: Int
        /// 被任何多字词（word.count ≥ 2）覆盖的字数，不受 `wordNoiseFloor` 限制——
        /// 噪声以下的多字词也计入。用作 pathScore/segs/chunks 全打平时的 tie-break：
        /// 多字词典命中是更强的用户意图信号，哪怕 freq 没过 noise floor。
        var softWordCharCount: Int
        var totalFreqSum: Double
        var segmentCount: Int
        var charCount: Int
        var chunkCount: Int
        /// 所有 chunks 的字母数总和。与 chunkCount 结合得到平均音节长度：
        /// `avgSyllableLength = syllableCharCount / chunkCount`。对同一输入而言
        /// syllableCharCount 在 DP 每个 cell 内恒等于剩余输入长度，因此 avgSyllableLength
        /// 的变化完全来自 chunkCount——等价于把"chunk 数"的偏好从次键提升到主键。
        var syllableCharCount: Int
        /// 单字段数（word.count == 1）。pathScore 减 `singleCharPenalty × singleCharCount`：
        /// 单字 log(freq) 通常远高于多字词（「的」「发」等高频单字），会虚高 pathScore；
        /// 用结构性代价压制这种虚高。
        var singleCharCount: Int
        var config: ScoringConfig

        static func empty(config: ScoringConfig) -> State {
            State(
                segments: [], chunks: [],
                wordFreqSum: 0, wordCount: 0, wordCharCount: 0, softWordCharCount: 0,
                totalFreqSum: 0, segmentCount: 0, charCount: 0, chunkCount: 0,
                syllableCharCount: 0, singleCharCount: 0,
                config: config)
        }

        /// 构造单段状态：一个 (word, freq, chunks) 对应的独立累积。
        static func segment(
            word: String, frequency: Int, chunks: [String], config: ScoringConfig
        ) -> State {
            let segmentFreq = log(Double(max(frequency, 1)))
            // 低频多字词（freq < wordNoiseFloor）视为词典噪声，不计入词段评分和覆盖率。
            // 例如 rime-ice 里那些 freq 只有数百的边缘多字条目，不应提升 wordCoverage。
            let isWord = word.count >= 2 && frequency >= config.wordNoiseFloor
            let wordChars = word.count
            // 反作弊：低频多字词按字数计入段数，避免垃圾词通过"减少段数"获益（段数是次键）
            let segmentContribution = (!isWord && word.count >= 2) ? word.count : 1
            let sylChars = chunks.reduce(0) { $0 + $1.count }

            return State(
                segments: [(word, chunks.joined(), frequency)],
                chunks: chunks,
                wordFreqSum: isWord ? segmentFreq : 0,
                wordCount: isWord ? 1 : 0,
                wordCharCount: isWord ? wordChars : 0,
                softWordCharCount: wordChars >= 2 ? wordChars : 0,
                totalFreqSum: segmentFreq,
                segmentCount: segmentContribution,
                charCount: wordChars,
                chunkCount: chunks.count,
                syllableCharCount: sylChars,
                singleCharCount: wordChars == 1 ? 1 : 0,
                config: config)
        }

        /// 把 self（前段）与 other（后段）拼接：segments 与 chunks 按顺序连接，
        /// 其它标量字段按加法累积。config 继承 self（DP 过程中两侧 config 相同）。
        func concat(_ other: State) -> State {
            State(
                segments: segments + other.segments,
                chunks: chunks + other.chunks,
                wordFreqSum: wordFreqSum + other.wordFreqSum,
                wordCount: wordCount + other.wordCount,
                wordCharCount: wordCharCount + other.wordCharCount,
                softWordCharCount: softWordCharCount + other.softWordCharCount,
                totalFreqSum: totalFreqSum + other.totalFreqSum,
                segmentCount: segmentCount + other.segmentCount,
                charCount: charCount + other.charCount,
                chunkCount: chunkCount + other.chunkCount,
                syllableCharCount: syllableCharCount + other.syllableCharCount,
                singleCharCount: singleCharCount + other.singleCharCount,
                config: config)
        }

        /// 主键评分。公式（参见 ScoringConfig 注释）：
        ///   pathScore = wordFreqAvg
        ///             + coverageWeight       · wordCoverage
        ///             + syllableGreedyWeight · avgSyllableLength
        ///             + wordLengthWeight     · avgWordLength
        ///             - singleCharPenalty    · singleCharCount
        var pathScore: Double {
            let wordFreqAvg = wordCount > 0 ? wordFreqSum / Double(wordCount) : -1
            let wordCoverage = charCount > 0 ? Double(wordCharCount) / Double(charCount) : 0
            let avgSyllableLength =
                chunkCount > 0 ? Double(syllableCharCount) / Double(chunkCount) : 0
            let avgWordLength =
                wordCount > 0 ? Double(wordCharCount) / Double(wordCount) : 0
            return wordFreqAvg
                + config.coverageWeight * wordCoverage
                + config.syllableGreedyWeight * avgSyllableLength
                + config.wordLengthWeight * avgWordLength
                - config.singleCharPenalty * Double(singleCharCount)
        }

        /// 路径比较顺序（参见 Conversion.md "比较顺序"）：
        /// 主键：pathScore 越大越好
        /// 次键：segmentCount 越小越好（避免 jiao 被拆成 ji+a+o）
        /// 三键：chunkCount 越小越好（与 avgSyllableLength 方向一致，已基本被 pathScore
        ///     吸收，保留作保险次键）
        /// 四键：softWordCharCount 越大越好（多字词典命中更能反映用户意图，
        ///     哪怕 freq 低于 wordNoiseFloor。救「心流+状态」vs「新+流+状态」这类平局。）
        /// 末键：totalFreqSum 越大越好（历史保留；在加入 softWordCharCount 后很少再起作用）
        ///
        /// pathScore 公式见 ScoringConfig。默认值是保守起点，待 eval_sweep 扫参后定。
        func isBetter(than other: State) -> Bool {
            let aScore = pathScore
            let bScore = other.pathScore
            if aScore != bScore { return aScore > bScore }
            if segmentCount != other.segmentCount { return segmentCount < other.segmentCount }
            if chunkCount != other.chunkCount { return chunkCount < other.chunkCount }
            if softWordCharCount != other.softWordCharCount {
                return softWordCharCount > other.softWordCharCount
            }
            return totalFreqSum > other.totalFreqSum
        }

        /// 构造公开结果。
        func toResult() -> ConversionResult {
            let wordFreqAvg = wordCount > 0 ? wordFreqSum / Double(wordCount) : -1
            let wordCoverage = charCount > 0 ? Double(wordCharCount) / Double(charCount) : 0
            return ConversionResult(
                segments: segments,
                chunks: chunks,
                text: segments.map { $0.word }.joined(),
                wordFreqAvg: wordFreqAvg,
                wordCoverage: wordCoverage,
                pathScore: pathScore,
                segmentCount: segmentCount,
                totalFreqSum: totalFreqSum)
        }
    }

    // MARK: - DFS 枚举

    /// 枚举从 pos 开始的所有合法短语：用 DFS 尝试连续音节组合并查词库。
    /// 每找到一个词库匹配就回调 (word, frequency, chunks, endPos)。
    /// chunks 是 DFS 切分单元序列（合法音节或裸声母），与输入字符一一对应。
    /// 支持裸声母展开：当位置上的字符是合法声母但不构成完整音节时，
    /// 展开为该声母的所有合法音节，查词库取 top 单字参与评分。
    fileprivate static func enumeratePhrases(
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
                let normalized = PinyinEngine.normalizePinyin(syllable)
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
}
