import Foundation

/// Compares human-oriented version strings such as "1.10", "v2.0.0", "1.2.0-beta.1" or "1.2b3".
///
/// Versions are split into numeric and alphabetic tokens (separators are ignored) and compared
/// token by token. Alphabetic tokens denote pre-releases, so "1.2.0-rc.1" < "1.2.0".
/// A leading "v", a leading word label ("Build 4215") and build metadata after "+" are ignored.
public struct VersionComparator: VersionComparing {
    public init() {}

    public func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// Orders `lhs` relative to `rhs` (`.orderedDescending` means `lhs` is newer).
    public func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = Self.tokenize(lhs)
        let right = Self.tokenize(rhs)

        for (leftToken, rightToken) in zip(left, right) {
            let result = Self.compare(leftToken, rightToken)
            if result != .orderedSame { return result }
        }

        if left.count == right.count { return .orderedSame }
        if left.count > right.count {
            return Self.compareRemainder(left.dropFirst(right.count))
        }
        return Self.invert(Self.compareRemainder(right.dropFirst(left.count)))
    }

    /// Compares (CFBundleShortVersionString, CFBundleVersion) pairs.
    /// Builds are only consulted when short versions are equal and both builds are known.
    public func compare(
        shortVersion lhsShort: String,
        build lhsBuild: String?,
        to rhsShort: String,
        build rhsBuild: String?
    ) -> ComparisonResult {
        let shortResult = compare(lhsShort, rhsShort)
        guard shortResult == .orderedSame, let lhsBuild, let rhsBuild else { return shortResult }
        return compare(lhsBuild, rhsBuild)
    }
}

// MARK: - Tokenizing

extension VersionComparator {
    enum Token: Equatable {
        /// Digits with leading zeros stripped; compared by length then lexically to avoid overflow.
        case number(String)
        case text(String)
    }

    static func tokenize(_ version: String) -> [Token] {
        var body = Substring(version.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = body.first, first == "v" || first == "V",
           body.dropFirst().first?.isNumber == true {
            body = body.dropFirst()
        }
        // Drop a leading word label such as "Build 4215" or "Version 2.1".
        if let space = body.firstIndex(where: \.isWhitespace),
           body[..<space].allSatisfy(\.isLetter),
           body[space...].contains(where: \.isNumber) {
            body = body[space...].drop(while: \.isWhitespace)
        }
        if let plus = body.firstIndex(of: "+") {
            body = body[..<plus]
        }

        var tokens: [Token] = []
        var current = ""
        var currentIsNumber = false

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(currentIsNumber ? .number(normalizedNumber(current)) : .text(current.lowercased()))
            current = ""
        }

        for character in body {
            let isDigit = character.isASCII && character.isNumber
            let isLetter = character.isLetter
            guard isDigit || isLetter else {
                flush()
                continue
            }
            if !current.isEmpty && isDigit != currentIsNumber { flush() }
            currentIsNumber = isDigit
            current.append(character)
        }
        flush()
        return tokens
    }

    private static func normalizedNumber(_ digits: String) -> String {
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}

// MARK: - Token comparison

extension VersionComparator {
    /// Known pre-release labels, lowest first. Unknown labels fall back to lexical order.
    private static let preReleaseRanks: [String: Int] = [
        "dev": 0, "snapshot": 0, "nightly": 0,
        "a": 1, "alpha": 1,
        "b": 2, "beta": 2,
        "pre": 3, "preview": 3,
        "c": 4, "rc": 4,
    ]

    static func compare(_ lhs: Token, _ rhs: Token) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.number(left), .number(right)):
            if left.count != right.count {
                return left.count < right.count ? .orderedAscending : .orderedDescending
            }
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case let (.text(left), .text(right)):
            return compareLabels(left, right)
        case (.number, .text):
            // A release component outranks a pre-release label at the same position.
            return .orderedDescending
        case (.text, .number):
            return .orderedAscending
        }
    }

    private static func compareLabels(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = preReleaseRanks[lhs], let right = preReleaseRanks[rhs], left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// Decides how the longer version relates to the shorter one using its extra tokens:
    /// trailing zeros are equal ("2.0" == "2.0.0"), a label means pre-release, otherwise newer.
    private static func compareRemainder(_ remainder: ArraySlice<Token>) -> ComparisonResult {
        for token in remainder {
            switch token {
            case .number("0"): continue
            case .number: return .orderedDescending
            case .text: return .orderedAscending
            }
        }
        return .orderedSame
    }

    private static func invert(_ result: ComparisonResult) -> ComparisonResult {
        switch result {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
