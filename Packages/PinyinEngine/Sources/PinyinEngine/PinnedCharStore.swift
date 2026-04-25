import Foundation

/// Two-layer pinned char store: sys (bundled, read-only) + user (Application Support, writable).
/// File format (TOML):
///   [pinned]
///   d = "的地得大"
///   shi = "是时"
///
/// Each value is a string of characters; position = priority (first char = top candidate).
/// Lookup merges both layers (user first, then sys) and dedupes by character.
public class PinnedCharStore: PinnedLookup {
    /// 系统层（bundle 内置只读数据），由 `Bundle.module` 加载。
    private var sysTable: [String: [String]] = [:]
    /// 用户层（Application Support 可写），用户 pin / unpin 操作只影响这一层。
    private var userTable: [String: [String]] = [:]
    /// 用户层文件路径；非 nil 时写操作会原子回写。
    private let userPath: String?

    /// 双层初始化：分别加载 sys 与 user 文件。任一为 nil 或文件缺失即该层为空。
    public init(sysPath: String?, userPath: String?) {
        self.userPath = userPath
        if let sysPath = sysPath,
            let content = try? String(contentsOfFile: sysPath, encoding: .utf8)
        {
            sysTable = Self.parse(content)
        }
        if let userPath = userPath,
            let content = try? String(contentsOfFile: userPath, encoding: .utf8)
        {
            userTable = Self.parse(content)
        }
    }

    /// user-only 兼容初始化：把指定路径作为用户层加载，sys 层为空。
    public init?(path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        self.userPath = path
        userTable = Self.parse(content)
    }

    /// user-only 兼容初始化（用于测试）：从 TOML 字符串构造，sys 层为空，无持久化。
    public init(toml: String) {
        self.userPath = nil
        userTable = Self.parse(toml)
    }

    /// Return the merged pinned char list for the given pinyin (user layer first, deduped).
    public func pinnedChars(for pinyin: String) -> [String] {
        return PinnedLookupHelper.merge(
            user: userTable[pinyin] ?? [],
            sys: sysTable[pinyin] ?? [],
            candidates: [])
    }

    /// `PinnedLookup` 协议实现：转发到 `pinnedChars(for:)`。
    public func pinned(for pinyin: String) -> [String] {
        return pinnedChars(for: pinyin)
    }

    // MARK: - 写操作（仅作用于 user 层）

    /// 把一个字 pin 到指定拼音的用户层队首。
    /// - 若已在 user 列表则移到队首（去重）。
    /// - 若不在则插入队首。
    /// - userPath 非 nil 时原子写回文件。
    public func pin(_ char: String, forPinyin pinyin: String) {
        var list = userTable[pinyin] ?? []
        list.removeAll { $0 == char }
        list.insert(char, at: 0)
        userTable[pinyin] = list
        persistUserTable()
    }

    /// 从用户层移除某字。不影响 sys 层。
    /// userPath 非 nil 时原子写回文件。
    public func unpinUser(_ char: String, forPinyin pinyin: String) {
        guard var list = userTable[pinyin] else { return }
        let originalCount = list.count
        list.removeAll { $0 == char }
        guard list.count != originalCount else { return }
        if list.isEmpty {
            userTable.removeValue(forKey: pinyin)
        } else {
            userTable[pinyin] = list
        }
        persistUserTable()
    }

    /// 把当前 user 层序列化为 TOML 并原子写回 userPath。
    /// userPath 为 nil（例如 `init(toml:)` 测试场景）时静默跳过。
    private func persistUserTable() {
        guard let userPath = userPath else { return }
        let url = URL(fileURLWithPath: userPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = Self.serialize(userTable).data(using: .utf8) ?? Data()
            try data.write(to: url, options: [.atomic])
        } catch {
            // 写失败不影响进程内状态，下次启动会回到磁盘上的旧值。
        }
    }

    // MARK: - 极简 TOML 解析

    /// 解析含 `[pinned]` section 与 `key = "value"` 条目的最小 TOML 子集。
    private static func parse(_ content: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var inPinnedSection = false

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 跳过空行与注释
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // section 头
            if trimmed.hasPrefix("[") {
                inPinnedSection = (trimmed == "[pinned]")
                continue
            }

            guard inPinnedSection else { continue }

            // 解析 key = "value"
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(
                in: .whitespaces)

            // 去引号
            let value: String
            if rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"") && rawValue.count >= 2 {
                value = String(rawValue.dropFirst().dropLast())
            } else {
                value = rawValue
            }

            guard !key.isEmpty else { continue }

            // 把 value 拆成单字数组
            let chars = value.map { String($0) }.filter { !$0.isEmpty }
            result[key] = chars
        }

        return result
    }

    /// 把 user 层 table 序列化为 TOML 文本（以 `[pinned]` 为唯一 section）。
    /// key 排序保证写回文件稳定，便于人工 diff。
    private static func serialize(_ table: [String: [String]]) -> String {
        var lines: [String] = ["[pinned]"]
        for key in table.keys.sorted() {
            let value = (table[key] ?? []).joined()
            lines.append("\(key) = \"\(value)\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 默认加载入口

    /// 同时加载 bundle 内的 sys 文件与 Application Support 下的 user 文件。
    /// - sys: `Bundle.module` 中的 `sys_pinned_chars.toml`（若资源缺失即 sys 层为空）。
    /// - user: `~/Library/Application Support/LaplaceIME/pinned_chars.toml`。
    public static func loadDefault() -> PinnedCharStore? {
        let sysPath = Bundle.module.url(
            forResource: "sys_pinned_chars", withExtension: "toml")?.path
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            // 没有用户目录也仍然返回 sys-only 的 store，保证 bundle 数据可用。
            return PinnedCharStore(sysPath: sysPath, userPath: nil)
        }
        let userPath = appSupport.appendingPathComponent("LaplaceIME/pinned_chars.toml").path
        return PinnedCharStore(sysPath: sysPath, userPath: userPath)
    }
}
