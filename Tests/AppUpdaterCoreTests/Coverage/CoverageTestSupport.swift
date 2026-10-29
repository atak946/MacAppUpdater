import Foundation
@testable import AppUpdaterCore

enum CoverageFixtures {
    static func app(
        _ id: String, name: String? = nil, path: String? = nil,
        feed: URL? = nil, appStore: Bool = false
    ) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: id, name: name ?? id,
            url: URL(fileURLWithPath: path ?? "/Applications/\(name ?? id).app"),
            shortVersion: "1.2.3", buildVersion: "42", sparkleFeedURL: feed, isFromAppStore: appStore
        )
    }

    static func result(
        _ app: InstalledApp, source: UpdateSourceKind?, errors: [String] = []
    ) -> UpdateCheckResult {
        UpdateCheckResult(app: app, matchedSource: source, update: nil, errors: errors)
    }
}
