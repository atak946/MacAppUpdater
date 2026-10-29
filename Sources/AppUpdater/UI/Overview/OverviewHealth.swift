import SwiftUI

/// Health score of the Mac shown by the Overview ring, derived from what still needs attention.
struct OverviewHealth: Equatable {
    let pendingUpdates: Int
    let warnings: Int
    let untrackedApps: Int

    // MARK: Weights

    private static let updatePenalty = 0.08
    private static let maxUpdatePenalty = 0.5
    private static let warningPenalty = 0.04
    private static let maxWarningPenalty = 0.25
    private static let untrackedPenalty = 0.02
    private static let maxUntrackedPenalty = 0.15

    /// 0...1, where 1 means nothing needs attention.
    var score: Double {
        let penalty = min(Double(pendingUpdates) * Self.updatePenalty, Self.maxUpdatePenalty)
            + min(Double(warnings) * Self.warningPenalty, Self.maxWarningPenalty)
            + min(Double(untrackedApps) * Self.untrackedPenalty, Self.maxUntrackedPenalty)
        return max(0, 1 - penalty)
    }

    /// Rounded percentage for display.
    var percent: Int { Int((score * 100).rounded()) }

    var tint: Color {
        switch score {
        case 0.85...: Theme.Palette.success
        case 0.6..<0.85: Theme.Palette.warning
        default: Theme.Palette.danger
        }
    }

    var rating: String {
        switch score {
        case 0.95...: String(localized: "Excellent")
        case 0.85..<0.95: String(localized: "Good")
        case 0.6..<0.85: String(localized: "Needs attention")
        default: String(localized: "At risk")
        }
    }
}
