import AppKit
import AppUpdaterCore
import SwiftUI

/// Hero for the uninstall sheet: glowing app icon, gradient name and the current step.
struct UninstallHeader: View {
    let app: InstalledApp
    let icon: NSImage
    /// Glow color behind the icon (the icon's dominant color).
    var tint: Color = Theme.Palette.danger
    let subtitle: String
    /// Team ID from a valid code signature, once the scan has checked it.
    var teamIdentifier: String?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.l + 4) {
            HeroAppIcon(image: icon, tint: tint)
            VStack(alignment: .leading, spacing: Theme.Spacing.s - 2) {
                Text(app.name)
                    .font(Theme.Typography.display)
                    .tracking(Theme.Typography.displayTracking)
                    .foregroundStyle(Theme.textGradient)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: Theme.Spacing.s) {
                    StatusPill(title: subtitle, symbol: "trash", tint: Theme.Palette.danger)
                    if let teamIdentifier {
                        Text("Team ID: \(teamIdentifier)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .textSelection(.enabled)
                    }
                }
                Text(app.bundleIdentifier)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Scanning state: a spinning danger orb while related files are collected.
struct UninstallScanningView: View {
    let appName: String

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            ScanOrb(tint: Theme.Palette.danger, isActive: true, diameter: 120) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.textGradient)
            }
            VStack(spacing: Theme.Spacing.s) {
                Text("Looking for related files…")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.textGradient)
                Text("Caches, preferences and support files left behind by \(appName).")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Tinted rounded banner, same look as the detail view's update banner.
struct UninstallBanner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(symbol: symbol, tint: tint, size: 28, glows: true)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.s)
            actions()
                .buttonStyle(.secondary(tint: tint))
                .controlSize(.small)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).fill(tint.opacity(0.10)))
        .surface(.raised)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(tint.opacity(0.28)))
    }
}

/// Hero of the ready state: the space the selection frees as a big gradient numeral inside
/// a glowing orb whose ring fills with the share of selected items.
struct UninstallReclaimSummary: View {
    let bytes: Int64
    let selectedCount: Int
    let totalCount: Int

    private var share: Double { totalCount == 0 ? 0 : Double(selectedCount) / Double(totalCount) }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.xl) {
            ScanOrb(tint: Theme.Palette.danger, diameter: 136, progress: share) {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .font(Theme.Typography.numeral(24))
                    .foregroundStyle(selectedCount == 0 ? AnyShapeStyle(Theme.Palette.textTertiary) : AnyShapeStyle(Theme.textGradient))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 92)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("RECLAIMABLE")
                    .font(Theme.Typography.eyebrow)
                    .tracking(1.4)
                    .foregroundStyle(Theme.Palette.textTertiary)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s - 2) {
                    Text("\(selectedCount)")
                        .font(Theme.Typography.numeral(44))
                        .foregroundStyle(Theme.textGradient)
                        .contentTransition(.numericText())
                    Text("of \(totalCount)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Text("\(selectedCount) of \(totalCount) items selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RadialGradient(colors: [Theme.Palette.danger.opacity(0.18), .clear], center: .leading, startRadius: 0, endRadius: 260)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        )
        .surface(.elevated, radius: Theme.Radius.xl)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(selectedCount) of \(totalCount) items selected"))
        .accessibilityValue(Text(bytes.formatted(.byteCount(style: .file))))
        .animation(Theme.Motion.content, value: bytes)
        .animation(Theme.Motion.content, value: selectedCount)
    }
}

/// Checkbox groups: app bundle, exact matches, then "possible matches" (unchecked by default).
struct UninstallItemList: View {
    let plan: UninstallPlan
    @Binding var selection: Set<URL>
    let isDisabled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l + 2) {
                group(String(localized: "Application"), items: [plan.bundle])
                let exact = plan.leftovers.filter { $0.confidence == .exact }
                if !exact.isEmpty {
                    group(String(localized: "Related files"), items: exact)
                }
                let possible = plan.leftovers.filter { $0.confidence == .possible }
                if !possible.isEmpty {
                    group(
                        String(localized: "Possible matches"),
                        items: possible,
                        footer: String(localized: "Named after the app, not its identifier. Review before selecting.")
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
        }
        .disabled(isDisabled)
    }

    private func group(_ title: String, items: [LeftoverItem], footer: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(Theme.Typography.eyebrow)
                    .tracking(1.4)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                if items.count > 1 {
                    groupToggle(items)
                }
            }
            .padding(.horizontal, Theme.Spacing.xs)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        GlassDivider(leadingInset: 66)
                    }
                    UninstallItemRow(item: item, isOn: binding(for: item.url))
                }
            }
            .padding(Theme.Spacing.xs)
            .surface(.raised)
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }

    /// "Select All" / "Deselect All" for a group.
    private func groupToggle(_ items: [LeftoverItem]) -> some View {
        let urls = Set(items.map(\.url))
        let allSelected = urls.isSubset(of: selection)
        return Button(allSelected ? String(localized: "Deselect All") : String(localized: "Select All")) {
            selection = allSelected ? selection.subtracting(urls) : selection.union(urls)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Theme.Palette.brandTertiary)
    }

    private func binding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { selection.contains(url) },
            set: { isOn in selection = isOn ? selection.union([url]) : selection.subtracting([url]) }
        )
    }
}

