import Foundation

/// A value from the small YAML subset used by electron-builder metadata
/// (`app-update.yml`, `latest-mac.yml`): block maps, block lists, plain/quoted scalars
/// and `|` / `>` block scalars. Flow collections (`[a, b]`) are kept as plain strings.
enum ElectronYAMLValue: Sendable, Equatable {
    case scalar(String)
    case list([ElectronYAMLValue])
    case map([String: ElectronYAMLValue])

    subscript(key: String) -> ElectronYAMLValue? {
        guard case .map(let entries) = self else { return nil }
        return entries[key]
    }

    /// Non-empty scalar text.
    var string: String? {
        guard case .scalar(let text) = self, !text.isEmpty else { return nil }
        return text
    }

    var list: [ElectronYAMLValue]? {
        guard case .list(let items) = self else { return nil }
        return items
    }
}

/// Dependency-free, indentation-based parser for `ElectronYAMLValue`.
enum ElectronYAMLParser {
    static let maximumDepth = 32

    static func parse(_ data: Data) throws -> ElectronYAMLValue {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdaterError.parsing("YAML is not valid UTF-8")
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> ElectronYAMLValue {
        let reader = ElectronYAMLReader(text: text)
        let start = reader.nextSignificant(from: 0)
        guard start < reader.lines.count else { return .map([:]) }
        return try reader.node(at: start, depth: 0).value
    }
}

private struct YAMLLine {
    let indent: Int
    /// Content without indentation or trailing whitespace.
    let text: String
    /// Original line (for block scalars).
    let raw: Substring

    var isBlank: Bool { text.isEmpty }
    var isListItem: Bool { text == "-" || text.hasPrefix("- ") }
}

private struct ElectronYAMLReader {
    typealias Parsed = (value: ElectronYAMLValue, next: Int)

    let lines: [YAMLLine]

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            let raw = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            let expanded = raw.replacingOccurrences(of: "\t", with: " ")
            let body = expanded.drop(while: { $0 == " " })
            let text = String(body).trimmingCharacters(in: .whitespaces)
            return YAMLLine(indent: expanded.count - body.count, text: text, raw: raw)
        }
    }

    func nextSignificant(from index: Int) -> Int {
        var current = index
        while current < lines.count, isInsignificant(lines[current]) { current += 1 }
        return current
    }

    private func isInsignificant(_ line: YAMLLine) -> Bool {
        line.isBlank || line.text.hasPrefix("#") || (line.indent == 0 && (line.text == "---" || line.text == "..."))
    }

    func node(at index: Int, depth: Int) throws -> Parsed {
        guard depth < ElectronYAMLParser.maximumDepth else {
            throw UpdaterError.parsing("YAML nesting too deep")
        }
        let line = lines[index]
        if line.isListItem { return try list(at: index, indent: line.indent, depth: depth) }
        return try map(at: index, indent: line.indent, firstText: nil, depth: depth)
    }

    // MARK: Collections

    private func list(at start: Int, indent: Int, depth: Int) throws -> Parsed {
        var items: [ElectronYAMLValue] = []
        var index = nextSignificant(from: start)
        while index < lines.count, lines[index].indent == indent, lines[index].isListItem {
            let parsed = try listItem(at: index, depth: depth)
            items.append(parsed.value)
            index = nextSignificant(from: parsed.next)
        }
        return (.list(items), index)
    }

    private func listItem(at index: Int, depth: Int) throws -> Parsed {
        let line = lines[index]
        let afterDash = line.text.dropFirst()
        let content = String(afterDash.drop(while: { $0 == " " }))
        if content.isEmpty { return try child(after: index, parentIndent: line.indent, depth: depth) }
        if ElectronYAMLScalar.splitKeyValue(content) != nil {
            let contentIndent = line.indent + (line.text.count - content.count)
            return try map(at: index, indent: contentIndent, firstText: content, depth: depth + 1)
        }
        return (.scalar(ElectronYAMLScalar.unquote(content)), index + 1)
    }

    /// Parses map entries at `indent`. `firstText` is an entry inlined after a list dash on line `start`.
    private func map(at start: Int, indent: Int, firstText: String?, depth: Int) throws -> Parsed {
        var entries: [String: ElectronYAMLValue] = [:]
        var index = start
        if let firstText {
            let parsed = try entry(firstText, line: start, indent: indent, depth: depth)
            entries[parsed.key] = parsed.value
            index = parsed.next
        }
        index = nextSignificant(from: index)
        while index < lines.count, lines[index].indent == indent, !lines[index].isListItem {
            let parsed = try entry(lines[index].text, line: index, indent: indent, depth: depth)
            entries[parsed.key] = parsed.value
            index = nextSignificant(from: parsed.next)
        }
        return (.map(entries), index)
    }

    private func entry(
        _ text: String, line: Int, indent: Int, depth: Int
    ) throws -> (key: String, value: ElectronYAMLValue, next: Int) {
        guard let (key, rest) = ElectronYAMLScalar.splitKeyValue(text) else {
            throw UpdaterError.parsing("YAML line \(line + 1): expected 'key: value'")
        }
        if rest.isEmpty {
            let parsed = try child(after: line, parentIndent: indent, depth: depth, allowSameIndentList: true)
            return (key, parsed.value, parsed.next)
        }
        if let indicator = rest.first, indicator == "|" || indicator == ">" {
            let parsed = blockScalar(after: line, parentIndent: indent, header: rest)
            return (key, parsed.value, parsed.next)
        }
        return (key, .scalar(ElectronYAMLScalar.unquote(rest)), line + 1)
    }

    /// Nested node below `line`, or an empty scalar when nothing is nested.
    private func child(
        after line: Int, parentIndent: Int, depth: Int, allowSameIndentList: Bool = false
    ) throws -> Parsed {
        let next = nextSignificant(from: line + 1)
        guard next < lines.count else { return (.scalar(""), line + 1) }
        let candidate = lines[next]
        let isNested = candidate.indent > parentIndent
            || (allowSameIndentList && candidate.indent == parentIndent && candidate.isListItem)
        guard isNested else { return (.scalar(""), line + 1) }
        return try node(at: next, depth: depth + 1)
    }

    // MARK: Block scalars

    private func blockScalar(after line: Int, parentIndent: Int, header: String) -> Parsed {
        var index = line + 1
        var body: [YAMLLine] = []
        while index < lines.count, lines[index].isBlank || lines[index].indent > parentIndent {
            body.append(lines[index])
            index += 1
        }
        while let last = body.last, last.isBlank { body.removeLast() }
        let blockIndent = body.first(where: { !$0.isBlank })?.indent ?? 0
        let texts = body.map { $0.isBlank ? "" : String($0.raw.dropFirst(min(blockIndent, $0.raw.count))) }
        let joined = header.hasPrefix(">") ? Self.fold(texts) : texts.joined(separator: "\n")
        let keepsNewline = !header.contains("-") && !joined.isEmpty
        return (.scalar(keepsNewline ? joined + "\n" : joined), index)
    }

    private static func fold(_ texts: [String]) -> String {
        texts.reduce(into: "") { result, text in
            if text.isEmpty {
                result += "\n"
            } else if result.isEmpty || result.hasSuffix("\n") {
                result += text
            } else {
                result += " " + text
            }
        }
    }
}
