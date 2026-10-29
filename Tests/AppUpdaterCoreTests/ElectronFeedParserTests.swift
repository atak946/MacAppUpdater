import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("ElectronYAMLParser")
struct ElectronYAMLParserTests {
    @Test("parses maps, indented and same-indent lists, quoting and comments")
    func parsesStructure() throws {
        let yaml = """
        # comment
        ---
        name: 'It''s "fine"'
        quoted: "a\\"b\\n"
        plain: value # trailing comment
        url: https://example.com/a:b
        files:
          - url: A.zip
            size: 12
          - plain item
        same:
        - one
        - "two: x"
        nested:
          inner:
            deep: yes
        empty:
        """
        let root = try ElectronYAMLParser.parse(yaml)
        #expect(root["name"]?.string == "It's \"fine\"")
        #expect(root["quoted"]?.string == "a\"b\n")
        #expect(root["plain"]?.string == "value")
        #expect(root["url"]?.string == "https://example.com/a:b")
        let files = try #require(root["files"]?.list)
        #expect(files.count == 2)
        #expect(files[0]["url"]?.string == "A.zip")
        #expect(files[0]["size"]?.string == "12")
        #expect(files[1].string == "plain item")
        #expect(root["same"]?.list == [.scalar("one"), .scalar("two: x")])
        #expect(root["nested"]?["inner"]?["deep"]?.string == "yes")
        #expect(root["empty"]?.string == nil)
    }

    @Test("parses literal and folded block scalars")
    func blockScalars() throws {
        let yaml = """
        literal: |
          line one
            indented
        
          # not a comment
        folded: >-
          a
          b
        after: done
        """
        let root = try ElectronYAMLParser.parse(yaml)
        #expect(root["literal"]?.string == "line one\n  indented\n\n# not a comment\n")
        #expect(root["folded"]?.string == "a b")
        #expect(root["after"]?.string == "done")
    }

    @Test("rejects lines that are not key/value pairs")
    func rejectsGarbage() {
        #expect(throws: UpdaterError.self) { try ElectronYAMLParser.parse("just text\nmore") }
    }

    @Test("rejects excessive nesting")
    func rejectsDeepNesting() {
        let yaml = (0..<40).map { String(repeating: " ", count: $0 * 2) + "k\($0):" }.joined(separator: "\n")
            + "\n" + String(repeating: " ", count: 80) + "leaf: 1"
        #expect(throws: UpdaterError.self) { try ElectronYAMLParser.parse(yaml) }
    }
}

@Suite("ElectronFeedParser")
struct ElectronFeedParserTests {
    static let latestMac = """
    version: 2.3.0
    files:
      - url: Example-2.3.0-arm64-mac.zip
        sha512: 'YXJt'
        size: 1000
        blockMapSize: 10
      - url: Example-2.3.0-mac.zip
        sha512: aW50ZWw=
        size: 1100
      - url: Example-2.3.0.dmg
        sha512: ZG1n
    path: Example-2.3.0-mac.zip
    sha512: aW50ZWw=
    releaseDate: '2024-05-01T10:20:30.123Z'
    releaseNotes: |
      ## Changes
      - Fixed things
    """

    @Test("parses latest-mac.yml")
    func parsesFeed() throws {
        let feed = try ElectronFeedParser.parseFeed(Data(Self.latestMac.utf8))
        #expect(feed.version == "2.3.0")
        #expect(feed.files.count == 3)
        #expect(feed.files[0] == ElectronFeedFile(url: "Example-2.3.0-arm64-mac.zip", sha512: "YXJt", size: 1000))
        #expect(feed.allFiles.count == 3)
        #expect(feed.releaseNotes == "## Changes\n- Fixed things")
        let date = try #require(feed.releaseDate)
        #expect(abs(date.timeIntervalSince1970 - 1_714_558_830.123) < 0.01)
    }

    @Test("legacy path-only feed and list-style release notes")
    func legacyFeed() throws {
        let yaml = """
        version: v1.0.1
        path: App-1.0.1-mac.zip
        sha512: c2hh
        releaseNotes:
          - version: 1.0.1
            note: Second
          - version: 1.0.0
            note: First
        """
        let feed = try ElectronFeedParser.parseFeed(Data(yaml.utf8))
        #expect(feed.version == "1.0.1")
        #expect(feed.allFiles == [ElectronFeedFile(url: "App-1.0.1-mac.zip", sha512: "c2hh", size: nil)])
        #expect(feed.releaseNotes == "Second\n\nFirst")
    }

    @Test("feed without version is a parsing error")
    func missingVersion() {
        #expect(throws: UpdaterError.self) { try ElectronFeedParser.parseFeed(Data("path: a.zip".utf8)) }
    }

    @Test("builds feed URLs from app-update.yml providers", arguments: [
        ("provider: github\nowner: acme\nrepo: tool\n", "https://github.com/acme/tool/releases/latest/download/latest-mac.yml"),
        ("owner: \"acme\"\nrepo: 'tool'\nprovider: github\nchannel: beta\n", "https://github.com/acme/tool/releases/latest/download/beta-mac.yml"),
        ("provider: generic\nurl: https://updates.example.com/app/\n", "https://updates.example.com/app/latest-mac.yml"),
        ("provider: generic\nurl: https://updates.example.com/app\n", "https://updates.example.com/app/latest-mac.yml"),
        ("provider: s3\nbucket: my-bucket\npath: releases/mac\n", "https://my-bucket.s3.amazonaws.com/releases/mac/latest-mac.yml"),
        ("provider: s3\nbucket: my.bucket\nregion: eu-west-1\n", "https://s3-eu-west-1.amazonaws.com/my.bucket/latest-mac.yml"),
        ("provider: s3\nbucket: my.bucket\nregion: us-east-1\n", "https://s3.amazonaws.com/my.bucket/latest-mac.yml"),
        ("provider: s3\nbucket: b\nregion: cn-north-1\n", "https://b.s3.cn-north-1.amazonaws.com.cn/latest-mac.yml"),
        ("provider: s3\nbucket: b\nendpoint: https://minio.example.com\n", "https://minio.example.com/b/latest-mac.yml"),
        ("provider: s3\nbucket: b\naccelerate: true\n", "https://b.s3-accelerate.amazonaws.com/latest-mac.yml"),
        ("provider: spaces\nname: space\nregion: nyc3\npath: /app\n", "https://space.nyc3.digitaloceanspaces.com/app/latest-mac.yml"),
    ])
    func feedURLs(config: String, expected: String) throws {
        #expect(try ElectronFeedParser.feedURL(fromUpdateConfig: Data(config.utf8))?.absoluteString == expected)
    }

    @Test("unsupported or unsafe providers yield nil", arguments: [
        "provider: snap\n",
        "provider: keygen\naccount: x\n",
        "provider: generic\nurl: http://insecure.example.com\n",
        "provider: generic\nurl: https://example.com/${channel}\n",
        "provider: github\nowner: ../evil\nrepo: tool\n",
        "provider: github\nowner: acme\nrepo: tool\nhost: evil.com/x\n",
        "provider: s3\nbucket: my.bucket\n",
        "provider: s3\nbucket: b\nendpoint: http://minio.local\n",
        "provider: s3\nbucket: b\npath: ../../etc\n",
        "owner: acme\nrepo: tool\n",
    ])
    func unsupportedProviders(config: String) throws {
        #expect(try ElectronFeedParser.feedURL(fromUpdateConfig: Data(config.utf8)) == nil)
    }
}
