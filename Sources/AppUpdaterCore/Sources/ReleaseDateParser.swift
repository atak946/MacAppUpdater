import Foundation

/// Lenient parsing of the release dates published by update feeds.
/// Formatters are created per call (they are cheap here and not `Sendable`).
enum ReleaseDateParser {
    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
    ]

    /// ISO 8601 with or without fractional seconds, or a plain `yyyy-MM-dd` (UTC).
    static func iso8601(_ string: String?) -> Date? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let dayOnly = ISO8601DateFormatter()
        dayOnly.formatOptions = [.withFullDate]
        return dayOnly.date(from: value)
    }

    /// RSS `pubDate` (RFC 822 / RFC 2822), falling back to ISO 8601.
    static func rfc822(_ string: String?) -> Date? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in rfc822Formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return iso8601(value)
    }

    /// Feed-agnostic: tries ISO 8601 first, then RFC 822.
    static func any(_ string: String?) -> Date? {
        iso8601(string) ?? rfc822(string)
    }
}
