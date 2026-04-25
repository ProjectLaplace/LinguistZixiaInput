import Foundation

/// Common abstraction for two-layer pinned-char / pinned-word lookup (user + sys).
/// Implementers merge the two layers into a single deduped, ordered list; callers only see the query API.
public protocol PinnedLookup {
    /// Return the merged pinned list for the given pinyin (user layer first, then sys, deduped).
    func pinned(for pinyin: String) -> [String]
}

/// Shared merge helper: concatenate user / sys / dict candidates in first-wins order with dedup.
/// Lifted into its own namespace so PinnedCharStore and the future PinnedWordStore can share it.
public enum PinnedLookupHelper {
    /// Merge `[user] + [sys] + [candidates]`, deduped by string identity, preserving first occurrence.
    /// - Parameters:
    ///   - user: User-layer pinned entries; highest priority.
    ///   - sys: Sys-layer pinned entries; second priority.
    ///   - candidates: Raw candidates from dict / frequency; lowest priority.
    /// - Returns: Deduped ordered list. The relative order within each input is preserved (apart from removed duplicates).
    public static func merge(user: [String], sys: [String], candidates: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(user.count + sys.count + candidates.count)

        for source in [user, sys, candidates] {
            for item in source where !seen.contains(item) {
                seen.insert(item)
                result.append(item)
            }
        }

        return result
    }
}
