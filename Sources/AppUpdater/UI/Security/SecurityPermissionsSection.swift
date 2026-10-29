import AppKit
import MaintenanceCore
import SwiftUI

/// Privacy permissions grouped by service, or a Full Disk Access notice when TCC is unreadable.
struct SecurityPermissionsSection: View {
    let model: SecurityModel
    let searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(eyebrow: String(localized: "PRIVACY"), title: String(localized: "App permissions"))
            if model.needsFullDiskAccess {
                SecurityAccessNotice(onReturn: model.refreshPermissions)
            } else if model.permissions != nil {
                groups
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may grant Full Disk Access in System Settings and come back.
            if model.needsFullDiskAccess { model.refreshPermissions() }
        }
    }

    @ViewBuilder
    private var groups: some View {
        let groups = model.permissionGroups(matching: searchText)
        if groups.isEmpty {
            Text(searchText.isEmpty
                ? String(localized: "No apps have asked for these permissions.")
                : String(localized: "No apps match “\(searchText)”."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 60)
                .surface(.inset, radius: Theme.Radius.m)
        } else {
            ForEach(groups) { group in
                PermissionGroupCard(group: group, model: model)
            }
        }
    }
}

/// One service: header with a deep link, then a row per app.
private struct PermissionGroupCard: View {
    let group: SecurityModel.PermissionGroup
    let model: SecurityModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                IconTile(symbol: group.service.symbol, tint: group.service.tint, size: 26)
                Text(group.service.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("\(group.entries.count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Button("Open Privacy Settings") { SecurityModel.open(group.service.settingsURL) }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
            }
            VStack(spacing: 0) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { GlassDivider(leadingInset: 34) }
                    PermissionRow(entry: entry, icon: model.icon(for: entry))
                }
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.raised, radius: Theme.Radius.m)
    }
}

/// App icon, name, flags and Allowed/Denied.
private struct PermissionRow: View {
    let entry: PermissionEntry
    let icon: NSImage

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(entry.appURL == nil ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.appName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            ForEach(entry.flags.sorted { $0.rawValue < $1.rawValue }, id: \.self) { flag in
                StatusPill(title: flag.title, tint: Theme.Palette.warning)
            }
            StatusPill(
                title: entry.isAllowed ? String(localized: "Allowed") : String(localized: "Denied"),
                symbol: entry.isAllowed ? "checkmark" : "xmark",
                tint: entry.isAllowed ? Theme.Palette.success : Theme.Palette.textTertiary
            )
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String? {
        if let lastUsed = entry.lastUsed {
            return String(localized: "Last opened \(lastUsed.formatted(.relative(presentation: .named)))")
        }
        return entry.appName == entry.client ? nil : entry.client
    }
}

/// Inline card asking for Full Disk Access, which reading the permission databases requires.
private struct SecurityAccessNotice: View {
    let onReturn: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            IconTile(symbol: "lock.shield.fill", tint: Theme.Palette.warning, size: 26)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Full Disk Access needed to list app permissions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("macOS keeps privacy permissions in a protected database. Grant access, then come back to App Updater.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Spacing.s) {
                    Button("Open Privacy Settings…", action: FullDiskAccess.openSettings)
                        .buttonStyle(.secondary)
                    Button("Check Again", action: onReturn)
                        .buttonStyle(.secondary)
                }
                .controlSize(.small)
                .padding(.top, Theme.Spacing.xxs)
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.inset, radius: Theme.Radius.m)
    }
}