/// One checkbox row: kind tile, path and size; hover highlight, whole row toggles.
private struct UninstallItemRow: View {
    let item: LeftoverItem
    @Binding var isOn: Bool

    @State private var isHovered = false

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Theme.Spacing.m - 2) {
                IconTile(symbol: symbol(for: item.kind), tint: tint, size: 24)
                    .saturation(isOn ? 1 : 0.2)
                    .opacity(isOn ? 1 : 0.7)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(item.kind.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(item.url.path)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.url.path)
                }
                Spacer(minLength: Theme.Spacing.s)
                Text(item.sizeInBytes.formatted(.byteCount(style: .file)))
                    .font(Theme.Typography.numeral(12.5))
                    .foregroundStyle(isOn ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(GlassCheckboxStyle())
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.s - 1)
        .hoverHighlight(isHovered, radius: Theme.Radius.m)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isOn)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    private var tint: Color {
        if item.kind == .appBundle { return Theme.Palette.brand }
        return item.confidence == .possible ? Theme.Palette.warning : Theme.Palette.brandTertiary
    }

    private func symbol(for kind: LeftoverItem.Kind) -> String {
        switch kind {
        case .appBundle: "app.badge"
        case .caches: "internaldrive"
        case .preferences, .byHostPreferences: "gearshape"
        case .container, .groupContainer: "shippingbox"
        case .logs: "doc.text"
        case .launchAgent: "bolt.horizontal"
        case .cookies, .httpStorage, .webKit: "globe"
        case .savedState: "macwindow"
        case .applicationSupport: "folder"
        }
    }
}

/// Glass checkbox: hollow rounded square that fills with the danger gradient and glows when on.
private struct GlassCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: Theme.Spacing.m - 2) {
                Box(isOn: configuration.isOn)
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }

    private struct Box: View {
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            ZStack {
                shape.fill(isOn ? AnyShapeStyle(Theme.gradient(for: Theme.Palette.danger)) : AnyShapeStyle(Color.white.opacity(0.05)))
                shape.strokeBorder(Color.white.opacity(isOn ? 0.35 : 0.22), lineWidth: 1)
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .heavy))
                    .foregroundStyle(.white)
                    .scaleEffect(isOn ? 1 : 0.4)
                    .opacity(isOn ? 1 : 0)
            }
            .frame(width: 16, height: 16)
            .glow(Theme.Palette.danger, radius: 6, opacity: isOn && isEnabled ? 0.6 : 0)
            .animation(Theme.Motion.press, value: isOn)
        }
    }
}

/// Result of the uninstall: reclaimed space as a big numeral, then anything that could not be moved.
struct UninstallSummary: View {
    let report: UninstallReport

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.l) {
                ScanOrb(tint: tint, diameter: 96) {
                    Image(systemName: report.succeeded ? "checkmark" : "exclamationmark.triangle.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.textGradient)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("RECLAIMED")
                        .font(Theme.Typography.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(report.reclaimedBytes.formatted(.byteCount(style: .file)))
                        .font(Theme.Typography.numeral(40))
                        .foregroundStyle(Theme.textGradient)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(report.succeeded ? successText : partialText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.s)
            .padding(.horizontal, Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.elevated, radius: Theme.Radius.xl)

            if !report.failures.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    SectionHeader(eyebrow: String(localized: "Needs attention"), title: String(localized: "Not moved"))
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        ForEach(report.failures, id: \.url) { failure in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Theme.Palette.warning)
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(failure.url.lastPathComponent)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Text(failure.reason)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surface(.raised)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tint: Color { report.succeeded ? Theme.Palette.success : Theme.Palette.warning }

    private var successText: String {
        String(localized: "Moved \(report.trashed.count) item(s) to the Trash. You can restore them from the Trash.")
    }

    private var partialText: String {
        String(localized: "Moved \(report.trashed.count) item(s); \(report.failures.count) could not be moved.")
    }
}

/// Warnings about the bundle's identity (L-11): a bundle ID is only an Info.plist string, so a
/// look-alike app can claim another app's ID and, with it, that app's data in ~/Library.
struct UninstallIntegrityBanners: View {
    let app: InstalledApp
    let integrity: BundleIntegrity

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            if let problem = integrity.signatureProblem {
                UninstallBanner(
                    symbol: "checkmark.seal.trianglebadge.exclamationmark",
                    tint: Theme.Palette.warning,
                    title: String(localized: "The code signature of \(app.name) could not be verified: \(problem)")
                ) { EmptyView() }
            }
            if integrity.hasDuplicates {
                UninstallBanner(
                    symbol: "square.on.square.badge.person.crop",
                    tint: Theme.Palette.warning,
                    title: duplicateMessage
                ) { EmptyView() }
                .help(integrity.duplicateBundles.map(\.path).joined(separator: "\n"))
            }
        }
    }

    private var duplicateMessage: String {
        let names = integrity.duplicateBundles.map(\.lastPathComponent).joined(separator: ", ")
        return String(
            localized: "Another app uses the same bundle ID (\(names)). Related files may belong to it, so only the app is selected."
        )
    }
}
