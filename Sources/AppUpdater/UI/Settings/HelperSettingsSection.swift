import AppKit
import AppUpdaterCore
import SwiftUI

/// Registration of the privileged helper. Implemented by `HelperClient`.
protocol HelperManaging: HelperStatusProviding {
    func register() async throws -> HelperStatus
    func unregister() async throws
    func openApprovalSettings()
}

/// Settings section to enable, approve or disable the helper that installs .pkg updates.
struct HelperSettingsSection: View {
    let helper: any HelperManaging
    /// Lets the view model pick up the new status (routing of .pkg installs).
    let onStatusChange: () -> Void

    @State private var status: HelperStatus?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            LabeledContent("Privileged helper") {
                Label(statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(statusTint)
            }
            controls
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Installer packages")
        } footer: {
            Text("With the helper enabled, .pkg updates install without opening Installer.app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch status {
        case .enabled:
            Button("Disable Helper") { perform { try await helper.unregister() } }
        case .requiresApproval:
            Text("Allow “App Updater” in System Settings → General → Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Login Items…") { helper.openApprovalSettings() }
        case .notRegistered:
            Button("Enable Helper…") { perform { try await register() } }
        case .notFound:
            Text("The helper is only available in the packaged App Updater.app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private func register() async throws {
        if try await helper.register() == .requiresApproval {
            helper.openApprovalSettings()
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    private func refresh() async {
        status = await helper.status
        onStatusChange()
    }

    private var statusTitle: String {
        switch status {
        case .enabled: String(localized: "Enabled")
        case .requiresApproval: String(localized: "Needs approval")
        case .notRegistered: String(localized: "Off")
        case .notFound: String(localized: "Not available")
        case nil: String(localized: "Checking…")
        }
    }

    private var statusSymbol: String {
        switch status {
        case .enabled: "checkmark.shield.fill"
        case .requiresApproval: "exclamationmark.shield.fill"
        default: "shield.slash"
        }
    }

    private var statusTint: Color {
        switch status {
        case .enabled: .green
        case .requiresApproval: .orange
        default: .secondary
        }
    }
}
