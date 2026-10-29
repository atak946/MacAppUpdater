import AppUpdaterCore
import os
import ServiceManagement
import SwiftUI

enum SettingsKeys {
    static let checkIntervalHours = "checkIntervalHours"
    static let defaultCheckIntervalHours: Double = 6
}

struct SettingsView: View {
    /// Invoked with the new interval in hours so the scheduler can be reconfigured.
    let onIntervalChange: (Double) -> Void
    let helper: any HelperManaging
    let onHelperStatusChange: () -> Void
    var managed: ManagedConfiguration = .unmanaged
    /// Records UI writes of the notarization toggle; nil in previews.
    var notarizationAudit: NotarizationSettingAudit?
    /// Launch-time result of `NotarizationSettingAudit.wasChangedOutsideApp`.
    var notarizationChangedExternally = false

    @AppStorage(SettingsKeys.checkIntervalHours)
    private var intervalHours: Double = SettingsKeys.defaultCheckIntervalHours
    /// Off (default) = `NotarizationPolicy.require`; read by `AppInstaller` on every install.
    @AppStorage(NotarizationPolicy.allowUnnotarizedDefaultsKey)
    private var allowUnnotarized = false

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var isExternalChangeDismissed = false

    private static let intervalOptions: [Double] = [1, 3, 6, 12, 24]
    private let logger = Logger(subsystem: "com.macappupdater", category: "Settings")

    var body: some View {
        Form {
            if managed.isManaged {
                Section { ManagedByOrganizationBanner() }
            }
            Section("Checking") {
                intervalPicker
                Text("macOS may shift checks slightly to save energy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                if let launchError {
                    Label(launchError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Security") {
                if notarizationChangedExternally && !isExternalChangeDismissed {
                    SecuritySettingChangedBanner(
                        isEnabled: allowUnnotarized,
                        onKeep: confirmExternalChange,
                        onTurnOff: { setAllowUnnotarized(false) }
                    )
                }
                notarizationToggle
                Text("Off (recommended): updates Apple hasn't notarized are blocked. On: they install with a warning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HelperSettingsSection(helper: helper, onStatusChange: onHelperStatusChange)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: intervalHours) { _, newValue in onIntervalChange(newValue) }
        .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
    }

    /// Locked off when MDM forces `RequireNotarization`. Writes go through the audit so
    /// only changes made here count as confirmed (see `NotarizationSettingAudit`).
    @ViewBuilder
    private var notarizationToggle: some View {
        let gate = ManagedPolicyGate(configuration: managed)
        let toggle = Toggle(
            "Allow updates that aren't notarized (warn)",
            isOn: Binding(
                get: { gate.effectiveAllowUnnotarized(userValue: allowUnnotarized) },
                set: setAllowUnnotarized
            )
        )
        toggle.managedLock(gate.isNotarizationLocked)
    }

    private func setAllowUnnotarized(_ value: Bool) {
        if let notarizationAudit {
            notarizationAudit.recordUserChange(value)
        } else {
            allowUnnotarized = value
        }
        isExternalChangeDismissed = true
    }

    private func confirmExternalChange() {
        notarizationAudit?.confirmStoredValue()
        isExternalChangeDismissed = true
    }

    /// Shows the forced interval (locked) when a configuration profile sets one.
    @ViewBuilder
    private var intervalPicker: some View {
        let gate = ManagedPolicyGate(configuration: managed)
        if gate.isCheckIntervalLocked {
            let forced = gate.effectiveCheckInterval(userValue: intervalHours)
            LabeledContent("Check for updates", value: label(forHours: forced))
                .managedLock(true)
        } else {
            Picker("Check for updates", selection: $intervalHours) {
                ForEach(Self.intervalOptions, id: \.self) { hours in
                    Text(label(forHours: hours)).tag(hours)
                }
            }
        }
    }

    private func label(forHours hours: Double) -> String {
        switch hours {
        case 1: String(localized: "Every hour")
        case 24: String(localized: "Once a day")
        default: hours == hours.rounded() ? String(localized: "Every \(Int(hours)) hours") : String(localized: "Every \(hours.formatted()) hours")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let isEnabled = service.status == .enabled
        guard enabled != isEnabled else {
            launchError = nil
            return
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchError = nil
        } catch {
            logger.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            launchError = error.localizedDescription
            launchAtLogin = service.status == .enabled
        }
    }
}

/// Shown once per launch when the notarization toggle was changed outside App Updater.
/// Until the user keeps the value, the installer treats it as off.
private struct SecuritySettingChangedBanner: View {
    let isEnabled: Bool
    let onKeep: () -> Void
    let onTurnOff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Security setting changed outside App Updater", systemImage: "exclamationmark.shield.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("“Allow updates that aren't notarized” was changed by another program. Until you confirm it here, notarization stays required.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if isEnabled {
                    Button("Turn Off", action: onTurnOff)
                    Button("Keep Allowed", action: onKeep)
                } else {
                    Button("OK", action: onKeep)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}
