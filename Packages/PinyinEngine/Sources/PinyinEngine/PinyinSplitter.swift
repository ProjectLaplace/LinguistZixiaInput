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

            // Can't split fully; find the longest prefix that can be split
            // and treat the rest as remainder
            for prefixLen in stride(from: chars.count - 1, through: 0, by: -1) {
                if prefixLen == 0 {
                    // Nothing can be split from this segment
                    var rawRemainder = hardSegments[index...].map(String.init).joined(
                        separator: "'")
                    // 尝试从 remainder 中拆出声母
                    let (initials, leftover) = splitInitials(rawRemainder)
                    allSyllables.append(contentsOf: initials)
                    return (allSyllables, leftover)
                }
                if let syllables = splitSegment(Array(chars[0..<prefixLen])) {
                    allSyllables.append(contentsOf: syllables)
                    let segRemainder = String(chars[prefixLen...])
                    // Append remaining hard segments too
                    var remainingParts = [segRemainder]
                    if index + 1 < hardSegments.count {
                        remainingParts.append(
                            contentsOf: hardSegments[(index + 1)...].map(String.init))
                    }
                    let rawRemainder = remainingParts.joined(separator: "'")
                    // 尝试从 remainder 中拆出声母
                    let (initials, leftover) = splitInitials(rawRemainder)
                    allSyllables.append(contentsOf: initials)
                    return (allSyllables, leftover)
                }
            }

            // Should not reach here, but safety fallback
            let rawRemainder = hardSegments[index...].map(String.init).joined(separator: "'")
            let (initials, leftover) = splitInitials(rawRemainder)
            allSyllables.append(contentsOf: initials)
            return (allSyllables, leftover)
        }

        return (allSyllables, "")
    }

    /// 将 remainder 中的连续声母拆为独立音节，保留最后一个声母作为 remainder
    /// （用户可能还在继续输入该音节的韵母）。
    /// 例如 "cd" → (["c"], "d"), "chzb" → (["ch", "z"], "b"), "f" → ([], "f")
    /// 贪心匹配最长声母（zh/ch/sh 优先于 z/c/s）。
    private static func splitInitials(_ input: String) -> (initials: [String], remainder: String) {
        let chars = Array(input)
        var pos = 0
        var initials: [String] = []

        while pos < chars.count {
            // 尝试双字母声母
            if pos + 1 < chars.count {
                let two = String(chars[pos...(pos + 1)])
                if validInitials.contains(two) {
                    initials.append(two)
                    pos += 2
                    continue
                }
            }
            // 尝试单字母声母
            let one = String(chars[pos])
            if validInitials.contains(one) {
                initials.append(one)
                pos += 1
            } else {
                // 非声母字符，停止
                break
            }
        }

        // 最后一个声母退回 remainder（用户可能还在输入韵母）
        let remainder: String
        if let last = initials.popLast() {
            let leftover = pos < chars.count ? String(chars[pos...]) : ""
            remainder = last + leftover
        } else {
            remainder = pos < chars.count ? String(chars[pos...]) : input
        }
        return (initials, remainder)
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
