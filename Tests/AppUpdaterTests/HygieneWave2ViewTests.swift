@testable import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

@Suite struct ReleaseNotesNavigationGateTests {
    private let blank = URL(string: "about:blank")

    @Test("exactly one main-frame load is allowed; a meta refresh before didFinish is cancelled")
    func onlyInitialLoad() {
        var gate = ReleaseNotesNavigationGate()
        #expect(gate.decide(isLinkActivation: false, isOtherNavigation: true, isMainFrame: true, url: blank) == .allowInitialLoad)
        #expect(gate.hasAllowedInitialLoad)
        let refresh = URL(string: "https://tracker.example/next")
        #expect(gate.decide(isLinkActivation: false, isOtherNavigation: true, isMainFrame: true, url: refresh) == .cancel)
        #expect(gate.decide(isLinkActivation: false, isOtherNavigation: true, isMainFrame: true, url: blank) == .cancel)
    }

    @Test("sub-frame and non-'other' navigations never load, even first")
    func subFrameAndOtherTypesCancelled() {
        var gate = ReleaseNotesNavigationGate()
        #expect(gate.decide(isLinkActivation: false, isOtherNavigation: true, isMainFrame: false, url: blank) == .cancel)
        #expect(gate.decide(isLinkActivation: false, isOtherNavigation: false, isMainFrame: true, url: blank) == .cancel)
        #expect(!gate.hasAllowedInitialLoad)
    }

    @Test("clicked links open externally only for http, https and mailto")
    func linkSchemes() throws {
        var gate = ReleaseNotesNavigationGate()
        let https = try #require(URL(string: "https://example.com/notes"))
        let mail = try #require(URL(string: "mailto:a@example.com"))
        let file = try #require(URL(string: "file:///etc/passwd"))
        #expect(gate.decide(isLinkActivation: true, isOtherNavigation: false, isMainFrame: true, url: https) == .openExternally(https))
        #expect(gate.decide(isLinkActivation: true, isOtherNavigation: false, isMainFrame: true, url: mail) == .openExternally(mail))
        #expect(gate.decide(isLinkActivation: true, isOtherNavigation: false, isMainFrame: true, url: file) == .blockedScheme("file"))
        #expect(gate.decide(isLinkActivation: true, isOtherNavigation: false, isMainFrame: true, url: nil) == .cancel)
        #expect(!gate.hasAllowedInitialLoad)
    }

    @Test("the default CSP blocks remote images; the opt-in allows https")
    func contentSecurityPolicy() {
        let strict = ReleaseNotesHTML.wrap("<p>x</p>")
        #expect(strict.contains("img-src data:;"))
        #expect(!strict.contains("https:"))
        let remote = ReleaseNotesHTML.wrap("<p>x</p>", allowsRemoteImages: true)
        #expect(remote.contains("img-src https: data:"))
    }
}

@MainActor
@Suite struct UninstallerManagedGateTests {
    @Test("uninstallPlan and uninstall throw when the organization disables the uninstaller")
    func gateEnforcedInFlow() async {
        let app = Fixtures.app("app")
        let extras = ViewModelExtras(managed: ManagedConfiguration(disableUninstaller: true))
        let viewModel = makeViewModel(updates: [], extras: extras)
        let plan = UninstallPlan(
            app: app,
            bundle: LeftoverItem(url: app.url, kind: .appBundle, sizeInBytes: 0, confidence: .exact),
            leftovers: []
        )

        await #expect(throws: UninstallError.disabledByOrganization) {
            _ = try await viewModel.uninstallPlan(for: app)
        }
        await #expect(throws: UninstallError.disabledByOrganization) {
            _ = try await viewModel.uninstall(plan, selected: [app.url])
        }
    }
}
