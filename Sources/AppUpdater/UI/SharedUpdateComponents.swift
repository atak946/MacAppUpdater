import AppUpdaterCore
import SwiftUI

/// Icon for the most severe warning; the tooltip lists all of them.
struct WarningBadge: View {
    /// Most severe first.
    let warnings: [AppWarning]

    var body: some View {
        if let top = warnings.first {
            Image(systemName: top.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(InsightsStyle.color(for: top.severity))
                .help(warnings.map(\.title).joined(separator: "\n"))
                .accessibilityLabel(warnings.count == 1 ? top.title : String(localized: "\(warnings.count) warnings"))
        }
    }
}

extension View {
    /// Asks before installing an update with a warning: a newer macOS requirement (destructive)
    /// or a changed download host (informational).
    func compatibilityConfirmation(
        warning: AppWarning?,
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            warning?.title ?? String(localized: "Install anyway?"),
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Install Anyway", role: warning?.severity == .info ? nil : .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let warning {
                Text("\(warning.explanation) \(warning.suggestedAction)")
            }
        }
    }

    /// Asks before restoring the backed-up version (the app is quit while it's replaced).
    func revertConfirmation(
        appName: String,
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Revert \(appName) to the previous version?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(appName) will quit while it's replaced. Its settings and data are not rolled back.")
        }
    }

    /// Shows the view model's last revert/uninstall error.
    func actionErrorAlert(_ viewModel: UpdatesViewModel) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(
                get: { viewModel.actionError != nil },
                set: { if !$0 { viewModel.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.actionError ?? "")
        }
    }
}

/// Uninstall sheet wired to the view model; shared by the detail view and the All Apps table.
@MainActor
func makeUninstallSheet(
    for app: InstalledApp,
    viewModel: UpdatesViewModel,
    onFinished: @escaping (UninstallReport) -> Void = { _ in }
) -> UninstallSheet {
    UninstallSheet(
        app: app,
        icon: viewModel.icon(for: app),
        scan: { try await viewModel.uninstallPlan(for: app) },
        uninstall: { plan, selected in try await viewModel.uninstall(plan, selected: selected) },
        quitApp: { try await viewModel.quit(app) },
        onFinished: { report in
            viewModel.didUninstall(report)
            onFinished(report)
        }
    )
}

extension UpdateCheckResult {
    /// Short label for the source that matched this app, or why none did.
    var sourceLabel: String {
        if let matchedSource { return matchedSource.displayName }
        return errors.isEmpty ? String(localized: "No known source") : String(localized: "Check failed")
    }
}

/// Small capsule identifying where an update comes from; color carries meaning per source.
struct SourceBadge: View {
    let source: UpdateSourceKind

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.15)))
            .fixedSize()
    }

    private var title: String {
        source.displayName
    }

    private var tint: Color {
        switch source {
        case .sparkle: .orange
        case .homebrew: .brown
        case .github: .purple
        case .appStore: .blue
        case .electron: .teal
        case .vendor: .indigo
        }
    }
}

/// "Stay on 5.x" / "Stay on 5.2.x" (D3): updates beyond the prefix are hidden and never auto-installed.
struct VersionCeilingMenu: View {
    let version: String
    let current: String?
    let onSelect: (String?) -> Void

    var body: some View {
        let options = VersionCeilingOptions(version: version)
        Menu("Stay on Version", systemImage: "arrow.down.to.line") {
            Button("Stay on \(options.major).x") { onSelect(options.major) }
            if let minor = options.minor {
                Button("Stay on \(minor).x") { onSelect(minor) }
            }
            if let current {
                Divider()
                Button("Allow Versions Newer Than \(current).x") { onSelect(nil) }
            }
        }
    }
}

/// Small badge for apps whose updates a vendor tool owns (Setapp, Creative Cloud, MAU, …).
struct VendorManagedBadge: View {
    let management: VendorManagement

    var body: some View {
        Label("Managed by \(management.updaterName)", systemImage: "arrow.triangle.2.circlepath.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("\(management.updaterName) manages updates for this app. App Updater won't install them.")
    }
}
