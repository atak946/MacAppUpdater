import AppUpdaterCore
import SwiftUI

/// Custom glass sidebar: brand mark, search, navigation with an animated selection pill
/// and a settings footer. Replaces the system source list for a fully designed look.
struct GlassSidebar: View {
    let viewModel: UpdatesViewModel
    let formulaeModel: FormulaeModel
    @Binding var selection: SidebarItem?
    @Binding var searchText: String

    @Namespace private var selectionNamespace

    /// Room for the traffic lights in the hidden title bar.
    private static let titleBarHeight: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Self.titleBarHeight)
            brand
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.l)
            SidebarSearchField(text: $searchText)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.m)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    row(.overview, count: 0)
                    section(String(localized: "Library"))
                    row(.updates, count: viewModel.pendingUpdates.count, isProminent: true)
                    row(.allApps, count: viewModel.installedApps.count)
                    row(.commandLineTools, count: formulaeModel.upgradable.count)
                    row(.insights, count: viewModel.insights?.totalWarnings ?? 0)
                    row(.coverage, count: viewModel.coverageReport?.untracked.count ?? 0)
                    row(.history, count: 0)
                    section(String(localized: "Maintenance"))
                    row(.cleanup, count: 0)
                    row(.startup, count: 0)
                    row(.security, count: 0)
                    section(String(localized: "Monitor"))
                    row(.system, count: 0)
                    row(.processes, count: 0)
                    section(String(localized: "Sources"))
                    ForEach(UpdateSourceKind.allCases, id: \.self) { kind in
                        row(.source(kind), count: count(for: kind))
                    }
                    section(String(localized: "Exclusions"))
                    row(.excluded, count: excludedCount)
                }
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.l)
            }
            .scrollIndicators(.never)
            footer
        }
        .background {
            ZStack {
                Rectangle().fill(Theme.Palette.glass)
                Rectangle().fill(Color.black.opacity(0.28))
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Palette.hairline).frame(width: 1).ignoresSafeArea()
        }
    }

    // MARK: Brand

    private var brand: some View {
        HStack(spacing: Theme.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.brandGradient)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                Image(systemName: "arrow.down")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .glow(Theme.Palette.brand, radius: 10, opacity: 0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text("App Updater")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Mac care, simplified")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    // MARK: Rows

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.Typography.eyebrow)
            .tracking(1.4)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.top, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xs)
    }

    private func row(_ item: SidebarItem, count: Int, isProminent: Bool = false) -> some View {
        SidebarRow(
            item: item,
            count: count,
            isProminent: isProminent,
            isSelected: (selection ?? .overview) == item,
            namespace: selectionNamespace
        ) {
            withAnimation(Theme.Motion.content) { selection = item }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.s) {
            Circle()
                .fill(statusTint)
                .frame(width: 7, height: 7)
                .glow(statusTint, radius: 4, opacity: 0.9)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .overlay(alignment: .top) { GlassDivider() }
    }

    private var statusTint: Color {
        switch viewModel.state {
        case .failed: Theme.Palette.danger
        case .scanning, .checking: Theme.Palette.warning
        default: viewModel.pendingUpdates.isEmpty ? Theme.Palette.success : Theme.Palette.info
        }
    }

    private var statusText: String {
        switch viewModel.state {
        case .failed: String(localized: "Last check failed")
        case .scanning, .checking: String(localized: "Checking for updates…")
        default:
            viewModel.pendingUpdates.isEmpty
                ? String(localized: "Everything is up to date")
                : String(localized: "\(viewModel.pendingUpdates.count) updates ready")
        }
    }

    private var excludedCount: Int {
        let rules = viewModel.exclusions
        return rules.ignoredBundleIdentifiers.count + rules.skippedVersions.count + rules.versionCeilings.count
    }

    private func count(for kind: UpdateSourceKind) -> Int {
        viewModel.pendingUpdates.filter { $0.source == kind }.count
    }
}

/// One navigation row; the selection pill slides between rows via a matched geometry effect.
private struct SidebarRow: View {
    let item: SidebarItem
    let count: Int
    let isProminent: Bool
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m - 2) {
                IconTile(symbol: item.symbol, tint: item.tint, size: 22, glows: isSelected)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.xs)
                if count > 0 { badge }
            }
            .padding(.horizontal, Theme.Spacing.s + 2)
            .padding(.vertical, 6)
            .background { background }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
        if isSelected {
            shape
                .fill(Theme.Palette.selectionFill)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                )
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .frame(width: 3, height: 16)
                        .glow(Theme.Palette.brand, radius: 6, opacity: 0.9)
                        .offset(x: -1)
                }
                .matchedGeometryEffect(id: "selection", in: namespace)
        } else if isHovered {
            shape.fill(Theme.Palette.hoverFill)
        }
    }

    private var badge: some View {
        Text("\(count)")
            .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(isProminent ? .white : Theme.Palette.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background {
                if isProminent {
                    Capsule().fill(Theme.brandGradient).glow(Theme.Palette.brand, radius: 5, opacity: 0.6)
                } else {
                    Capsule().fill(Color.white.opacity(0.08))
                }
            }
            .contentTransition(.numericText())
    }
}

/// Glass search field; ⌘F focuses it.
private struct SidebarSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField("Search apps", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Spacing.m - 2)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .fill(Color.white.opacity(isFocused ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(isFocused ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.Palette.hairline), lineWidth: 1)
        )
        .animation(Theme.Motion.hover, value: isFocused)
        // AppKit makes the first text field key on launch; start unfocused instead.
        .task { isFocused = false }
        .background(
            Button("Search") { isFocused = true }
                .keyboardShortcut("f")
                .hidden()
                .accessibilityHidden(true)
        )
    }
}
