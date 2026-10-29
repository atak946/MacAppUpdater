import AppKit
import AppUpdaterCore
import SwiftUI

/// Sheet with everything known about one app, plus its update action.
struct AppDetailView: View {
    let app: InstalledApp
    let viewModel: UpdatesViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var details: AppDetails?
    @State private var isUninstalling = false
    @State private var isConfirmingRevert = false
    @State private var didRemoveApp = false
    /// Average color of the app icon, used for the hero glow.
    @State private var iconTint: Color = Theme.Palette.brand

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.xl + Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.xl)
            UpdateBanner(app: app, viewModel: viewModel)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, hasPolicyHints ? Theme.Spacing.s : Theme.Spacing.l)
            if hasPolicyHints {
                policyHints
                    .padding(.horizontal, Theme.Spacing.xl + Theme.Spacing.xs)
                    .padding(.bottom, Theme.Spacing.m)
            }
            releaseNotes
            GlassDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    warningsSection
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionHeader(eyebrow: String(localized: "About"), title: String(localized: "Details"))
                        AppInfoGrid(
                            app: app, details: details, result: viewModel.checkResult(for: app),
                            releaseDate: viewModel.update(for: app).flatMap(viewModel.releaseDateLabel(for:))
                        )
                    }
                    betaToggle
                }
                .padding(Theme.Spacing.xl)
            }
            footer
                .padding(.horizontal, Theme.Spacing.l + 4)
                .padding(.vertical, Theme.Spacing.m)
                .glassSheetFooter()
        }
        .frame(width: 520, height: 760)
        .sheetBackdrop()
        .task(id: app.id) {
            iconTint = viewModel.icon(for: app).dominantTint ?? Theme.Palette.brand
            details = await viewModel.details(for: app)
        }
        .sheet(isPresented: $isUninstalling, onDismiss: { if didRemoveApp { dismiss() } }) {
            makeUninstallSheet(for: app, viewModel: viewModel) { report in
                didRemoveApp = report.removedAppBundle
            }
        }
        .revertConfirmation(appName: app.name, isPresented: $isConfirmingRevert) {
            Task { await viewModel.revertToPreviousVersion(app) }
        }
        .actionErrorAlert(viewModel)
    }

    // MARK: Hero

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.l + 4) {
            HeroAppIcon(image: viewModel.icon(for: app), tint: iconTint)
            VStack(alignment: .leading, spacing: Theme.Spacing.s - 2) {
                Text(app.name)
                    .font(Theme.Typography.display)
                    .tracking(Theme.Typography.displayTracking)
                    .foregroundStyle(Theme.textGradient)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: Theme.Spacing.s) {
                    Text(app.shortVersion)
                        .font(Theme.Typography.numeral(14))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    StatusPill(title: heroStatus.title, symbol: heroStatus.symbol, tint: heroStatus.tint)
                    if let management = viewModel.vendorManagement(for: app) {
                        VendorManagedBadge(management: management)
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

    /// Short status for the hero pill; the banner below carries the details.
    private var heroStatus: (title: String, symbol: String, tint: Color) {
        if viewModel.exclusions.isIgnored(app.bundleIdentifier) {
            return (String(localized: "Ignored"), "eye.slash", Theme.Palette.textSecondary)
        }
        if let update = viewModel.update(for: app) {
            return (String(localized: "\(update.newVersion) available"), "arrow.down.circle.fill", Theme.Palette.info)
        }
        return (String(localized: "Up to date"), "checkmark.circle.fill", Theme.Palette.success)
    }

    @ViewBuilder
    private var releaseNotes: some View {
        if let update = viewModel.update(for: app), let notes = update.releaseNotes {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("What's New in \(update.newVersion)", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                ReleaseNotesView(notes: notes, loader: viewModel.releaseNotesLoader)
                    .frame(height: 170)
                    .padding(Theme.Spacing.xs)
                    .surface(.raised, radius: Theme.Radius.l)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.l)
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        let warnings = viewModel.warnings(for: app)
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader(eyebrow: String(localized: "Attention"), title: String(localized: "Warnings"))
                ForEach(warnings) { warning in
                    WarningCard(entry: AppWarningEntry(app: app, warning: warning), onSelectApp: { _ in })
                }
            }
        }
    }

    private var autoInstallHint: String? {
        viewModel.update(for: app).flatMap(viewModel.autoInstallHint(for:))
    }

    private var ceiling: String? { viewModel.exclusions.ceiling(for: app.bundleIdentifier) }

    private var hasPolicyHints: Bool { autoInstallHint != nil || ceiling != nil }

    /// Auto-install countdown and version ceiling, under the banner.
    private var policyHints: some View {
        HStack(spacing: Theme.Spacing.l) {
            if let autoInstallHint { Label(autoInstallHint, systemImage: "clock.badge.checkmark") }
            if let ceiling { Label("Staying on \(ceiling).x", systemImage: "arrow.down.to.line") }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    /// Sparkle feeds may publish a "beta" channel; App Store apps never use Sparkle.
    /// Hidden when the organization disables beta channels (MDM).
    @ViewBuilder
    private var betaToggle: some View {
        if app.sparkleFeedURL != nil, !app.isFromAppStore, viewModel.managedGate.areBetaChannelsAllowed {
            Toggle("Include beta versions", isOn: Binding(
                get: { viewModel.isBetaOptedIn(app) },
                set: { viewModel.setBeta($0, for: app) }
            ))
            .toggleStyle(.switch)
            .tint(Theme.Palette.brand)
            .controlSize(.small)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .surface(.raised, radius: Theme.Radius.m)
            .help("Uses the app's Sparkle \"beta\" channel when it publishes one.")
        }
    }

    @ViewBuilder
    private var ignoreButton: some View {
        if viewModel.isIgnoreLocked(app.bundleIdentifier) {
            Label("Ignored by your organization", systemImage: "lock.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.Palette.textSecondary)
                .help("A configuration profile excludes this app from updates.")
        } else if viewModel.exclusions.isIgnored(app.bundleIdentifier) {
            Button("Stop Ignoring", systemImage: "eye") { viewModel.include(app.bundleIdentifier) }
                .buttonStyle(.secondary)
        } else {
            Button("Ignore Updates", systemImage: "eye.slash") { viewModel.ignore(app) }
                .buttonStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button("Show in Finder", systemImage: "folder") { viewModel.revealInFinder(app) }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Show in Finder")
            ignoreButton
            if !app.isFromAppStore {
                VersionCeilingMenu(
                    version: app.shortVersion,
                    current: ceiling,
                    onSelect: { viewModel.setCeiling($0, for: app) }
                )
                .glassMenuStyle()
                .help("Keep this app on its current major or minor version")
            }
            if let backup = viewModel.backup(for: app) {
                Button("Revert to \(backup.version)", systemImage: "arrow.uturn.backward") {
                    isConfirmingRevert = true
                }
                .buttonStyle(.secondary)
                .help("Restore the version installed before the last update (backed up \(backup.createdAt.formatted(.relative(presentation: .named))))")
            }
            if viewModel.canUninstall(app) {
                Button("Uninstall…", systemImage: "trash") { isUninstalling = true }
                    .buttonStyle(.secondary(tint: Theme.Palette.danger))
            }
            Spacer(minLength: Theme.Spacing.s)
            Button("Done") { dismiss() }
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Hero icon

/// App icon floating on a soft halo of its own dominant color.
struct HeroAppIcon: View {
    let image: NSImage
    var tint: Color = Theme.Palette.brand
    var size: CGFloat = 72

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .glow(tint, radius: size * 0.36, opacity: 0.6)
            .background {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: size * 0.9))
                    .frame(width: size * 1.8, height: size * 1.8)
                    .blur(radius: 14)
            }
            .animation(Theme.Motion.content, value: tint)
            .accessibilityHidden(true)
    }
}

// MARK: - Sheet chrome

extension View {
    /// Root of a sheet: paints its own static backdrop (the presenter's environment says it is
    /// already on one) and forces the dark glass appearance.
    func sheetBackdrop() -> some View {
        pageBackground()
            .environment(\.isOnBackdrop, false)
            .preferredColorScheme(.dark)
    }

    /// Frosted footer bar with a hairline on top, for a sheet's action row.
    func glassSheetFooter() -> some View {
        background {
            ZStack {
                Rectangle().fill(Theme.Palette.glass)
                Rectangle().fill(Color.black.opacity(0.18))
            }
        }
        .overlay(alignment: .top) { GlassDivider() }
    }

    /// Borderless menu dressed as a secondary glass capsule (no system accent color).
    func glassMenuStyle() -> some View {
        modifier(GlassMenuModifier())
    }
}

private struct GlassMenuModifier: ViewModifier {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Theme.Palette.textPrimary)
            .foregroundStyle(Theme.Palette.textPrimary)
            .font(.system(size: 11.5, weight: .medium))
            .fixedSize()
            .padding(.horizontal, 11)
            .padding(.vertical, 4.5)
            .background(Capsule().fill(Color.white.opacity(isHovered ? 0.11 : 0.06)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(isHovered ? 0.22 : 0.12), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(Theme.Motion.hover, value: isHovered)
    }
}

// MARK: - Icon tint

extension NSImage {
    /// Alpha-weighted average color of the image, lifted so it reads as a glow on the dark
    /// backdrop. Nil for transparent or near-grey images.
    var dominantTint: Color? {
        let side = 12
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: rep), let data = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for index in 0..<(side * side) {
            let offset = index * 4
            // Premultiplied RGBA: summing the channels already weights by alpha.
            red += Double(data[offset])
            green += Double(data[offset + 1])
            blue += Double(data[offset + 2])
            weight += Double(data[offset + 3])
        }
        guard weight > 0 else { return nil }
        let average = NSColor(deviceRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        guard average.saturationComponent > 0.12 else { return nil }
        return Color(nsColor: NSColor(
            deviceHue: average.hueComponent,
            saturation: max(average.saturationComponent, 0.5),
            brightness: max(average.brightnessComponent, 0.85),
            alpha: 1
        ))
    }
}
