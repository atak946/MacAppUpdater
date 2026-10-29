import Foundation
import Testing
@testable import AppUpdater

@Suite("Screenshot mode")
struct ScreenshotModeTests {
    @Test("the argument wins over the environment; a missing or flag-like value is ignored")
    func outputDirectory() {
        let env = [ScreenshotMode.environmentKey: "/tmp/from-env"]
        #expect(ScreenshotMode.outputDirectory(arguments: ["app", "--render-screenshots", "/tmp/out"], environment: env)?.path
            == "/tmp/out")
        #expect(ScreenshotMode.outputDirectory(arguments: ["app"], environment: env)?.path == "/tmp/from-env")
        #expect(ScreenshotMode.outputDirectory(arguments: ["app", "--render-screenshots"], environment: [:]) == nil)
        #expect(ScreenshotMode.outputDirectory(arguments: ["app", "--render-screenshots", "-AppleLanguages"], environment: [:]) == nil)
        #expect(ScreenshotMode.outputDirectory(arguments: ["app"], environment: [:]) == nil)
    }

    @Test("demo data holds nothing from the machine it runs on")
    func fixturesAreGeneric() {
        let user = NSUserName()
        let fullName = NSFullUserName()
        let host = ProcessInfo.processInfo.hostName
        let texts = DemoFixtures.apps.flatMap { [$0.name, $0.bundleID, $0.version] }
            + DemoFixtures.updates.map(\.bundleID)
            + DemoFixtures.history(now: Date()).map(\.appName)
            + DemoMonitorFixtures.processes.map(\.name)
            + DemoMonitorFixtures.usageApps.map(\.name)
            + DemoFixtures.cleanupReport(home: URL(fileURLWithPath: "/demo"), now: Date())
                .groups.flatMap(\.items).map { $0.url.path + $0.displayName }
        for text in texts {
            #expect(!text.localizedCaseInsensitiveContains(user))
            if !fullName.isEmpty { #expect(!text.localizedCaseInsensitiveContains(fullName)) }
            #expect(!text.localizedCaseInsensitiveContains(host))
        }
    }
}
