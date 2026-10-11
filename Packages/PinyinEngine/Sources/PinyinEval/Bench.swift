import Foundation
import PinyinEngine

// MARK: - 逐键开销测量（--bench）

/// 测量序列：所属分组（如 full、abbr、mixed）与逐字母键入的输入串
struct BenchSequence {
    let group: String
    let input: String
}

/// 一次按键的开销
struct KeystrokeSample {
    var milliseconds: Double
    var statements: Int
    var vmSteps: Int
}

/// 解析 bench 序列文件：`[分组名]` 开启一个分组，其后每行一个输入串，`#` 开头为注释。
func parseBenchFile(_ path: String) -> [BenchSequence] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("\(Color.red)Error: cannot read file \(path)\(Color.reset)\n", stderr)
        exit(1)
    }
    var sequences: [BenchSequence] = []
    var group = "default"
    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            group = String(trimmed.dropFirst().dropLast())
            continue
        }
        sequences.append(BenchSequence(group: group, input: trimmed))
    }
    return sequences
}

/// 用一个新建的引擎逐字母键入 `input`，返回每次按键的耗时与中文词库查询开销。
/// 每次新建引擎，使引擎内的缓存不跨越测量轮次；用户词典使用内存库，不读写用户数据。
func measureKeystrokes(
    _ input: String, zhDictPath: String, jaDictPath: String,
    pinnedChars: PinnedCharStore?, pinnedWords: PinnedWordStore?
) -> [KeystrokeSample] {
    let engine = PinyinEngine(
        zhDictPath: zhDictPath, jaDictPath: jaDictPath, userDictPath: ":memory:",
        pinnedChars: pinnedChars, pinnedWords: pinnedWords)
    guard let store = engine.zhDictionary else {
        fputs("\(Color.red)Error: cannot open dictionary at \(zhDictPath)\(Color.reset)\n", stderr)
        exit(1)
    }
    var samples: [KeystrokeSample] = []
    for char in input {
        store.resetStats()
        let start = DispatchTime.now().uptimeNanoseconds
        _ = engine.process(.letter(char))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        samples.append(
            KeystrokeSample(
                milliseconds: elapsed, statements: store.stats.statements,
                vmSteps: store.stats.vmSteps))
    }
    return samples
}

/// 先预热一轮（让操作系统缓存词库页面），再重复 `runs` 轮，逐键取各项中位数。
func measureSequence(
    _ input: String, runs: Int, zhDictPath: String, jaDictPath: String,
    pinnedChars: PinnedCharStore?, pinnedWords: PinnedWordStore?
) -> [KeystrokeSample] {
    let measure = {
        measureKeystrokes(
            input, zhDictPath: zhDictPath, jaDictPath: jaDictPath,
            pinnedChars: pinnedChars, pinnedWords: pinnedWords)
    }
    _ = measure()
    let rounds = (0..<runs).map { _ in measure() }
    return (0..<input.count).map { key in
        KeystrokeSample(
            milliseconds: median(rounds.map { $0[key].milliseconds }),
            statements: Int(median(rounds.map { Double($0[key].statements) })),
            vmSteps: Int(median(rounds.map { Double($0[key].vmSteps) })))
    }
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

/// 最近秩法百分位
func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[max(0, min(rank, sorted.count) - 1)]
}

/// 一组按键样本的 p50 / p95 / max
struct Distribution {
    let p50: Double
    let p95: Double
    let max: Double

    init(_ values: [Double]) {
        p50 = percentile(values, 0.50)
        p95 = percentile(values, 0.95)
        max = values.max() ?? 0
    }
}

func runBench(
    file: String, runs: Int, zhDictPath: String, pinnedChars: PinnedCharStore?,
    pinnedWords: PinnedWordStore?
) -> Never {
    let jaDictPath =
        ((zhDictPath as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("ja_dict.db")
    let sequences = parseBenchFile(file)
    guard !sequences.isEmpty else {
        fputs("\(Color.red)Error: no sequences in \(file)\(Color.reset)\n", stderr)
        exit(1)
    }

    print("Per-keystroke cost, median of \(runs) runs after one warm-up (\(zhDictPath))")
    print()

    var groupOrder: [String] = []
    var samplesByGroup: [String: [KeystrokeSample]] = [:]
    for sequence in sequences {
        let samples = measureSequence(
            sequence.input, runs: runs, zhDictPath: zhDictPath, jaDictPath: jaDictPath,
            pinnedChars: pinnedChars, pinnedWords: pinnedWords)
        if samplesByGroup[sequence.group] == nil { groupOrder.append(sequence.group) }
        samplesByGroup[sequence.group, default: []].append(contentsOf: samples)

        let keys = zip(sequence.input, samples).map { char, sample in
            String(
                format: "%@ %.2fms/%dq/%dvm", String(char), sample.milliseconds,
                sample.statements, sample.vmSteps)
        }
        print("[\(sequence.group)] \(sequence.input): \(keys.joined(separator: "  "))")
    }

    print()
    print(
        "group     keys   latency ms p50/p95/max      statements p50/p95/max   VM steps p50/p95/max"
    )
    var distributions: [String: (latency: Distribution, vmSteps: Distribution)] = [:]
    for group in groupOrder {
        let samples = samplesByGroup[group] ?? []
        let latency = Distribution(samples.map { $0.milliseconds })
        let statements = Distribution(samples.map { Double($0.statements) })
        let vmSteps = Distribution(samples.map { Double($0.vmSteps) })
        distributions[group] = (latency, vmSteps)
        print(
            String(
                format: "%@ %5d   %7.2f %7.2f %7.2f   %7.0f %7.0f %7.0f   %9.0f %9.0f %9.0f",
                group.padding(toLength: 8, withPad: " ", startingAt: 0), samples.count,
                latency.p50, latency.p95, latency.max,
                statements.p50, statements.p95, statements.max,
                vmSteps.p50, vmSteps.p95, vmSteps.max))
    }

    if let full = distributions["full"], let abbr = distributions["abbr"] {
        print()
        print(
            String(
                format: "abbr/full ratio: latency p95 %.2f, VM steps p95 %.2f",
                abbr.latency.p95 / max(full.latency.p95, 0.001),
                abbr.vmSteps.p95 / max(full.vmSteps.p95, 1)))
    }
    exit(0)
}
