import Foundation

/// 极简 TOML 解析器，仅支持 PinnedChar / PinnedWord 配置文件需要的子集：
/// - 单 section（一般是 `[pinned]`），其它 section 整体跳过
/// - `key = "value"` 字符串
/// - `key = ["a", "b"]` 单行字符串数组（不支持嵌套、转义、跨行）
/// - `#` 行内注释
///
/// 中文词不含特殊字符，所以不需要支持转义；保持实现尽可能小。
/// 调用方拿到 `[String: [String]]` 后按各自语义解读：
/// - `PinnedCharStore` 把单字符串值拆成单字数组
/// - `PinnedWordStore` 直接当作完整词项数组
enum MinimalTOML {
    /// 解析指定 section 内的所有 key/value 条目。
    /// - Parameters:
    ///   - content: TOML 文本
    ///   - section: 要进入的 section 头（如 `pinned`），不带方括号
    /// - Returns: `key -> [value]`；字符串值统一包成单元素数组。
    static func parse(_ content: String, section: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var inTargetSection = false
        let targetHeader = "[\(section)]"

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 跳过空行与注释
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // section 头：仅 targetHeader 进入解析状态
            if trimmed.hasPrefix("[") {
                inTargetSection = (trimmed == targetHeader)
                continue
            }

            guard inTargetSection else { continue }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(
                in: .whitespaces)

            guard !key.isEmpty else { continue }

            result[key] = parseValue(rawValue)
        }

        return result
    }

    /// 解析 value 部分：字符串视作单元素数组，数组语法逐项 trim + 去引号。
    private static func parseValue(_ raw: String) -> [String] {
        if raw.hasPrefix("[") && raw.hasSuffix("]") && raw.count >= 2 {
            let inner = raw.dropFirst().dropLast()
            // 数组为空（`[]`）→ 返回空数组
            let body = inner.trimmingCharacters(in: .whitespaces)
            if body.isEmpty {
                return []
            }
            return inner.split(separator: ",").map { token in
                stripQuotes(token.trimmingCharacters(in: .whitespaces))
            }.filter { !$0.isEmpty }
        }
        return [stripQuotes(raw)]
    }

    /// 去掉成对的双引号或单引号；不含引号则原样返回。
    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
