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

func formatPath(_ result: ConversionResult) -> String {
    let segStrs = result.segments.map { seg in
        "\(seg.word)(\(seg.pinyin) f=\(seg.frequency))"
    }
    return segStrs.joined(separator: " + ")
}

func formatScore(_ result: ConversionResult) -> String {
    String(
        format: "wordFreqAvg=%.1f wordCov=%.2f pathScore=%.2f segs=%d totalFreqSum=%.1f",
        result.wordFreqAvg, result.wordCoverage, result.pathScore,
        result.segmentCount, result.totalFreqSum)
}

// MARK: - Split Evaluation
// 按指定切分查词库评分使用 Conversion.scoreSplit（PinyinEngine 模块）。
// eval 工具不再维护独立的评分累加实现。

// MARK: - JSON Output

/// 把 ConversionResult 序列化为可喂给 JSONSerialization 的字典；nil → NSNull。
func convResultToDict(_ r: ConversionResult?) -> Any {
    guard let r = r else { return NSNull() }
    let segs: [[String: Any]] = r.segments.map { seg in
        ["word": seg.word, "pinyin": seg.pinyin, "frequency": seg.frequency]
    }
    return [
        "text": r.text,
        "segments": segs,
        "chunks": r.chunks,
        "wordFreqAvg": r.wordFreqAvg,
        "wordCoverage": r.wordCoverage,
        "pathScore": r.pathScore,
        "segmentCount": r.segmentCount,
        "totalFreqSum": r.totalFreqSum,
    ]
}

func printCaseJSON(
    evalCase: EvalCase, actual: ConversionResult?, split: ConversionResult?, status: String,
    config: ScoringConfig
) {
    let dict: [String: Any] = [
        "pinyin": evalCase.rawPinyin,
        "expectedSplit": evalCase.expectedSplit,
        "expected": evalCase.expectedOutput,
        "reasonable": evalCase.reasonableOutput as Any? ?? NSNull(),
        "line": evalCase.lineNumber,
        "status": status,
        "actual": convResultToDict(actual),
        "split": convResultToDict(split),
        "config": [
            "coverageWeight": config.coverageWeight,
            "wordNoiseFloor": config.wordNoiseFloor,
            "syllableGreedyWeight": config.syllableGreedyWeight,
            "wordLengthWeight": config.wordLengthWeight,
            "singleCharPenalty": config.singleCharPenalty,
        ],
    ]
    guard
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
        let str = String(data: data, encoding: .utf8)
    else { return }
    print(str)
}

// MARK: - Evaluation

func evaluate(
    _ evalCase: EvalCase, store: DictionaryStore, pinnedChars: PinnedCharStore?,
    config: ScoringConfig, jsonMode: Bool
) -> Bool {
    let convResult = Conversion.compose(
        evalCase.rawPinyin, store: store, pinnedChars: pinnedChars, config: config)
    let splitResult = Conversion.scoreSplit(evalCase.expectedSplit, store: store, config: config)
    let actualText = convResult?.text ?? ""

    // 判定
    let status: String
    let passed: Bool
    if actualText == evalCase.expectedOutput {
        status = "pass"
        passed = true
    } else if let reasonable = evalCase.reasonableOutput, actualText == reasonable {
        status = "reasonable"
        passed = true
    } else {
        status = "fail"
        passed = false
    }

    if jsonMode {
        printCaseJSON(
            evalCase: evalCase, actual: convResult, split: splitResult, status: status,
            config: config)
        return passed
    }

    switch status {
    case "pass":
        print("\(Color.green)●\(Color.reset) \(evalCase.rawPinyin) → \(actualText)")
    case "reasonable":
        print(
            "\(Color.orange)●\(Color.reset) \(evalCase.rawPinyin) → \(actualText) \(Color.dim)(expected: \(evalCase.expectedOutput))\(Color.reset)"
        )
    default:
        print(
            "\(Color.red)●\(Color.reset) \(evalCase.rawPinyin) → \(actualText) \(Color.dim)(expected: \(evalCase.expectedOutput))\(Color.reset)"
        )
        printDetail(evalCase: evalCase, convResult: convResult, splitResult: splitResult)
    }
    print()
    return passed
}

