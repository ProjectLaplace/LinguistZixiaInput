import Foundation

/// Pinyin syllable splitter using greedy longest match.
///
/// Splits a continuous pinyin string into individual syllables.
/// Supports apostrophe (`'`) as a hard boundary for disambiguation (e.g. `xi'an`).
public enum PinyinSplitter {

    /// All valid pinyin syllables, built from initials + finals combinations.
    /// Used for greedy longest-match splitting.
    static let validSyllables: Set<String> = {
        // Zero-initial syllables (standalone finals)
        let zeroInitial = [
            "a", "o", "e", "ai", "ei", "ao", "ou",
            "an", "en", "ang", "eng", "er",
        ]

        // Syllables starting with y-
        let ySyllables = [
            "ya", "yo", "ye", "yao", "you",
            "yan", "yin", "yang", "ying",
            "yong", "yu", "yue", "yuan", "yun",
            "yi",
        ]

        // Syllables starting with w-
        let wSyllables = [
            "wa", "wo", "wai", "wei",
            "wan", "wen", "wang", "weng",
            "wu",
        ]

        let initials = [
            "b", "p", "m", "f",
            "d", "t", "n", "l",
            "g", "k", "h",
            "j", "q", "x",
            "zh", "ch", "sh", "r",
            "z", "c", "s",
        ]

        let finals = [
            "a", "o", "e", "i", "u",
            "ai", "ei", "ao", "ou",
            "an", "en", "ang", "eng",
            "ia", "ie", "iao", "iu", "iou",
            "ian", "in", "iang", "ing", "iong",
            "ua", "uo", "uai", "ui", "uei",
            "uan", "un", "uang", "ong",
            "ue", "uan", "un",
        ]

        // ju/qu/xu series (v-finals mapped to u after j/q/x)
        let jqxFinals = ["u", "ue", "uan", "un"]

        var result = Set<String>()

        // Add zero-initial, y-, w- syllables
        for s in zeroInitial + ySyllables + wSyllables {
            result.insert(s)
        }

        // Add initial + final combinations
        for initial in initials {
            for final_ in finals {
                let syllable = initial + final_
                result.insert(syllable)
            }
        }

        // Ensure j/q/x + v-final coverage
        for initial in ["j", "q", "x"] {
            for final_ in jqxFinals {
                result.insert(initial + final_)
            }
        }

        // v-finals for n/l (nv, lv, nve, lve)
        // Also accept u-spelling (lue, nue) as ü alternatives
        for initial in ["n", "l"] {
            for final_ in ["v", "ve", "ue"] {
                result.insert(initial + final_)
            }
        }

        // Special syllables not covered by the above combinatorics
        let specials = [
            "ng", "hm", "hng", "m", "n",
            "bia", "biang", "dia", "lo",
            "cen", "den", "nen", "gen", "hen",
            "cei", "sei", "dei",
            "me", "ne", "le", "ge", "he",
            "re", "se", "ze", "ce",
            "zhe", "che", "she",
            "ri",
            "zi", "ci", "si",
            "zhi", "chi", "shi",
            "zu", "cu", "su",
            "zhu", "chu", "shu", "ru",
        ]
        for s in specials {
            result.insert(s)
        }

        return result
    }()

    /// 合法声母集合（含双字母声母 zh/ch/sh）
    static let validInitials: Set<String> = [
        "b", "p", "m", "f",
        "d", "t", "n", "l",
        "g", "k", "h",
        "j", "q", "x",
        "zh", "ch", "sh", "r",
        "z", "c", "s",
    ]

    /// 声母→合法音节列表映射，用于 Conversion 中裸声母展开。
    /// 每个音节归属于其最长匹配声母（如 chi 归 ch，ci 归 c）。
    static let syllablesForInitial: [String: [String]] = {
        var map: [String: [String]] = [:]
        for initial in validInitials {
            map[initial] = []
        }
        for syllable in validSyllables {
            // 找最长匹配声母
            var best: String?
            for initial in validInitials where syllable.hasPrefix(initial) {
                if best == nil || initial.count > best!.count {
                    best = initial
                }
            }
            if let initial = best, syllable != initial {
                map[initial]?.append(syllable)
            }
        }
        for key in map.keys {
            map[key]?.sort()
        }
        return map
    }()

    /// Maximum length of any valid pinyin syllable.
    static let maxSyllableLength: Int = {
        validSyllables.map(\.count).max() ?? 6
    }()

