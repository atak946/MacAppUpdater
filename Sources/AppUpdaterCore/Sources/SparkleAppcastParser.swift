import Foundation

/// A single `<item>` from a Sparkle appcast.
struct SparkleAppcastItem: Sendable, Equatable {
    var version: String?
    var shortVersionString: String?
    var downloadURL: URL?
    var edSignature: String?
    var length: Int64?
    var releaseNotesURL: URL?
    var minimumSystemVersion: String?
    var channel: String?
    /// Inline release notes (`<description>`, usually CDATA HTML).
    var descriptionHTML: String?
    /// `<pubDate>` (RFC 822).
    var publishedAt: Date?

    /// Version used for ordering: build version (`sparkle:version`) first.
    var comparableVersion: String? { version ?? shortVersionString }
    /// Human-facing version.
    var displayVersion: String? { shortVersionString ?? version }
}

/// Parses Sparkle appcast RSS (Sparkle 1 attribute style and Sparkle 2 element style).
enum SparkleAppcastParser {
    static func parse(_ data: Data) throws -> [SparkleAppcastItem] {
        let delegate = AppcastParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown error"
            throw UpdaterError.parsing("Invalid Sparkle appcast: \(reason)")
        }
        return delegate.items
    }
}

private final class AppcastParserDelegate: NSObject, XMLParserDelegate {
    private(set) var items: [SparkleAppcastItem] = []
    private var current: SparkleAppcastItem?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        if elementName == "item" {
            current = SparkleAppcastItem()
        } else if elementName == "enclosure", current != nil, current?.downloadURL == nil {
            applyEnclosure(attributeDict)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard var item = current else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        if elementName == "item" {
            items.append(item)
            current = nil
            return
        }
        Self.apply(element: elementName, value: value, to: &item)
        current = item
    }

    private static func apply(element: String, value: String, to item: inout SparkleAppcastItem) {
        switch element {
        case "sparkle:version":
            item.version = item.version ?? value.nonEmpty
        case "sparkle:shortVersionString":
            item.shortVersionString = item.shortVersionString ?? value.nonEmpty
        case "sparkle:releaseNotesLink":
            item.releaseNotesURL = item.releaseNotesURL ?? value.nonEmpty.flatMap(URL.init(string:))
        case "sparkle:minimumSystemVersion":
            item.minimumSystemVersion = value.nonEmpty
        case "sparkle:channel":
            item.channel = value.nonEmpty
        case "description":
            item.descriptionHTML = item.descriptionHTML ?? value.nonEmpty
        case "pubDate":
            item.publishedAt = item.publishedAt ?? ReleaseDateParser.rfc822(value)
        default:
            break
        }
    }

    private func applyEnclosure(_ attributes: [String: String]) {
        current?.downloadURL = attributes["url"].flatMap(URL.init(string:))
        current?.edSignature = attributes["sparkle:edSignature"]?.nonEmpty
        current?.length = attributes["length"].flatMap(Int64.init)
        if let version = attributes["sparkle:version"]?.nonEmpty {
            current?.version = version
        }
        if let short = attributes["sparkle:shortVersionString"]?.nonEmpty {
            current?.shortVersionString = short
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension SparkleAppcastItem {
    /// Default channel items are always eligible; named channels only when opted in.
    func isOnChannel(in allowedChannels: Set<String>) -> Bool {
        guard let channel else { return true }
        return allowedChannels.contains(channel)
    }

    /// Inline description wins over the remote link.
    var releaseNotes: ReleaseNotes? {
        if let descriptionHTML { return .html(descriptionHTML) }
        return releaseNotesURL.map(ReleaseNotes.remote)
    }
}

/// macOS version requirement check for `sparkle:minimumSystemVersion`.
enum SystemVersionRequirement {
    static func isSatisfied(minimum: String, current: OperatingSystemVersion) -> Bool {
        let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let required = (parts.count > 0 ? parts[0] : 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
        let actual = (current.majorVersion, current.minorVersion, current.patchVersion)
        return actual >= required
    }
}
