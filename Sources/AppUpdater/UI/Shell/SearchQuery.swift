import Foundation

/// The top bar's search text, matched the same way on every page: each whitespace-separated
/// term must appear in at least one of an item's fields, ignoring case and diacritics
/// ("gİthub desk" finds "GitHub Desktop", "guvenlik" finds "Güvenlik").
struct SearchQuery: Equatable, Sendable {
    let terms: [String]

    init(_ text: String) {
        terms = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    var isEmpty: Bool { terms.isEmpty }

    /// True when every term is found in some field; an empty query matches everything.
    func matches(_ fields: String?...) -> Bool {
        matches(fields: fields)
    }

    func matches(fields: [String?]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = fields.compactMap { $0 }
        return terms.allSatisfy { term in
            haystack.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Keeps the items whose fields match; returns the array untouched for an empty query.
    func filter<Item>(_ items: [Item], fields: (Item) -> [String?]) -> [Item] {
        guard !terms.isEmpty else { return items }
        return items.filter { matches(fields: fields($0)) }
    }
}
