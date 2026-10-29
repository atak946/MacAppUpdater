import Foundation

/// Scalar-level helpers for `ElectronYAMLParser`: key/value splitting and unquoting.
enum ElectronYAMLScalar {
    /// Splits `key: value` at the first `:` followed by a space or end of line, outside quotes.
    /// Returns nil when the text is not a mapping entry (e.g. a URL like `https://x`).
    static func splitKeyValue(_ text: String) -> (key: String, value: String)? {
        guard let first = text.first else { return nil }
        if first == "'" || first == "\"" { return splitQuotedKey(text, quote: first) }
        var index = text.startIndex
        while let colon = text[index...].firstIndex(of: ":") {
            let after = text.index(after: colon)
            if after == text.endIndex || text[after] == " " {
                let key = text[..<colon].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !key.hasPrefix("#") else { return nil }
                return (key, text[after...].trimmingCharacters(in: .whitespaces))
            }
            index = after
        }
        return nil
    }

    private static func splitQuotedKey(_ text: String, quote: Character) -> (key: String, value: String)? {
        guard let close = closingQuote(in: text, quote: quote) else { return nil }
        let rest = text[text.index(after: close)...].drop(while: { $0 == " " })
        guard rest.first == ":" else { return nil }
        let afterColon = rest.dropFirst()
        guard afterColon.isEmpty || afterColon.first == " " else { return nil }
        return (unquote(String(text[...close])), afterColon.trimmingCharacters(in: .whitespaces))
    }

    /// Unquotes a scalar: `'it''s'`, `"a\"b\n"`, or plain text with an inline ` #comment` removed.
    static func unquote(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "" }
        switch first {
        case "'":
            guard let close = closingQuote(in: text, quote: "'") else { return text }
            return String(text[text.index(after: text.startIndex)..<close]).replacingOccurrences(of: "''", with: "'")
        case "\"":
            guard let close = closingQuote(in: text, quote: "\"") else { return text }
            return unescape(text[text.index(after: text.startIndex)..<close])
        default:
            return stripComment(text)
        }
    }

    /// Index of the quote closing the one at `text.startIndex`.
    private static func closingQuote(in text: String, quote: Character) -> String.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let next = text.index(after: index)
            if quote == "\"", text[index] == "\\" {
                index = next < text.endIndex ? text.index(after: next) : next
                continue
            }
            if text[index] == quote {
                // `''` inside single quotes is an escaped quote.
                guard quote == "'", next < text.endIndex, text[next] == "'" else { return index }
                index = text.index(after: next)
                continue
            }
            index = next
        }
        return nil
    }

    private static func unescape(_ body: Substring) -> String {
        var result = ""
        var isEscaping = false
        for character in body {
            if isEscaping {
                result.append(escaped(character))
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func escaped(_ character: Character) -> Character {
        switch character {
        case "n": "\n"
        case "t": "\t"
        case "r": "\r"
        case "0": "\0"
        default: character
        }
    }

    private static func stripComment(_ text: String) -> String {
        guard let range = text.range(of: " #") else { return text }
        return text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    }
}
