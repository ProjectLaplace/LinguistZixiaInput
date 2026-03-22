import Foundation
import os

/// 轻量级性能打点工具。超过阈值时通过 os_log 输出，平时零开销。
/// 日志可在 Console.app 中通过 Process "LaplaceIME" 过滤查看。
/// 同时在内存中聚合统计（count/avg/p95/max），通过 vprofile 上屏查看。
public enum Profiler {
    private static let logger = Logger(subsystem: "org.1b2c.inputmethod.LaplaceIME", category: "perf")

    /// 默认阈值：超过此毫秒数才输出日志
    public static var thresholdMs: Double = 5.0

    /// 每个 label 保留的最近采样数（用于计算 p95）
    private static let maxSamples = 1000
    /// 每个 label 保留的最慢调用数
    private static let topSlowestCount = 3

    /// 慢调用记录
    private struct SlowEntry {
        let elapsed: Double
        let detail: String
    }

    /// 统计数据结构
    private struct Stats {
        var count: Int = 0
        var sum: Double = 0
        var max: Double = 0
        var samples: [Double] = []
        var slowest: [SlowEntry] = []

        var avg: Double { count > 0 ? sum / Double(count) : 0 }

        var p95: Double {
            guard !samples.isEmpty else { return 0 }
            let sorted = samples.sorted()
            let idx = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
            return sorted[idx]
        }

        mutating func record(_ elapsed: Double, detail: String) {
            count += 1
            sum += elapsed
            if elapsed > max { max = elapsed }
            if samples.count >= Profiler.maxSamples {
                samples.removeFirst()
            }
            samples.append(elapsed)

            // 维护 top-N 最慢调用（按耗时降序）
            if slowest.count < Profiler.topSlowestCount {
                slowest.append(SlowEntry(elapsed: elapsed, detail: detail))
                slowest.sort { $0.elapsed > $1.elapsed }
            } else if elapsed > slowest.last!.elapsed {
                slowest[slowest.count - 1] = SlowEntry(elapsed: elapsed, detail: detail)
                slowest.sort { $0.elapsed > $1.elapsed }
            }
        }
    }

    /// label → 统计数据
    private static var statsMap: [String: Stats] = [:]

    /// 测量闭包执行时间，超过阈值时打印日志，同时记录统计
    /// - Parameters:
    ///   - label: 日志中显示的详细标签（如 "process(letter("a"))"），也用于慢调用记录
    ///   - statsLabel: 统计聚合用的标签（如 "process"），默认同 label
    @inline(__always)
    public static func measure<T>(_ label: String, statsLabel: String? = nil, _ body: () -> T) -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = body()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        record(statsLabel ?? label, elapsed: elapsed, detail: label)
        if elapsed >= thresholdMs {
            logger.warning("\(label, privacy: .public): \(String(format: "%.1f", elapsed), privacy: .public)ms")
        }
        return result
    }

    /// 记录一次耗时到统计（供手动计时场景使用）
    public static func record(_ label: String, elapsed: Double, detail: String? = nil) {
        statsMap[label, default: Stats()].record(elapsed, detail: detail ?? label)
    }

    /// 记录生命周期事件或超阈值的性能日志（持久化，随时可查）
    public static func event(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    /// 生成聚合统计摘要，然后清空统计数据
    public static func summary() -> String {
        guard !statsMap.isEmpty else { return "[perf] no data" }

        var lines: [String] = []
        for (label, stats) in statsMap.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "[perf] \(label): \(stats.count)calls avg=\(f(stats.avg))ms p95=\(f(stats.p95))ms max=\(f(stats.max))ms"
            )
            for entry in stats.slowest {
                lines.append("  \(f(entry.elapsed))ms \(entry.detail)")
            }
        }
        statsMap.removeAll()
        return lines.joined(separator: "\n")
    }

    private static func f(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}
