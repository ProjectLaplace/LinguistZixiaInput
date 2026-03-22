import Foundation

/// Loads pinned characters from a TOML config file.
/// File format (pinned_chars.toml):
///   [pinned]
///   d = "的地得大"
///   shi = "是时"
///
/// Each value is a string of characters; position = priority (first char = candidate #1).
public class PinnedCharStore {
    private var table: [String: [String]] = [:]

    /// Initialize from a TOML file at the given path.
    public init?(path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        table = Self.parse(content)
    }

    /// Initialize from raw TOML string (for testing).
    public init(toml: String) {
        table = Self.parse(toml)
    }

    /// Look up pinned characters for a pinyin syllable.
    /// Returns an array of single-character strings in priority order, or empty if none.
    public func pinnedChars(for pinyin: String) -> [String] {
        return table[pinyin] ?? []
    }

    // MARK: - Minimal TOML parser

    /// Parse a simple TOML file with [pinned] section and `key = "value"` entries.
    private static func parse(_ content: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var inPinnedSection = false

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Section header
            if trimmed.hasPrefix("[") {
                inPinnedSection = (trimmed == "[pinned]")
                continue
            }

            guard inPinnedSection else { continue }

            // Parse key = "value"
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(
                in: .whitespaces)

            // Strip quotes
            let value: String
            if rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"") && rawValue.count >= 2 {
                value = String(rawValue.dropFirst().dropLast())
            } else {
                value = rawValue
            }

            guard !key.isEmpty else { continue }

            // Split value into individual characters
            let chars = value.map { String($0) }.filter { !$0.isEmpty }
            result[key] = chars
        }

        return result
    }

    // MARK: - Default path

    /// Load from the default user config location:
    /// ~/Library/Application Support/LaplaceIME/pinned_chars.toml
    public static func loadDefault() -> PinnedCharStore? {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            return nil
        }
        let path = appSupport.appendingPathComponent("LaplaceIME/pinned_chars.toml").path
        return PinnedCharStore(path: path)
    }
}
