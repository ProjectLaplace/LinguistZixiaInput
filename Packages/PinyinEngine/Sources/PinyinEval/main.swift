import Foundation
import PinyinEngine

// MARK: - ANSI Colors

enum Color {
    static let green = "\u{1b}[32m"
    static let orange = "\u{1b}[33m"
    static let red = "\u{1b}[31m"
    static let dim = "\u{1b}[2m"
    static let reset = "\u{1b}[0m"
    static let bold = "\u{1b}[1m"
}

// MARK: - Case Parsing

struct EvalCase {
    let rawPinyin: String  // 去掉 | 的原始拼音
    let expectedSplit: [String]  // 按 | 切分的音节组
    let expectedOutput: String  // col2: 预期输出（绿色标准）
    let reasonableOutput: String?  // col3: 合理输出（橙色标准，可选）
    let lineNumber: Int
    let rawLine: String
}

func parseCaseFile(_ path: String) -> [EvalCase] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("\(Color.red)Error: cannot read file \(path)\(Color.reset)\n", stderr)
        exit(1)
    }

    var cases: [EvalCase] = []
    for (lineNum, line) in content.components(separatedBy: .newlines).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            fputs(
                "\(Color.orange)Warning: line \(lineNum + 1) skipped (need at least 2 columns)\(Color.reset)\n",
                stderr)
            continue
        }

        let pinyinWithBars = parts[0]
        let expectedOutput = parts[1]
        let reasonableOutput = parts.count >= 3 ? parts[2] : nil

        let splitGroups = pinyinWithBars.components(separatedBy: "|")
        let rawPinyin = splitGroups.joined()

        cases.append(
            EvalCase(
                rawPinyin: rawPinyin,
                expectedSplit: splitGroups,
                expectedOutput: expectedOutput,
                reasonableOutput: reasonableOutput,
                lineNumber: lineNum + 1,
                rawLine: trimmed))
    }
    return cases
}

// MARK: - Formatting

func formatPath(_ result: DPPathResult) -> String {
    let segStrs = result.segments.map { seg in
        "\(seg.word)(\(seg.pinyin) f=\(seg.frequency))"
    }
    return segStrs.joined(separator: " + ")
}

func formatScore(_ result: DPPathResult) -> String {
    String(
        format: "avgMulti=%.1f cov=%.2f composite=%.2f words=%d total=%.1f",
        result.avgMultiCharScore, result.coverage, result.compositeScore,
        result.wordCount, result.totalScore)
}

// MARK: - Split Evaluation