    /// Split a raw pinyin string into syllables.
    ///
    /// Uses longest-match-first with backtracking: tries the longest valid syllable
    /// at each position, but backtracks if the remainder cannot be fully split.
    ///
    /// - Parameter input: Raw pinyin string, may contain `'` as hard separator
    /// - Returns: Array of syllable strings, or nil if the input cannot be fully split
    public static func split(_ input: String) -> [String]? {
        guard !input.isEmpty else { return [] }

        let lowered = input.lowercased()

        // Step 1: Split on apostrophe (hard boundaries)
        let hardSegments = lowered.split(separator: "'", omittingEmptySubsequences: true)

        var result: [String] = []

        // Step 2: Longest match with backtracking within each hard segment
        for segment in hardSegments {
            guard let syllables = splitSegment(Array(segment)) else {
                return nil
            }
            result.append(contentsOf: syllables)
        }

        return result
    }

    /// Split a raw pinyin string that may be incomplete (user still typing).
    ///
    /// Splits as many complete syllables as possible from the beginning.
    /// Returns the successfully split syllables and any trailing remainder.
    ///
    /// - Parameter input: Raw pinyin string, may contain `'` as hard separator
    /// - Returns: Tuple of (complete syllables, unsplittable remainder)
    public static func splitPartial(_ input: String) -> (syllables: [String], remainder: String) {
        guard !input.isEmpty else { return ([], "") }

        let lowered = input.lowercased()

        // Split on apostrophe first
        let hardSegments = lowered.split(separator: "'", omittingEmptySubsequences: true)

        var allSyllables: [String] = []

        for (index, segment) in hardSegments.enumerated() {
            let chars = Array(segment)

            // Try to split the full segment
            if let syllables = splitSegment(chars) {
                allSyllables.append(contentsOf: syllables)
                continue
            }

            // 本段无法整体切分：连同其后的硬分段一起交给 splitTail 逐步推进
            let rawRemainder = hardSegments[index...].map(String.init).joined(separator: "'")
            let (tailSyllables, leftover) = splitTail(Array(rawRemainder))
            allSyllables.append(contentsOf: tailSyllables)
            return (allSyllables, leftover)
        }

        return (allSyllables, "")
    }

    /// 逐步切分无法整体切分的尾部。
    ///
    /// 依次尝试三条路径：整体切分 → 最长可切分前缀 → 剥离一个裸声母后递归。
    /// 剥离裸声母后恢复常规切分，使位于中间的声母缩写不再阻断其后完整音节的识别
    /// （如 "dshi" → (["d", "shi"], "")）。
    /// 位于串尾的声母按最长匹配保留为 remainder，因为用户可能仍在输入该音节的韵母
    /// （如 "cd" → (["c"], "d")，"sh" → ([], "sh")）。
    private static func splitTail(_ chars: [Character]) -> (syllables: [String], remainder: String)
    {
        // 撇号在此处仅充当分隔符，本身不参与切分
        if chars.first == "'" {
            return splitTail(Array(chars.dropFirst()))
        }
        guard !chars.isEmpty else { return ([], "") }

        if let syllables = splitSegment(chars) {
            return (syllables, "")
        }

        // 最长可切分前缀：切下之后对剩余部分递归
        for prefixLen in stride(from: chars.count - 1, through: 1, by: -1) {
            if let syllables = splitSegment(Array(chars[0..<prefixLen])) {
                let (rest, remainder) = splitTail(Array(chars[prefixLen...]))
                return (syllables + rest, remainder)
            }
        }

        // 裸声母：最长匹配（zh/ch/sh 优先于 z/c/s）
        for length in [2, 1] where length <= chars.count {
            let initial = String(chars[0..<length])
            guard validInitials.contains(initial) else { continue }
            // 恰好耗尽输入的声母位于串尾，退回 remainder 等待韵母
            if length == chars.count {
                return ([], initial)
            }
            let (rest, remainder) = splitTail(Array(chars[length...]))
            return ([initial] + rest, remainder)
        }

        return ([], String(chars))
    }

    /// Split a single segment (no apostrophes) into syllables using DP.
    /// Finds the split with the fewest syllables (preferring longer matches overall).
    private static func splitSegment(_ chars: [Character]) -> [String]? {
        let n = chars.count
        guard n > 0 else { return [] }

        // dp[i] stores the optimal (fewest syllables) split for chars[i..<n]
        var dp: [[String]?] = Array(repeating: nil, count: n + 1)
        dp[n] = []  // base case: empty suffix

        for pos in stride(from: n - 1, through: 0, by: -1) {
            let remaining = n - pos
            let maxLen = min(remaining, maxSyllableLength)

            var bestSplit: [String]? = nil

            for len in 1...maxLen {
                let candidate = String(chars[pos..<(pos + len)])
                if validSyllables.contains(candidate), let rest = dp[pos + len] {
                    let split = [candidate] + rest
                    if bestSplit == nil || split.count < bestSplit!.count {
                        bestSplit = split
                    }
                }
            }

            dp[pos] = bestSplit
        }

        return dp[0]
    }
}
