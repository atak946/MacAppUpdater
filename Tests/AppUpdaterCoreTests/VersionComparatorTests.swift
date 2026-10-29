import Testing
import Foundation
@testable import AppUpdaterCore

@Suite struct VersionComparatorTests {
    let comparator = VersionComparator()

    @Test("Candidate is newer", arguments: [
        ("1.10", "1.9"),
        ("2.0.1", "2.0"),
        ("v1.2.3", "1.2.2"),
        ("1.2.0", "1.2.0-beta.1"),
        ("1.2.0-beta.2", "1.2.0-beta.1"),
        ("1.2.0-rc.1", "1.2.0-beta.9"),
        ("1.2.0-beta", "1.2.0-alpha"),
        ("1.0.0-alpha.1", "1.0.0-alpha"),
        ("1.2", "1.2b3"),
        ("1.2b4", "1.2b3"),
        ("1.2rc1", "1.2b3"),
        ("1.2.1", "1.2b3"),
        ("10.0", "9.99.99"),
        ("123456789012345678901", "123456789012345678900"),
    ])
    func isNewer(candidate: String, current: String) {
        #expect(comparator.isNewer(candidate, than: current))
        #expect(!comparator.isNewer(current, than: candidate))
    }

    @Test("Versions are equal", arguments: [
        ("2.0", "2.0.0"),
        ("v1.2.3", "1.2.3"),
        ("1.2.3+build.5", "1.2.3+build.9"),
        ("1.02", "1.2"),
        ("1.2-beta", "1.2.beta"),
        (" 3.1 ", "3.1"),
        ("Build 4215", "4215"),
        ("Version 2.1", "2.1"),
    ])
    func equal(lhs: String, rhs: String) {
        #expect(comparator.compare(lhs, rhs) == .orderedSame)
        #expect(!comparator.isNewer(lhs, than: rhs))
        #expect(!comparator.isNewer(rhs, than: lhs))
    }

    @Test func buildBreaksTieWhenShortVersionsMatch() {
        #expect(comparator.compare(shortVersion: "1.0", build: "42", to: "1.0", build: "41") == .orderedDescending)
        #expect(comparator.compare(shortVersion: "1.0", build: nil, to: "1.0", build: "41") == .orderedSame)
        #expect(comparator.compare(shortVersion: "1.1", build: "1", to: "1.0", build: "99") == .orderedDescending)
    }

    @Test func labelPrefixedVersionsStillOrder() {
        #expect(comparator.isNewer("4216", than: "Build 4215"))
        #expect(!comparator.isNewer("4215", than: "Build 4215"))
        #expect(comparator.isNewer("1.2.0", than: "1.2.0 beta"))
    }
}
