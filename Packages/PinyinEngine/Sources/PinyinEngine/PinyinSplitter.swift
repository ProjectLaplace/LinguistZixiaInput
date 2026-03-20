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
        for initial in ["n", "l"] {
            for final_ in ["v", "ve"] {
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

            // Can't split fully — find the longest prefix that can be split
            // and treat the rest as remainder
            for prefixLen in stride(from: chars.count - 1, through: 0, by: -1) {
                if prefixLen == 0 {
                    // Nothing can be split from this segment
                    let remainder = hardSegments[index...].map(String.init).joined(separator: "'")
                    return (allSyllables, remainder)
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
                    return (allSyllables, remainingParts.joined(separator: "'"))
                }
            }

            // Should not reach here, but safety fallback
            let remainder = hardSegments[index...].map(String.init).joined(separator: "'")
            return (allSyllables, remainder)
        }

        return (allSyllables, "")
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
