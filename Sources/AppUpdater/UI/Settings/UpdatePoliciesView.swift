import AppKit
import AppUpdaterCore
import SwiftUI

/// Settings for unattended installs: a global toggle, soak period, install conditions
/// and per-app overrides.
///
/// Stateless with respect to persistence: the caller owns `UpdatePolicies` and saves
/// whatever `onChange` hands back (e.g. via `UserDefaultsUpdatePoliciesStore`).
struct UpdatePoliciesView: View {
    let policies: UpdatePolicies
    let installedApps: [InstalledApp]
    let icon: (InstalledApp) -> NSImage
    /// Administrator-forced values: their controls are disabled and show a lock.
    var managed: ManagedConfiguration = .unmanaged
    let onChange: (UpdatePolicies) -> Void

    @State private var searchText = ""

    var body: some View {
        Form {
            if managed.isManaged {
                Section { ManagedByOrganizationBanner() }
            }
            Section {
                Toggle("Install updates automatically", isOn: globalBinding)
                    .managedLock(managed.isDefaultPolicyLocked)
                Text("Applies to apps updated from a disk image or zip. App Store apps and installer packages always ask first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DeferralSection(policies: policies, isLocked: managed.isManaged(.deferralDays), onChange: onChange)
            InstallConditionsSection(
                conditions: policies.conditions,
                managed: managed,
                onChange: { onChange(policies.settingConditions($0)) }
            )
            Section {
                TextField("Filter apps", text: $searchText, prompt: Text("Filter apps"))
                    .textFieldStyle(.roundedBorder)
                ForEach(filteredApps) { app in
                    PolicyOverrideRow(
                        app: app,
                        icon: icon(app),
                        selection: overrideBinding(for: app.bundleIdentifier),
                        defaultPolicy: policies.defaultPolicy,
                        allowsAutoInstall: !managed.isAutoInstallDisabled
                            || managed.isPolicyLocked(for: app.bundleIdentifier)
                    )
                    .managedLock(managed.isPolicyLocked(for: app.bundleIdentifier))
                }
            } header: {
                Text("Per-app")
            } footer: {
                if filteredApps.isEmpty {
                    Text(installedApps.isEmpty ? String(localized: "No apps scanned yet.") : String(localized: "No matching apps."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var filteredApps: [InstalledApp] {
        let eligible = installedApps.filter { !$0.isFromAppStore }
        let matching = searchText.isEmpty
            ? eligible
            : eligible.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        // Overridden apps first so the user sees their choices without scrolling.
        return matching.sorted { lhs, rhs in
            let lhsOverride = policies.hasOverride(for: lhs.bundleIdentifier)
            let rhsOverride = policies.hasOverride(for: rhs.bundleIdentifier)
            if lhsOverride != rhsOverride { return lhsOverride }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var globalBinding: Binding<Bool> {
        Binding(
            get: { policies.defaultPolicy == .autoInstall },
            set: { onChange(policies.settingDefault($0 ? .autoInstall : .notifyOnly)) }
        )
    }

    private func overrideBinding(for bundleIdentifier: String) -> Binding<UpdatePolicy?> {
        Binding(
            get: { policies.overrides[bundleIdentifier] },
            set: { onChange(policies.setting($0, for: bundleIdentifier)) }
        )
    }
}

private struct PolicyOverrideRow: View {
    let app: InstalledApp
    let icon: NSImage
    @Binding var selection: UpdatePolicy?
    let defaultPolicy: UpdatePolicy
    /// False when the organization turned automatic installs off (MDM kill switch).
    var allowsAutoInstall = true

    private var choices: [UpdatePolicy] {
        UpdatePolicy.allCases.filter { allowsAutoInstall || $0 != .autoInstall }
    }

    var body: some View {
        Picker(selection: $selection) {
            Text("Default (\(defaultPolicy.title))").tag(UpdatePolicy?.none)
            Divider()
            ForEach(choices, id: \.self) { policy in
                Text(policy.title).tag(UpdatePolicy?.some(policy))
            }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                Text(app.name).lineLimit(1)
                if selection != nil {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.tint)
                        .help("Overrides the default")
                }
            }
        }
    }
}

extension UpdatePolicy {
    var title: String {
        switch self {
        case .notifyOnly: String(localized: "Notify only")
        case .autoInstall: String(localized: "Install automatically")
        }
    }
}

/// Global soak period (B2): wait N days after a release before installing unattended.
private struct DeferralSection: View {
    let policies: UpdatePolicies
    var isLocked = false
    let onChange: (UpdatePolicies) -> Void

    var body: some View {
        Section {
            Stepper(value: daysBinding, in: 0...UpdatePolicies.maxDeferralDays) {
                LabeledContent("Wait after release", value: label(for: policies.deferralDays))
            }
            .managedLock(isLocked)
            Text("Gives a new release time to prove itself before it installs unattended. When a source publishes no release date, the day the update was first seen is used.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Soak period")
        }
    }

    private var daysBinding: Binding<Int> {
        Binding(
            get: { policies.deferralDays },
            set: { onChange(policies.settingDeferralDays($0)) }
        )
    }

    private func label(for days: Int) -> String {
        switch days {
        case 0: String(localized: "Install immediately")
        case 1: String(localized: "1 day")
        default: String(localized: "\(days) days")
        }
    }
}

/// Conditions (C3) every unattended install must meet.
private struct InstallConditionsSection: View {
    let conditions: InstallConditions
    var managed: ManagedConfiguration = .unmanaged
    let onChange: (InstallConditions) -> Void

    private static let defaultQuietHours = QuietHours(startHour: 22, endHour: 8)

    var body: some View {
        Section {
            Toggle("Only on AC power", isOn: toggle(\.requireACPower) { conditions.with(requireACPower: $0) })
                .managedLock(managed.isManaged(.requireACPower))
            Toggle("Not on expensive networks (hotspot, cellular)",
                   isOn: toggle(\.avoidExpensiveNetwork) { conditions.with(avoidExpensiveNetwork: $0) })
                .managedLock(managed.isManaged(.avoidExpensiveNetwork))
            Toggle("Not in Low Data Mode",
                   isOn: toggle(\.avoidConstrainedNetwork) { conditions.with(avoidConstrainedNetwork: $0) })
            Toggle("Skip apps that are running", isOn: toggle(\.skipRunningApps) { conditions.with(skipRunningApps: $0) })
            Toggle("Quiet hours", isOn: quietHoursEnabled)
            if let quiet = conditions.quietHours {
                HourPicker(title: "From", hour: quiet.startHour) {
                    onChange(conditions.withQuietHours(QuietHours(startHour: $0, endHour: quiet.endHour)))
                }
                HourPicker(title: "Until", hour: quiet.endHour) {
                    onChange(conditions.withQuietHours(QuietHours(startHour: quiet.startHour, endHour: $0)))
                }
            }
        } header: {
            Text("Conditions")
        } footer: {
            Text("Updates that do not meet these conditions wait for the next check.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func toggle(
        _ keyPath: KeyPath<InstallConditions, Bool>,
        update: @escaping (Bool) -> InstallConditions
    ) -> Binding<Bool> {
        Binding(get: { conditions[keyPath: keyPath] }, set: { onChange(update($0)) })
    }

    private var quietHoursEnabled: Binding<Bool> {
        Binding(
            get: { conditions.quietHours != nil },
            set: { onChange(conditions.withQuietHours($0 ? Self.defaultQuietHours : nil)) }
        )
    }
}

private struct HourPicker: View {
    let title: LocalizedStringKey
    let hour: Int
    let onSelect: (Int) -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { hour }, set: { onSelect($0) })) {
            ForEach(0..<24, id: \.self) { value in
                Text(Self.label(for: value)).tag(value)
            }
        }
    }

    private static func label(for hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
