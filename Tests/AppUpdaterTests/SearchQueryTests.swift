import Testing
@testable import AppUpdater

@Suite("SearchQuery")
struct SearchQueryTests {
    @Test("an empty or blank query matches everything")
    func emptyMatchesAll() {
        #expect(SearchQuery("").matches("GitHub Desktop"))
        #expect(SearchQuery("   ").isEmpty)
        #expect(SearchQuery("  ").filter([1, 2, 3]) { _ in [nil] } == [1, 2, 3])
    }

    @Test("every term must appear in some field", arguments: [
        ("git desk", true),
        ("desktop com.github", true),
        ("git slack", false),
        ("GITHUB", true),
        ("3.6.11", true),
    ])
    func termsAcrossFields(query: String, expected: Bool) {
        #expect(SearchQuery(query).matches("GitHub Desktop", "com.github.GitHubClient", "3.6.11") == expected)
    }

    @Test("diacritics and case are ignored")
    func diacriticInsensitive() {
        #expect(SearchQuery("guvenlik").matches("Güvenlik"))
        #expect(SearchQuery("ISLEM").matches("İşlemler"))
    }

    @Test("nil fields are skipped")
    func nilFields() {
        #expect(!SearchQuery("x").matches(nil, nil))
        #expect(SearchQuery("x").matches(nil, "x"))
    }
}
