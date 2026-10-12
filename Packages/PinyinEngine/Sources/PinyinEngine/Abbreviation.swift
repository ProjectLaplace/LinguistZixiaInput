import Foundation

/// 与一串简拼单元匹配的词条：词、完整拼音、词频，以及按词条字数切出的音节。
public struct AbbreviationEntry: Equatable {
    public let word: String
    /// 词条自身的完整拼音（如 `rengongzhineng`），而非键入的字母
    public let pinyin: String
    public let frequency: Int
    /// 完整拼音按词条字数切出的音节（如 `["ren", "gong", "zhi", "neng"]`）
    public let syllables: [String]
}

/// 简拼候选行：一对起始单元的范围查询结果。拼音以字节保存，匹配时才切分，
/// 使取行的开销与行数成正比，而切分只发生在实际参与比较的行上。
struct AbbreviationRow {
    let pinyin: [UInt8]
    let word: String
    let frequency: Int
    /// 词条字数，即音节数
    let syllableCount: Int
}

/// 简拼：只键入每个音节的首字母（或 zh/ch/sh），匹配各音节依次以这些字母开头的多字词。
///
/// 规则（参见 Conversion.md「简拼段」）：
/// - 简拼字母为全部单字母声母加上 `y`、`w`。`y`、`w` 只在简拼匹配中视为首字母，
///   不属于 `PinyinSplitter.validInitials`。
/// - 键入的字母按双字母声母优先切为单元：`zh`/`ch`/`sh` 为一个单元，其余每个字母一个单元。
/// - 单元匹配以它开头的音节：`z` 匹配 `zi` 与 `zhi`，`zh` 只匹配 `zhi` 等以 zh 开头的音节。
/// - 一个词匹配一串单元，当且仅当词的音节数等于单元数，且各音节依次被对应单元匹配。
///
/// 查询方式：同一对起始单元的候选行由 `DictionaryStore.abbreviationRows` 以一次范围查询
/// 取得并缓存（按词频降序），更长的简拼串在缓存的行中按词频顺序逐行匹配，不枚举音节组合。
public enum Abbreviation {

    /// 简拼字母：单字母声母加上 y、w
    static let letters: Set<Character> = Set("bpmfdtnlgkhjqxrzcsyw")

    /// 双字母声母
    private static let digraphInitials: Set<String> = ["zh", "ch", "sh"]

    /// 简拼匹配的最大音节数，即词条的最大字数
    static let maxSyllables = 8

    /// 合法音节的全部前缀（含音节本身），用于判断一个字母能否接续前面的字母组成音节
    static let syllablePrefixes: Set<String> = {
        var prefixes = Set<String>()
        for syllable in PinyinSplitter.validSyllables {
            for length in 1...syllable.count {
                prefixes.insert(String(syllable.prefix(length)))
            }
        }
        return prefixes
    }()

    /// 从 `start` 起把连续的简拼字母切为单元，至多 `maxSyllables` 个；遇到非简拼字母即停止。
    /// 例：`rgzn` → `["r", "g", "z", "n"]`，`zhn` → `["zh", "n"]`。
    static func units(in chars: [Character], from start: Int) -> [String] {
        var units: [String] = []
        var pos = start
        while pos < chars.count, units.count < maxSyllables, letters.contains(chars[pos]) {
            if pos + 1 < chars.count {
                let pair = String(chars[pos...(pos + 1)])
                if digraphInitials.contains(pair) {
                    units.append(pair)
                    pos += 2
                    continue
                }
            }
            units.append(String(chars[pos]))
            pos += 1
        }
        return units
    }

    /// 叹词音节（嗯、呣、哼）。多字词条中间出现它们的切分（`xian` → `xia` + `n`）几乎都是误切，
    /// 简拼切分不使用它们。
    private static let interjectionSyllables: Set<String> = ["n", "m", "ng", "hm", "hng"]

    /// 把词条拼音切为恰好 `count` 个合法音节的全部方式（不含叹词音节）。
    ///
    /// 词条字数确定音节数，借此消解 `xian` 与 `xi'an` 一类歧义。词库拼音不带隔音符号，
    /// `fangan` 这类串本身有两种读法（方案、反感），故返回全部切分；`validSyllables` 是组合
    /// 生成的超集，可能多出 `zhin` + `eng` 一类切分，它们多以元音开头，不会与键入的简拼匹配。
    static func splits(of pinyin: String, into count: Int) -> [[String]] {
        var results: [[String]] = []
        search(Array(pinyin.utf8), count: count, units: []) { results.append($0) }
        return results
    }

