import Foundation

/// DP 路径诊断结果：一条切分路径的完整评分明细。
public struct DPPathResult {
    /// 逐词拆分：每个词及其频率
    public let segments: [(word: String, pinyin: String, frequency: Int)]
    /// 组合文本（所有 word 拼接）
    public let text: String
    /// 多字词平均 log(freq)
    public let avgMultiCharScore: Double
    /// 多字词覆盖率（被多字词覆盖的音节数 / 总音节数）
    public let coverage: Double
    /// compositeScore = avgMulti + 4 * coverage
    public let compositeScore: Double
    /// 总词数
    public let wordCount: Int
    /// 总 log(freq) 之和
    public let totalScore: Double
}

/// DP 诊断工具：对拼音串执行 DP 切分并返回最优路径的评分明细，
/// 或按指定切分查词库并计算评分。
public enum DPDiagnostics {

    /// 对原始拼音串执行 DP，返回最优路径的诊断结果。
    public static func evaluateDP(_ input: String, store: DictionaryStore) -> DPPathResult? {
        let normalized = normalizePinyin(input)
        let chars = Array(normalized)
        let n = chars.count
        guard n > 0 else { return nil }

        func compositeScore(_ s: DPState) -> Double {
            let avg =
                s.multiCharCount > 0
                ? s.multiCharScore / Double(s.multiCharCount) : -1
            let cov =
                s.sylCount > 0
                ? Double(s.multiCharSylCount) / Double(s.sylCount) : 0
            return avg + 4.0 * cov
        }

        func isBetter(_ a: DPState, than b: DPState) -> Bool {
            let aScore = compositeScore(a)
            let bScore = compositeScore(b)
            if aScore != bScore { return aScore > bScore }
            if a.wordCount != b.wordCount { return a.wordCount < b.wordCount }
            return a.totalScore > b.totalScore
        }

        var dp: [DPState?] = Array(repeating: nil, count: n + 1)
        dp[n] = DPState(
            segments: [], syllables: [], multiCharScore: 0, multiCharCount: 0,
            multiCharSylCount: 0, totalScore: 0, wordCount: 0, sylCount: 0)

        for pos in stride(from: n - 1, through: 0, by: -1) {
            enumeratePhrases(chars: chars, from: pos, store: store) {
                word, frequency, syllables, endPos in
                guard let rest = dp[endPos] else { return }

                let wordScore = log(Double(max(frequency, 1)))
                let isMultiChar = word.count >= 2 && frequency >= 10000
                let multiCharScore = (isMultiChar ? wordScore : 0) + rest.multiCharScore
                let multiCharCount = (isMultiChar ? 1 : 0) + rest.multiCharCount
                let trueSylCount = word.count
                let multiCharSylCount = (isMultiChar ? trueSylCount : 0) + rest.multiCharSylCount
                let totalScore = wordScore + rest.totalScore
                let wordCountContribution = (!isMultiChar && word.count >= 2) ? word.count : 1
                let wordCount = wordCountContribution + rest.wordCount
                let totalSyls = trueSylCount + rest.sylCount

                let pinyinStr = syllables.joined()
                let candidate = DPState(
                    segments: [(word, pinyinStr, frequency)] + rest.segments,
                    syllables: syllables + rest.syllables,
                    multiCharScore: multiCharScore,
                    multiCharCount: multiCharCount,
                    multiCharSylCount: multiCharSylCount,
                    totalScore: totalScore,
                    wordCount: wordCount,
                    sylCount: totalSyls)

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
        return makeResult(best)
    }

    /// 按指定切分（如 ["jingque", "biaoyi"]）查词库，返回该路径的评分。
    public static func evaluateSplit(
        _ syllableGroups: [String], store: DictionaryStore
    ) -> DPPathResult? {
        var segments: [(word: String, pinyin: String, frequency: Int)] = []
        var multiCharScore: Double = 0
        var multiCharCount = 0
        var multiCharSylCount = 0
        var totalScore: Double = 0
        var wordCount = 0
        var sylCount = 0

        for group in syllableGroups {
            let normalized = normalizePinyin(group)
            guard let top = store.topCandidate(for: normalized) else {
                // 无匹配，按单字逐一查找
                let singleResults = evaluateSingleChars(normalized, store: store)
                if singleResults.isEmpty { return nil }
                for sr in singleResults {
                    segments.append(sr)
                    let ws = log(Double(max(sr.frequency, 1)))
                    totalScore += ws
                    wordCount += 1
                    sylCount += 1
                }
                continue
            }

            let frequency = top.frequency
            let word = top.word
            let wordScore = log(Double(max(frequency, 1)))
            let isMultiChar = word.count >= 2 && frequency >= 10000

            segments.append((word, normalized, frequency))
            multiCharScore += isMultiChar ? wordScore : 0
            multiCharCount += isMultiChar ? 1 : 0
            let trueSylCount = word.count
            multiCharSylCount += isMultiChar ? trueSylCount : 0
            totalScore += wordScore
            let wcc = (!isMultiChar && word.count >= 2) ? word.count : 1
            wordCount += wcc
            sylCount += trueSylCount
        }

        let avg = multiCharCount > 0 ? multiCharScore / Double(multiCharCount) : -1
        let cov = sylCount > 0 ? Double(multiCharSylCount) / Double(sylCount) : 0
        let composite = avg + 4.0 * cov

        return DPPathResult(
            segments: segments,
            text: segments.map { $0.word }.joined(),
            avgMultiCharScore: avg,
            coverage: cov,
            compositeScore: composite,
            wordCount: wordCount,
            totalScore: totalScore)
    }

    // MARK: - Private

    private static func normalizePinyin(_ pinyin: String) -> String {
        var result = pinyin
        result = result.replacingOccurrences(of: "lue", with: "lve")
        result = result.replacingOccurrences(of: "nue", with: "nve")
        return result
    }

    /// 将无法整体匹配的拼音串按音节逐一查单字。
    private static func evaluateSingleChars(
        _ pinyin: String, store: DictionaryStore
    ) -> [(word: String, pinyin: String, frequency: Int)] {
        guard let syllables = PinyinSplitter.split(pinyin) else { return [] }
        var results: [(word: String, pinyin: String, frequency: Int)] = []
        for syl in syllables {
            if let top = store.topCandidate(for: syl) {
                results.append((top.word, syl, top.frequency))
            } else {
                results.append(("?", syl, 0))
            }
        }
        return results
    }

    private static func enumeratePhrases(
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
                let normalized = normalizePinyin(syllable)
                guard
                    PinyinSplitter.validSyllables.contains(normalized)
                        || PinyinSplitter.validSyllables.contains(syllable)
                else { continue }

                let newPinyin = accPinyin + normalized
                let newSyllables = accSyllables + [syllable]
                let newPos = curPos + sylLen

                if let top = store.topCandidate(for: newPinyin) {
                    callback(top.word, top.frequency, newSyllables, newPos)
                }

                dfs(newPos, newPinyin, newSyllables)
            }
        }

        dfs(startPos, "", [])
    }

    private struct DPState {
        var segments: [(word: String, pinyin: String, frequency: Int)]
        var syllables: [String]
        var multiCharScore: Double
        var multiCharCount: Int
        var multiCharSylCount: Int
        var totalScore: Double
        var wordCount: Int
        var sylCount: Int
    }

    private static func makeResult(_ state: DPState) -> DPPathResult {
        let avg =
            state.multiCharCount > 0
            ? state.multiCharScore / Double(state.multiCharCount) : -1
        let cov =
            state.sylCount > 0
            ? Double(state.multiCharSylCount) / Double(state.sylCount) : 0
        let composite = avg + 4.0 * cov

        return DPPathResult(
            segments: state.segments,
            text: state.segments.map { $0.word }.joined(),
            avgMultiCharScore: avg,
            coverage: cov,
            compositeScore: composite,
            wordCount: state.wordCount,
            totalScore: state.totalScore)
    }
}
