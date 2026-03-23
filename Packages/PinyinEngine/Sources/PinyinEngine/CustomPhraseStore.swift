import Foundation

/// Loads custom phrases from a TOML config file.
/// File format (custom_phrases.toml):
///   [phrases]
///   addr = '上海市长宁区'
///   xl_ = ['α', 'β', 'γ']
///   sign = '''
///   --乘风破浪会有时--
///   --直挂云帆济沧海--'''
///
/// Each name maps to one or more candidate strings.
public class CustomPhraseStore {
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

    /// Look up custom phrases for a given name.
    /// Returns an array of candidate strings in definition order, or empty if none.
    public func phrases(for name: String) -> [String] {
        return table[name] ?? []
    }

    /// Check if a name has any custom phrases defined.
    public func hasPhrase(_ name: String) -> Bool {
        return table[name] != nil
    }

    // MARK: - TOML parser for [phrases] section

    private static func parse(_ content: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0)
        }
        var inPhrasesSection = false
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            // Section header
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("['") && !trimmed.hasPrefix("[\"") {
                inPhrasesSection = (trimmed == "[phrases]")
                i += 1
                continue
            }

            guard inPhrasesSection else {
                i += 1
                continue
            }

            // Parse key = value
            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                i += 1
                continue
            }
            let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                i += 1
                continue
            }

            let rawValue = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(
                in: .whitespaces)

            // Determine value type and parse
            if rawValue.hasPrefix("[") {
                // Array value — may span multiple lines
                let (array, consumed) = parseArray(lines: lines, startLine: i, afterEqual: rawValue)
                let existing = result[key] ?? []
                result[key] = existing + array
                i += consumed
            } else if rawValue.hasPrefix("'''") {
                // Multi-line literal string
                let (str, consumed) = parseTripleQuoted(
                    lines: lines, startLine: i, afterEqual: rawValue)
                let existing = result[key] ?? []
                result[key] = existing + [str]
                i += consumed
            } else {
                // Single value (quoted or unquoted)
                let value = stripQuotes(rawValue)
                let existing = result[key] ?? []
                result[key] = existing + [value]
                i += 1
            }
        }

        return result
    }

    /// Strip surrounding single or double quotes from a string.
    private static func stripQuotes(_ s: String) -> String {
        if s.count >= 2 {
            if (s.hasPrefix("'") && s.hasSuffix("'"))
                || (s.hasPrefix("\"") && s.hasSuffix("\""))
            {
                return String(s.dropFirst().dropLast())
            }
        }
        return s
    }

    /// Parse a triple-quoted literal string ('''...''').
    /// Returns (parsed string, number of lines consumed).
    private static func parseTripleQuoted(lines: [String], startLine: Int, afterEqual: String)
        -> (String, Int)
    {
        // afterEqual starts with '''
        let content = String(afterEqual.dropFirst(3))

        // Check if closing ''' is on the same line
        if let closeRange = content.range(of: "'''") {
            let str = String(content[content.startIndex..<closeRange.lowerBound])
            return (str, 1)
        }

        // Multi-line: collect until we find '''
        var parts: [String] = [content]
        var lineIdx = startLine + 1
        while lineIdx < lines.count {
            let line = lines[lineIdx]
            if let closeRange = line.range(of: "'''") {
                parts.append(String(line[line.startIndex..<closeRange.lowerBound]))
                return (parts.joined(separator: "\n"), lineIdx - startLine + 1)
            }
            parts.append(line)
            lineIdx += 1
        }

        // No closing ''' found — take what we have
        return (parts.joined(separator: "\n"), lines.count - startLine)
    }

    /// Parse an inline or multi-line TOML array.
    /// Returns (array of strings, number of lines consumed).
    private static func parseArray(lines: [String], startLine: Int, afterEqual: String) -> (
        [String], Int
    ) {
        // Collect the full array text (may span multiple lines)
        var text = String(afterEqual)
        var lineIdx = startLine + 1

        // Check if the array is closed on the first line
        if arrayIsClosed(text) {
            return (parseArrayItems(text), 1)
        }

        // Multi-line array: collect lines until balanced ]
        while lineIdx < lines.count {
            text += "\n" + lines[lineIdx]
            lineIdx += 1
            if arrayIsClosed(text) {
                break
            }
        }

        return (parseArrayItems(text), lineIdx - startLine)
    }

    /// Check if a TOML array text has balanced brackets (outside of quotes).
    private static func arrayIsClosed(_ text: String) -> Bool {
        var depth = 0
        var inSingle = false
        var inTriple = false
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            // Check for triple quotes
            if i + 2 < chars.count && chars[i] == "'" && chars[i + 1] == "'"
                && chars[i + 2] == "'"
            {
                if inTriple {
                    inTriple = false
                    i += 3
                    continue
                } else if !inSingle {
                    inTriple = true
                    i += 3
                    continue
                }
            }

            if !inTriple {
                if chars[i] == "'" && !inSingle {
                    inSingle = true
                } else if chars[i] == "'" && inSingle {
                    inSingle = false
                } else if !inSingle {
                    if chars[i] == "[" {
                        depth += 1
                    } else if chars[i] == "]" {
                        depth -= 1
                        if depth == 0 { return true }
                    }
                }
            }

            i += 1
        }
        return false
    }

    /// Parse items from a TOML array string like "['a', 'b', '''multi\nline''']".
    private static func parseArrayItems(_ text: String) -> [String] {
        var items: [String] = []
        let chars = Array(text)
        var i = 0

        // Skip to first [
        while i < chars.count && chars[i] != "[" { i += 1 }
        i += 1  // skip [

        while i < chars.count {
            // Skip whitespace, commas, newlines
            while i < chars.count
                && (chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\r"
                    || chars[i] == "\t")
            {
                i += 1
            }

            if i >= chars.count || chars[i] == "]" { break }

            // Check for triple-quoted string
            if i + 2 < chars.count && chars[i] == "'" && chars[i + 1] == "'"
                && chars[i + 2] == "'"
            {
                i += 3
                var content: [Character] = []
                while i < chars.count {
                    if i + 2 < chars.count && chars[i] == "'" && chars[i + 1] == "'"
                        && chars[i + 2] == "'"
                    {
                        i += 3
                        break
                    }
                    content.append(chars[i])
                    i += 1
                }
                let str = String(content)
                // Strip leading newline (TOML convention for triple-quoted after opening)
                if str.hasPrefix("\n") {
                    items.append(String(str.dropFirst()))
                } else {
                    items.append(str)
                }
            }
            // Single-quoted string
            else if chars[i] == "'" {
                i += 1
                var content: [Character] = []
                while i < chars.count && chars[i] != "'" {
                    content.append(chars[i])
                    i += 1
                }
                if i < chars.count { i += 1 }  // skip closing '
                items.append(String(content))
            }
            // Double-quoted string
            else if chars[i] == "\"" {
                i += 1
                var content: [Character] = []
                while i < chars.count && chars[i] != "\"" {
                    content.append(chars[i])
                    i += 1
                }
                if i < chars.count { i += 1 }  // skip closing "
                items.append(String(content))
            }
            // Unquoted value (shouldn't happen in well-formed TOML, but handle gracefully)
            else {
                var content: [Character] = []
                while i < chars.count && chars[i] != "," && chars[i] != "]" {
                    content.append(chars[i])
                    i += 1
                }
                let trimmed = String(content).trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    items.append(trimmed)
                }
            }
        }

        return items
    }

    // MARK: - Default path

    /// Load from the default user config location:
    /// ~/Library/Application Support/LaplaceIME/custom_phrases.toml
    public static func loadDefault() -> CustomPhraseStore? {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            return nil
        }
        let path = appSupport.appendingPathComponent("LaplaceIME/custom_phrases.toml").path
        return CustomPhraseStore(path: path)
    }
}
