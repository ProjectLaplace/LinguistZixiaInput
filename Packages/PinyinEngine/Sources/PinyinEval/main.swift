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

// MARK: - Evaluation

func evaluate(_ evalCase: EvalCase, store: DictionaryStore) -> Bool {
    let dpResult = DPDiagnostics.evaluateDP(evalCase.rawPinyin, store: store)
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
    if let splitResult = DPDiagnostics.evaluateSplit(evalCase.expectedSplit, store: store) {
        print("  \(Color.green)split:\(Color.reset)    \(splitLabel) → \(formatPath(splitResult))")
        print("           \(formatScore(splitResult))")
    } else {
        print("  \(Color.green)split:\(Color.reset)    \(splitLabel) → (no dictionary match)")
    }
}

// MARK: - Main

func findDictionary() -> String {
    // 1. 从环境变量
    if let envPath = ProcessInfo.processInfo.environment["PINYIN_DICT_PATH"] {
        return envPath
    }

    // 2. 相对于可执行文件的常见位置
    let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

    // 3. 相对于项目根目录
    let candidates = [
        execDir.appendingPathComponent("../../../Sources/PinyinEngine/Resources/zh_dict.db").path,
        execDir.appendingPathComponent("zh_dict.db").path,
        // 从 Package 目录运行时
        "Sources/PinyinEngine/Resources/zh_dict.db",
        "Packages/PinyinEngine/Sources/PinyinEngine/Resources/zh_dict.db",
    ]

    for path in candidates {
        let resolved = (path as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: resolved) {
            return resolved
        }
    }

    fputs(
        "\(Color.red)Error: cannot find zh_dict.db. Set PINYIN_DICT_PATH or run from project root.\(Color.reset)\n",
        stderr)
    exit(1)
}

let args = CommandLine.arguments

if args.count < 2 {
    fputs("Usage: pinyin-eval <cases-file> [--dict <path>]\n", stderr)
    fputs("       pinyin-eval \"jingque|biaoyi 精确表意 精确表姨\"\n", stderr)
    exit(1)
}

// 解析 --dict 参数
var dictPath: String?
var inputArg: String?
var i = 1
while i < args.count {
    if args[i] == "--dict" && i + 1 < args.count {
        dictPath = args[i + 1]
        i += 2
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
    if evaluate(c, store: store) {
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
