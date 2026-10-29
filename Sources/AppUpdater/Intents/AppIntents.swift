import AppIntents
import Foundation

// Shortcuts and Spotlight actions. They run inside the app process and drive the same models as
// the window, so a check or cleanup started here shows up on screen too.
// The bundle needs Metadata.appintents for these to appear; scripts/build-app.sh extracts it.

/// Failures shown by Shortcuts when an action can't run.
enum AppIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case busy

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "App Updater isn't ready yet. Try again in a moment."
        case .busy: "App Updater is busy with another check or cleanup. Try again when it finishes."
        }
    }
}

@MainActor
private func runningEnvironment() throws -> AppEnvironment {
    guard let environment = AppEnvironment.current else { throw AppIntentError.notRunning }
    return environment
}

/// Joins app names for a dialog ("Arc, Slack and Zoom").
private func nameList(_ names: [String]) -> String {
    names.formatted(.list(type: .and))
}

struct CheckForUpdatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for Updates"
    static let description = IntentDescription("Checks your apps for updates and returns how many are available.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let viewModel = try runningEnvironment().viewModel
        guard !viewModel.isBusy else { throw AppIntentError.busy }
        let updates = await viewModel.refresh()
        if case .failed(let message) = viewModel.state {
            throw IntentFailure(message: message)
        }
        guard !updates.isEmpty else {
            return .result(value: 0, dialog: "All your apps are up to date.")
        }
        let names = nameList(updates.map(\.app.name))
        return .result(value: updates.count, dialog: "\(updates.count) updates available: \(names)")
    }
}

struct UpdateAllAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Update All Apps"
    static let description = IntentDescription(
        "Checks for updates, then installs every update that Update All can install without asking."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let viewModel = try runningEnvironment().viewModel
        guard !viewModel.isBusy else { throw AppIntentError.busy }
        await viewModel.refresh()
        if case .failed(let message) = viewModel.state {
            throw IntentFailure(message: message)
        }
        let summary = await viewModel.installAllSummarized()
        return .result(value: summary.installed.count, dialog: IntentDialog(stringLiteral: Self.text(for: summary)))
    }

    static func text(for summary: InstallAllSummary) -> String {
        var lines: [String] = []
        if !summary.installed.isEmpty {
            lines.append(String(localized: "Updated: \(nameList(summary.installed))"))
        }
        if !summary.needsAction.isEmpty {
            lines.append(String(localized: "Needs your attention: \(nameList(summary.needsAction))"))
        }
        if !summary.failed.isEmpty {
            lines.append(String(localized: "Failed: \(nameList(summary.failed))"))
        }
        if !summary.skipped.isEmpty {
            lines.append(String(localized: "Update in the app: \(nameList(summary.skipped))"))
        }
        return lines.isEmpty ? String(localized: "All your apps are up to date.") : lines.joined(separator: "\n")
    }
}

struct CleanCachesIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Caches"
    static let description = IntentDescription(
        "Moves app, Xcode, simulator and package manager caches to the Trash and returns the bytes freed."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let cleanup = try runningEnvironment().cleanupModel
        guard let result = try await cleanup.cleanUnattended() else { throw AppIntentError.busy }
        let freed = result.reclaimedBytes.formatted(.byteCount(style: .file))
        let dialog: IntentDialog = result.failed.isEmpty
            ? "Freed \(freed)."
            : "Freed \(freed). \(result.failed.count) items couldn't be moved to the Trash."
        return .result(value: Int(clamping: result.reclaimedBytes), dialog: dialog)
    }
}

/// Wraps a model's error message so Shortcuts shows it as is.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
