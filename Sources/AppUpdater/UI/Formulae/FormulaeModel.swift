import AppUpdaterCore
import Observation
import os

/// Drives the "Command Line Tools" screen: outdated Homebrew formulae and their upgrades.
@MainActor
@Observable
final class FormulaeModel {
    enum State: Equatable {
        case idle
        case unavailable
        case loading
        case loaded
        case failed(String)
    }

    enum UpgradeState: Equatable {
        case upgrading
        case upgraded
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var formulae: [OutdatedFormula] = []
    private(set) var upgradeStates: [OutdatedFormula.ID: UpgradeState] = [:]
    private(set) var isUpgradingAll = false

    private let homebrew: any HomebrewFormulaManaging
    private let logger = Logger(subsystem: "com.macappupdater", category: "FormulaeModel")

    init(homebrew: any HomebrewFormulaManaging = HomebrewCLI()) {
        self.homebrew = homebrew
    }

    var isBusy: Bool {
        state == .loading || isUpgradingAll || upgradeStates.values.contains(.upgrading)
    }

    /// Formulae that can still be upgraded (not pinned, not already done).
    var upgradable: [OutdatedFormula] {
        formulae.filter { !$0.pinned && upgradeStates[$0.id] != .upgraded }
    }

    func upgradeState(for formula: OutdatedFormula) -> UpgradeState? {
        upgradeStates[formula.id]
    }

    func refresh() async {
        guard homebrew.isAvailable else {
            state = .unavailable
            return
        }
        state = .loading
        do {
            formulae = try await homebrew.outdatedFormulae()
            upgradeStates = [:]
            state = .loaded
        } catch {
            logger.error("brew outdated failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func upgrade(_ formula: OutdatedFormula) async {
        guard upgradeStates[formula.id] != .upgrading else { return }
        guard !formula.pinned else {
            setUpgradeState(.failed(HomebrewError.pinned(formula.name).localizedDescription), for: formula)
            return
        }
        setUpgradeState(.upgrading, for: formula)
        do {
            try await homebrew.upgrade(formula.name)
            setUpgradeState(.upgraded, for: formula)
        } catch {
            logger.error("brew upgrade \(formula.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            setUpgradeState(.failed(error.localizedDescription), for: formula)
        }
    }

    /// Upgrades sequentially: brew holds a global lock, parallel runs would just fail.
    func upgradeAll() async {
        guard !isUpgradingAll else { return }
        isUpgradingAll = true
        defer { isUpgradingAll = false }
        for formula in upgradable {
            await upgrade(formula)
        }
    }

    private func setUpgradeState(_ newState: UpgradeState, for formula: OutdatedFormula) {
        upgradeStates = upgradeStates.merging([formula.id: newState]) { _, new in new }
    }
}