/// 按指定切分（如 ["jingque", "biaoyi"]）查词库，返回该路径的评分。
func evaluateSplit(
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
        let normalized = PinyinEngine.normalizePinyin(group)
        guard let top = store.topCandidate(for: normalized) else {
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

func evaluateSingleChars(
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

// MARK: - Evaluation

func evaluate(_ evalCase: EvalCase, store: DictionaryStore, pinnedChars: PinnedCharStore?) -> Bool {
    let dpResult = PinyinEngine.compose(evalCase.rawPinyin, store: store, pinnedChars: pinnedChars)
    let dpText = dpResult?.text ?? ""

    // 判定
    if dpText == evalCase.expectedOutput {
        // 绿色：完美匹配
        print("\(Color.green)●\(Color.reset) \(evalCase.rawPinyin) → \(dpText)")
        return true
    } else if let reasonable = evalCase.reasonableOutput, dpText == reasonable {
        // 橙色：合理匹配
        print(
            "\(Color.orange)●\(Color.reset) \(evalCase.rawPinyin) → \(dpText) \(Color.dim)(expected: \(evalCase.expectedOutput))\(Color.reset)"
        )
        return true
    } else {
        // 红色：不匹配，展开明细
        print(
            "\(Color.red)●\(Color.reset) \(evalCase.rawPinyin) → \(dpText) \(Color.dim)(expected: \(evalCase.expectedOutput))\(Color.reset)"
        )
        printDetail(evalCase: evalCase, dpResult: dpResult, store: store)
        return false
    }
}

func printDetail(evalCase: EvalCase, dpResult: DPPathResult?, store: DictionaryStore) {
    // DP 实际路径
    if let dp = dpResult {
        print("  \(Color.red)actual:\(Color.reset)   \(formatPath(dp))")
        print("           \(formatScore(dp))")
    } else {
        print("  \(Color.red)actual:\(Color.reset)   (no DP result)")
    }

    // 按指定切分查词库的评分
    let splitLabel = evalCase.expectedSplit.joined(separator: "|")
    if let splitResult = evaluateSplit(evalCase.expectedSplit, store: store) {
        print("  \(Color.green)split:\(Color.reset)    \(splitLabel) → \(formatPath(splitResult))")
        print("           \(formatScore(splitResult))")
    } else {
        print("  \(Color.green)split:\(Color.reset)    \(splitLabel) → (no dictionary match)")
    }
}

// MARK: - Main

/// 从当前工作目录或可执行文件位置往上查找 .git 目录，返回项目根路径。
func findProjectRoot() -> String? {
    // 优先从 CWD 往上找
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            return dir.path
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    // 从可执行文件位置往上找
    dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            return dir.path
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return nil
}

func findDictionary() -> String {
    if let envPath = ProcessInfo.processInfo.environment["PINYIN_DICT_PATH"] {
        return envPath
    }

    if let root = findProjectRoot() {
        let path = "\(root)/Packages/PinyinEngine/Sources/PinyinEngine/Resources/zh_dict.db"
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }

    fputs(
        "\(Color.red)Error: cannot find zh_dict.db. Set PINYIN_DICT_PATH or run from project root.\(Color.reset)\n",
        stderr)
    exit(1)
}

func findPinnedChars() -> PinnedCharStore? {
    if let envPath = ProcessInfo.processInfo.environment["PINYIN_PINNED_PATH"] {
        return PinnedCharStore(path: envPath)
    }

    if let root = findProjectRoot() {
        let path = "\(root)/fixtures/pinned_chars.toml"
        if FileManager.default.fileExists(atPath: path) {
            return PinnedCharStore(path: path)
        }
    }

    return nil
}

let args = CommandLine.arguments

if args.count < 2 {
    fputs("Usage: pinyin-eval <cases-file> [--dict <path>]\n", stderr)
    fputs("       pinyin-eval \"jingque|biaoyi 精确表意 精确表姨\"\n", stderr)
    fputs("       pinyin-eval -q <pinyin>\n", stderr)
    exit(1)
}

// 解析参数
var dictPath: String?
var inputArg: String?
var queryMode = false
var i = 1
while i < args.count {
    if args[i] == "--dict" && i + 1 < args.count {
        dictPath = args[i + 1]
        i += 2
    } else if args[i] == "-q" || args[i] == "--query" {
        queryMode = true
        i += 1
    } else if inputArg == nil {
        inputArg = args[i]
        i += 1
    } else {
        i += 1
    }
}

guard let input = inputArg else {
    fputs("Usage: pinyin-eval <cases-file> [--dict <path>]\n", stderr)
    exit(1)
}

let resolvedDictPath = dictPath ?? findDictionary()
guard let store = DictionaryStore(path: resolvedDictPath) else {
    fputs(
        "\(Color.red)Error: cannot open dictionary at \(resolvedDictPath)\(Color.reset)\n", stderr)
    exit(1)
}

let pinnedChars = findPinnedChars()

// -q 模式：查询词库
if queryMode {
    let pinyin = input.lowercased()
    let exact = store.candidatesWithFrequency(for: pinyin)
    let prefix = store.candidatesWithPrefix(pinyin, limit: 20)

    if !exact.isEmpty {
        print("\(Color.bold)exact:\(Color.reset)  ", terminator: "")
        print(
            exact.map { "\($0.word)(\(Color.dim)f=\($0.frequency)\(Color.reset))" }.joined(
                separator: " "))
    } else {
        print("\(Color.dim)exact:  (no match)\(Color.reset)")
    }

    if !prefix.isEmpty {
        // 前缀结果去掉精确匹配中已出现的
        let exactWords = Set(exact.map { $0.word })
        let prefixOnly = prefix.filter { !exactWords.contains($0) }
        if !prefixOnly.isEmpty {
            print("\(Color.bold)prefix:\(Color.reset) ", terminator: "")
            print(prefixOnly.joined(separator: " "))
        }
    }

    // DP 结果
    if let dpResult = PinyinEngine.compose(pinyin, store: store, pinnedChars: pinnedChars) {
        print(
            "\(Color.bold)dp:\(Color.reset)     \(dpResult.text)  \(Color.dim)\(formatPath(dpResult))\(Color.reset)"
        )
    }

    exit(0)
}

// 判断输入是文件还是单条 case
var cases: [EvalCase]
if FileManager.default.fileExists(atPath: input) {
    cases = parseCaseFile(input)
} else {
    // 单条 case，解析为内联格式
    let parts = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    guard parts.count >= 2 else {
        fputs("Error: inline case needs at least 2 columns: <pinyin> <expected>\n", stderr)
        exit(1)
    }
    let splitGroups = parts[0].components(separatedBy: "|")
    cases = [
        EvalCase(
            rawPinyin: splitGroups.joined(),
            expectedSplit: splitGroups,
            expectedOutput: parts[1],
            reasonableOutput: parts.count >= 3 ? parts[2] : nil,
            lineNumber: 1,
            rawLine: input)
    ]
}

// 执行
var passed = 0
var failed = 0
for c in cases {
    if evaluate(c, store: store, pinnedChars: pinnedChars) {
        passed += 1
    } else {
        failed += 1
    }
}

// 汇总
if cases.count > 1 {
    print()
    let summary =
        failed > 0
        ? "\(Color.red)\(failed) failed\(Color.reset), \(passed) passed"
        : "\(Color.green)All \(passed) passed\(Color.reset)"
    print("\(summary) (\(cases.count) cases)")
}

exit(failed > 0 ? 1 : 0)
