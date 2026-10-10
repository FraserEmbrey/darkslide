import Foundation

/// Search that forgives typing mistakes: every word typed must match a word
/// of the text, as its start or within it, or be within a letter or two of
/// one (a missed, extra, swapped or wrong letter). Short words must match
/// exactly, as one wrong letter in three is a different word.
enum FuzzySearch {
    static func matches(_ query: String, in texts: [String]) -> Bool {
        let words = tokens(query)
        guard !words.isEmpty else { return true }
        let candidates = texts.flatMap(tokens)
        let joined = texts.joined(separator: " ").lowercased()
        return words.allSatisfy { w in
            joined.contains(w) || candidates.contains { close(w, $0) }
        }
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// within the allowed edits of the candidate, or of its start as long as the typed word
    private static func close(_ w: String, _ c: String) -> Bool {
        let allowed = w.count >= 8 ? 2 : w.count >= 4 ? 1 : 0
        guard allowed > 0 else { return false }
        if distance(w, c) <= allowed { return true }
        // partly typed: compare with the candidate's start
        if c.count > w.count { return distance(w, String(c.prefix(w.count))) <= allowed }
        return false
    }

    /// Damerau–Levenshtein (optimal string alignment) distance
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}
