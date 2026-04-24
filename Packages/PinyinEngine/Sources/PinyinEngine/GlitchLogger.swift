import Foundation

/// 诊断 glitch 日志器：用户主动按 hotkey 时记录当前拼音 + 候选 + Conversion 诊断。
///
/// 仅在 marker 文件 `~/Library/Application Support/LaplaceIME/collect.on` 存在时启用；
/// 关闭时 `isEnabled` 为 false，`log(...)` 直接返回不做任何 IO。
///
/// 日志格式：NDJSON，一行一个 entry，追加写入
/// `~/Library/Application Support/LaplaceIME/glitches.jsonl`。
/// 配套工具：`tools/harvest_cases.py` 读日志、去重、整理成 fixture 候选供人工 review。
final class GlitchLogger {
    static let shared = GlitchLogger()

    private let baseDir: URL
    private let markerPath: String
    private let logPath: URL

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        baseDir = appSupport.appendingPathComponent("LaplaceIME", isDirectory: true)
        markerPath = baseDir.appendingPathComponent("collect.on").path
        logPath = baseDir.appendingPathComponent("glitches.jsonl")
    }

    /// marker 文件存在即开启
    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: markerPath)
    }

    /// 追加一条 entry。关闭或 IO 失败都静默；这是辅助诊断功能，绝不阻塞主流程。
    func log(pinyin: String, candidates: [String], conv: ConversionResult?) {
        guard isEnabled else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var entry: [String: Any] = [
            "ts": formatter.string(from: Date()),
            "pinyin": pinyin,
            "top": candidates.first as Any? ?? NSNull(),
            "candidates": Array(candidates.prefix(5)),
        ]
        if let conv = conv {
            let segs: [[String: Any]] = conv.segments.map {
                ["word": $0.word, "pinyin": $0.pinyin, "frequency": $0.frequency]
            }
            entry["chunks"] = conv.chunks
            entry["conv"] = [
                "text": conv.text,
                "segments": segs,
                "wordFreqAvg": conv.wordFreqAvg,
                "wordCoverage": conv.wordCoverage,
                "pathScore": conv.pathScore,
                "segmentCount": conv.segmentCount,
                "totalFreqSum": conv.totalFreqSum,
            ]
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        else { return }

        do {
            try FileManager.default.createDirectory(
                at: baseDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logPath.path) {
                FileManager.default.createFile(atPath: logPath.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logPath)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
            if let nl = "\n".data(using: .utf8) {
                handle.write(nl)
            }
        } catch {
            // 静默：诊断功能最佳努力，不抛错
        }
    }
}
