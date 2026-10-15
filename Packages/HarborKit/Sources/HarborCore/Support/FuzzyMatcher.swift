import Foundation

/// Subsequence matching with bonuses for contiguous runs and word starts —
/// "prdapi" finds "prod-api", and typing a prefix ranks highest.
public enum FuzzyMatcher {
    /// Returns nil when `query` is not a subsequence of `candidate`. Both should be lowercased.
    public static func score(_ query: String, in candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let needle = Array(query)
        let haystack = Array(candidate)
        var score = 0
        var needleIndex = 0
        var previousMatch: Int?

        for (index, character) in haystack.enumerated() where needleIndex < needle.count {
            guard character == needle[needleIndex] else { continue }
            score += 1
            if let previousMatch, previousMatch == index - 1 { score += 4 }
            if index == 0 || " -_.@/".contains(haystack[index - 1]) { score += 6 }
            previousMatch = index
            needleIndex += 1
        }
        guard needleIndex == needle.count else { return nil }
        if candidate.hasPrefix(query) { score += 20 }
        return score
    }
}
