import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

/// In-memory brew: fixed outdated list, per-formula upgrade failures, call log.
final class StubHomebrew: HomebrewFormulaManaging, @unchecked Sendable {
    let isAvailable: Bool
    private let formulae: [OutdatedFormula]
    private let listError: (any Error)?
    private let failing: Set<String>
    private let lock = NSLock()
    private var calls: [String] = []

    init(isAvailable: Bool = true, formulae: [OutdatedFormula] = [], listError: (any Error)? = nil, failing: Set<String> = []) {
        self.isAvailable = isAvailable
        self.formulae = formulae
        self.listError = listError
        self.failing = failing
    }

    var upgraded: [String] { lock.withLock { calls } }

    func outdatedFormulae() async throws -> [OutdatedFormula] {
        if let listError { throw listError }
        return formulae
    }

    func upgrade(_ name: String) async throws {
        lock.withLock { calls.append(name) }
        if failing.contains(name) { throw HomebrewError.invalidFormulaName(name) }
    }
}

@MainActor
@Suite("FormulaeModel")
struct FormulaeModelTests {
    private static func formula(_ name: String, pinned: Bool = false) -> OutdatedFormula {
        OutdatedFormula(name: name, installedVersions: ["1.0"], currentVersion: "2.0", pinned: pinned)
    }

    @Test("reports unavailable when Homebrew is not installed")
    func unavailable() async {
        let model = FormulaeModel(homebrew: StubHomebrew(isAvailable: false))

        await model.refresh()

        #expect(model.state == .unavailable)
        #expect(model.formulae.isEmpty)
    }

    @Test("loads outdated formulae, and surfaces list failures")
    func refresh() async {
        let loaded = FormulaeModel(homebrew: StubHomebrew(formulae: [Self.formula("wget")]))
        let failing = FormulaeModel(homebrew: StubHomebrew(listError: HomebrewError.notInstalled))

        await loaded.refresh()
        await failing.refresh()

        #expect(loaded.state == .loaded)
        #expect(loaded.formulae.map(\.name) == ["wget"])
        #expect(!loaded.isBusy)
        #expect(failing.state == .failed(HomebrewError.notInstalled.localizedDescription))
    }

    @Test("pinned formulae are never upgraded and explain how to unpin")
    func pinnedFormula() async {
        let brew = StubHomebrew()
        let model = FormulaeModel(homebrew: brew)
        let pinned = Self.formula("node", pinned: true)

        await model.upgrade(pinned)

        #expect(brew.upgraded.isEmpty)
        #expect(model.upgradeState(for: pinned) == .failed(HomebrewError.pinned("node").localizedDescription))
    }

    @Test("upgrade records success and failure per formula")
    func upgradeOutcomes() async {
        let brew = StubHomebrew(failing: ["bad"])
        let model = FormulaeModel(homebrew: brew)

        await model.upgrade(Self.formula("good"))
        await model.upgrade(Self.formula("bad"))

        #expect(model.upgradeState(for: Self.formula("good")) == .upgraded)
        #expect(model.upgradeState(for: Self.formula("bad")) == .failed(HomebrewError.invalidFormulaName("bad").localizedDescription))
    }

    @Test("Upgrade All runs sequentially over unpinned, not yet upgraded formulae; refresh resets states")
    func upgradeAll() async {
        let brew = StubHomebrew(formulae: [Self.formula("a"), Self.formula("pinned", pinned: true), Self.formula("b")])
        let model = FormulaeModel(homebrew: brew)
        await model.refresh()
        await model.upgrade(Self.formula("a"))

        #expect(model.upgradable.map(\.name) == ["b"])
        await model.upgradeAll()

        #expect(brew.upgraded == ["a", "b"])
        #expect(model.upgradable.isEmpty)
        #expect(!model.isUpgradingAll)

        await model.refresh()
        #expect(model.upgradeState(for: Self.formula("a")) == nil)
    }
}
