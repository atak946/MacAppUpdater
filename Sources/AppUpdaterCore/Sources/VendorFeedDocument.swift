import Foundation

/// A decoded vendor feed (JSON or XML) that answers dot-separated key paths.
/// Only used synchronously inside one lookup, so it holds Foundation property-list values.
struct VendorFeedDocument {
    private let root: Any

    private init(root: Any) {
        self.root = root
    }

    /// Each element of the array at `path` as its own document (empty when not an array).
    func elements(at path: String) -> [VendorFeedDocument] {
        guard let array = value(at: path) as? [Any] else { return [] }
        return array.map(VendorFeedDocument.init(root:))
    }

    /// Matches the fetch limit; `URLSessionHTTPClient` already stops reading beyond it.
    static let maximumSize = HTTPFetchLimit.feed

    init(data: Data, format: VendorFeedFormat) throws {
        guard data.count <= Self.maximumSize else {
            throw UpdaterError.parsing("Vendor feed is too large")
        }
        switch format {
        case .json:
            do {
                root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            } catch {
                throw UpdaterError.parsing("Invalid vendor JSON: \(error.localizedDescription)")
            }
        case .xml:
            root = try VendorXMLTreeBuilder.build(data)
        }
    }

    /// Scalar at `path` as a trimmed, non-empty string.
    func string(at path: String) -> String? {
        Self.scalarText(value(at: path))
    }

    private func value(at path: String) -> Any? {
        path.split(separator: ".").reduce(Optional(root)) { current, component in
            current.flatMap { Self.child(of: $0, component: String(component)) }
        }
    }

    private static func child(of value: Any, component: String) -> Any? {
        if let object = value as? [String: Any] { return object[component] }
        if let array = value as? [Any], let index = Int(component), array.indices.contains(index) {
            return array[index]
        }
        return nil
    }

    private static func scalarText(_ value: Any?) -> String? {
        let text: String? = switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        case let object as [String: Any]: object["#text"] as? String
        default: nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Converts XML into nested dictionaries/arrays/strings for key-path lookup.
private final class VendorXMLTreeBuilder: NSObject, XMLParserDelegate {
    private struct Frame {
        let name: String
        var children: [String: Any]
        var text: String
    }

    private var stack: [Frame] = []
    private var root: [String: Any] = [:]

    static func build(_ data: Data) throws -> Any {
        let builder = VendorXMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown error"
            throw UpdaterError.parsing("Invalid vendor XML: \(reason)")
        }
        return builder.root
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        let attributes = Dictionary(uniqueKeysWithValues: attributeDict.map { ("@\($0.key)", $0.value as Any) })
        stack.append(Frame(name: elementName, children: attributes, text: ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard let frame = stack.popLast() else { return }
        let text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Any = frame.children.isEmpty
            ? text
            : frame.children.merging(text.isEmpty ? [:] : ["#text": text]) { current, _ in current }
        if stack.isEmpty {
            root = [frame.name: value]
        } else {
            stack[stack.count - 1].children = Self.adding(value, named: frame.name, to: stack[stack.count - 1].children)
        }
    }

    /// Repeated element names become arrays in document order.
    private static func adding(_ value: Any, named name: String, to children: [String: Any]) -> [String: Any] {
        guard let existing = children[name] else { return children.merging([name: value]) { _, new in new } }
        let combined: [Any] = (existing as? [Any] ?? [existing]) + [value]
        return children.merging([name: combined]) { _, new in new }
    }
}