    /// 把拼音切为与单元依次匹配的音节（音节数等于单元数），返回第一种匹配的切分；无则 nil。
    static func matchingSyllables(of pinyin: [UInt8], units: [[UInt8]]) -> [String]? {
        var match: [String]?
        search(pinyin, count: units.count, units: units) {
            match = $0
            return false
        }
        return match
    }

    /// 合法音节（不含叹词音节）的字母 trie，以数组表示：`next[state * 26 + letter]` 为下一状态
    /// （-1 表示没有音节以此延伸），`terminal[state]` 表示到此为一个完整音节。切分时沿 trie
    /// 逐字母前进，前缀不再能延伸为音节即停止，不必为每个长度构造字符串或查集合。
    private static let syllableTrie: (next: [Int32], terminal: [Bool]) = {
        var next = [Int32](repeating: -1, count: 26)
        var terminal = [false]
        for syllable in PinyinSplitter.validSyllables
        where !interjectionSyllables.contains(syllable) {
            var state = 0
            for byte in syllable.utf8 {
                guard byte >= 97, byte <= 122 else { break }
                let slot = state * 26 + Int(byte - 97)
                if next[slot] < 0 {
                    next[slot] = Int32(terminal.count)
                    terminal.append(false)
                    next += [Int32](repeating: -1, count: 26)
                }
                state = Int(next[slot])
            }
            terminal[state] = true
        }
        return (next, terminal)
    }()

    /// 在字节层面沿音节 trie 搜索把 `pinyin` 切为 `count` 个音节的方式，只为找到的切分构造字符串。
    /// 前 `units.count` 个音节须依次以对应单元开头，不满足的分支在中途剪去。
    /// `found` 返回 false 时停止搜索。
    private static func search(
        _ bytes: [UInt8], count: Int, units: [[UInt8]], found: ([String]) -> Bool
    ) {
        let n = bytes.count
        let maxLength = PinyinSplitter.maxSyllableLength
        guard count > 0, n >= count, n <= count * maxLength else { return }

        let (next, terminal) = syllableTrie
        var cuts: [Int] = [0]
        var stopped = false

        func step(from pos: Int) {
            let index = cuts.count - 1
            let remaining = count - index
            let left = n - pos
            if remaining == 0 {
                if left == 0 {
                    let syllables = (1..<cuts.count).map {
                        String(decoding: bytes[cuts[$0 - 1]..<cuts[$0]], as: UTF8.self)
                    }
                    stopped = !found(syllables)
                }
                return
            }
            guard left >= remaining, left <= remaining * maxLength else { return }
            if index < units.count {
                let unit = units[index]
                guard left >= unit.count else { return }
                for offset in 0..<unit.count where bytes[pos + offset] != unit[offset] {
                    return
                }
            }

            var state = 0
            for end in (pos + 1)...min(n, pos + maxLength) {
                let byte = bytes[end - 1]
                guard byte >= 97, byte <= 122 else { return }
                state = Int(next[state * 26 + Int(byte - 97)])
                guard state >= 0 else { return }
                if terminal[state] {
                    cuts.append(end)
                    step(from: end)
                    cuts.removeLast()
                    if stopped { return }
                }
            }
        }

        step(from: 0)
    }

    private static func search(
        _ bytes: [UInt8], count: Int, units: [[UInt8]], found: ([String]) -> Void
    ) {
        search(bytes, count: count, units: units) { (syllables: [String]) -> Bool in
            found(syllables)
            return true
        }
    }

    /// 以「首单元的各音节 + 第二单元」为前缀的范围查询前缀，覆盖首音节以首单元开头、
    /// 次音节以第二单元开头的全部词条。
    ///
    /// 首音节与第二单元相连仍可能是某个音节的前缀时（`sa` + `n` = `san`），该前缀下绝大多数
    /// 条目属于更长的首音节，故改按第二单元的各音节展开（`sana`、`sanai`……），减少扫描行数。
    /// 叹词音节不参与展开：`n` 作为次音节会使 `za` + `n` 退化为整个 `zan` 前缀。
    /// 互相包含的前缀只保留最短者。
    static func rangePrefixes(firstUnit: String, secondUnit: String) -> [String] {
        func syllables(startingWith unit: String) -> [String] {
            PinyinSplitter.syllables(withPrefix: unit).filter {
                !interjectionSyllables.contains($0)
            }
        }

        var prefixes: [String] = []
        for first in syllables(startingWith: firstUnit) {
            if syllablePrefixes.contains(first + secondUnit) {
                prefixes += syllables(startingWith: secondUnit).map { first + $0 }
            } else {
                prefixes.append(first + secondUnit)
            }
        }

        var shortest: [String] = []
        for prefix in Set(prefixes).sorted() {
            if let last = shortest.last, prefix.hasPrefix(last) { continue }
            shortest.append(prefix)
        }
        return shortest
    }
}
