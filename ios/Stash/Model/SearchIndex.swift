import Foundation

/// Ranks items against a free-text query.
///
/// Weights favour what the user wrote (phrases, title) over what the AI inferred,
/// matches every query word (AND), and tolerates prefixes and diacritics.
nonisolated enum SearchIndex {
    struct Fields: Sendable {
        var phrases: [String]
        var title: String
        var notes: String
        var tags: [String]
        var summary: String
        var ocr: String
    }

    static func fields(of item: StashItem) -> Fields {
        Fields(
            phrases: item.phrases,
            title: item.title,
            notes: item.notes,
            tags: item.aiTags,
            summary: item.aiSummary,
            ocr: item.ocrText
        )
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    static func tokens(_ text: String) -> [String] {
        normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Returns nil when the item doesn't match every query token.
    static func score(_ fields: Fields, query: String) -> Double? {
        let queryNorm = normalize(query).trimmingCharacters(in: .whitespaces)
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return 0 }

        let weighted: [(text: String, weight: Double)] =
            fields.phrases.map { ($0, 10) }
            + [(fields.title, 8)]
            + fields.tags.map { ($0, 5) }
            + [(fields.notes, 4), (fields.ocr, 4), (fields.summary, 2)]

        let prepared = weighted.map { (norm: normalize($0.text), words: tokens($0.text), weight: $0.weight) }
        var total = 0.0

        for token in queryTokens {
            var best = 0.0
            for field in prepared {
                if field.words.contains(token) {
                    best = max(best, field.weight)
                } else if field.words.contains(where: { $0.hasPrefix(token) }) {
                    best = max(best, field.weight * 0.7)
                } else if token.count >= 4, field.words.contains(where: { closeEnough($0, token) }) {
                    best = max(best, field.weight * 0.4)
                }
            }
            if best == 0 { return nil }
            total += best
        }

        // Whole-phrase bonus: "this is fine" exactly matching a saved phrase beats loose word hits.
        if queryTokens.count > 1 {
            for field in prepared where field.norm.contains(queryNorm) {
                total += field.weight * 2
            }
        }
        return total
    }

    /// Edit distance ≤ 1 for short words, ≤ 2 for long ones. Catches "suprised", "cofee".
    static func closeEnough(_ a: String, _ b: String) -> Bool {
        let limit = max(a.count, b.count) >= 8 ? 2 : 1
        guard abs(a.count - b.count) <= limit else { return false }
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMin = current[0]
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return false }
            previous = current
        }
        return previous[b.count] <= limit
    }
}