func printDetail(
    evalCase: EvalCase, convResult: ConversionResult?, splitResult: ConversionResult?
) {
    if let conv = convResult {
        print("  \(Color.red)actual:\(Color.reset)   \(formatPath(conv))")
        print("           \(formatScore(conv))")
    } else {
        print("  \(Color.red)actual:\(Color.reset)   (no Conversion result)")
    }

    let splitLabel = evalCase.expectedSplit.joined(separator: "|")
    if let split = splitResult {
        print("  \(Color.green)split:\(Color.reset)    \(splitLabel) → \(formatPath(split))")
        print("           \(formatScore(split))")
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
    fputs(
        "Usage: pinyin-eval [--json] [--coverage-weight N] [--word-noise-floor N]\n"
            + "                   [--syllable-greedy-weight N] [--word-length-weight N]\n"
            + "                   [--single-char-penalty N] <cases-file> [--dict <path>]\n",
        stderr)
    fputs("       pinyin-eval [--json] \"jingque|biaoyi 精确表意 精确表姨\"\n", stderr)
    fputs("       pinyin-eval -q <pinyin>\n", stderr)
    exit(1)
}

// 解析参数
var dictPath: String?
var inputArg: String?
var queryMode = false
var jsonMode = false
let defaults = ScoringConfig.default
var coverageWeight: Double = defaults.coverageWeight
var wordNoiseFloor: Int = defaults.wordNoiseFloor
var syllableGreedyWeight: Double = defaults.syllableGreedyWeight
var wordLengthWeight: Double = defaults.wordLengthWeight
var singleCharPenalty: Double = defaults.singleCharPenalty
var i = 1
while i < args.count {
    if args[i] == "--dict" && i + 1 < args.count {
        dictPath = args[i + 1]
        i += 2
    } else if args[i] == "-q" || args[i] == "--query" {
        queryMode = true
        i += 1
    } else if args[i] == "--json" {
        jsonMode = true
        i += 1
    } else if args[i] == "--coverage-weight" && i + 1 < args.count {
        guard let v = Double(args[i + 1]) else {
            fputs("Error: --coverage-weight expects a number, got '\(args[i + 1])'\n", stderr)
            exit(1)
        }
        coverageWeight = v
        i += 2
    } else if args[i] == "--word-noise-floor" && i + 1 < args.count {
        guard let v = Int(args[i + 1]) else {
            fputs(
                "Error: --word-noise-floor expects an integer, got '\(args[i + 1])'\n", stderr)
            exit(1)
        }
        wordNoiseFloor = v
        i += 2
    } else if args[i] == "--syllable-greedy-weight" && i + 1 < args.count {
        guard let v = Double(args[i + 1]) else {
            fputs(
                "Error: --syllable-greedy-weight expects a number, got '\(args[i + 1])'\n",
                stderr)
            exit(1)
        }
        syllableGreedyWeight = v
        i += 2
    } else if args[i] == "--word-length-weight" && i + 1 < args.count {
        guard let v = Double(args[i + 1]) else {
            fputs(
                "Error: --word-length-weight expects a number, got '\(args[i + 1])'\n", stderr)
            exit(1)
        }
        wordLengthWeight = v
        i += 2
    } else if args[i] == "--single-char-penalty" && i + 1 < args.count {
        guard let v = Double(args[i + 1]) else {
            fputs(
                "Error: --single-char-penalty expects a number, got '\(args[i + 1])'\n", stderr)
            exit(1)
        }
        singleCharPenalty = v
        i += 2
    } else if inputArg == nil {
        inputArg = args[i]
        i += 1
    } else {
        i += 1
    }
}

let scoringConfig = ScoringConfig(
    coverageWeight: coverageWeight,
    wordNoiseFloor: wordNoiseFloor,
    syllableGreedyWeight: syllableGreedyWeight,
    wordLengthWeight: wordLengthWeight,
    singleCharPenalty: singleCharPenalty)

guard let input = inputArg else {
    fputs(
        "Usage: pinyin-eval [--json] [--coverage-weight N] [--word-noise-floor N]\n"
            + "                   [--syllable-greedy-weight N] [--word-length-weight N]\n"
            + "                   [--single-char-penalty N] <cases-file> [--dict <path>]\n",
        stderr)
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

    // Conversion 结果
    if let convResult = Conversion.compose(
        pinyin, store: store, pinnedChars: pinnedChars, config: scoringConfig)
    {
        print(
            "\(Color.bold)conv:\(Color.reset)   \(convResult.text)  \(Color.dim)\(formatPath(convResult))\(Color.reset)"
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
    if evaluate(
        c, store: store, pinnedChars: pinnedChars, config: scoringConfig, jsonMode: jsonMode)
    {
        passed += 1
    } else {
        failed += 1
    }
}

// 汇总（JSON 模式下保持 NDJSON 干净，跳过汇总行）
if cases.count > 1 && !jsonMode {
    print()
    let summary =
        failed > 0
        ? "\(Color.red)\(failed) failed\(Color.reset), \(passed) passed"
        : "\(Color.green)All \(passed) passed\(Color.reset)"
    print("\(summary) (\(cases.count) cases)")
}

exit(failed > 0 ? 1 : 0)
