import AppKit
import MaintenanceCore
import SwiftUI

/// Glass card for one category: icon, title, size, tri-state select-all and an expandable item list.
struct CleanupGroupCard: View {
    let group: CleanupGroup
    let model: CleanupModel

    @State private var isExpanded = false
    @State private var showsAll = false
    @State private var isHeaderHovered = false

    /// Rows shown before "Show all N".
    private static let collapsedLimit = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                GlassDivider()
                    .padding(.horizontal, Theme.Spacing.l)
                expandedContent
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, Theme.Spacing.s)
                    // A move transition inside the card drew rows over the hero above; fade only.
                    .transition(.opacity)
            }
        }
        .background(
            RadialGradient(
                colors: [group.category.tint.opacity(selection == .none ? 0.06 : 0.16), .clear],
                center: .topLeading, startRadius: 0, endRadius: 260
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        )
        .surface(isHeaderHovered ? .elevated : .raised)
        .animation(Theme.Motion.content, value: isExpanded)
        .animation(Theme.Motion.hover, value: isHeaderHovered)
    }

    private var selection: CleanupModel.GroupSelection { model.selectionState(of: group) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            CleanupCheckbox(state: selection, tint: group.category.tint) { model.toggleGroup(group) }
                .accessibilityLabel(Text("Select all \(group.category.title)"))
            IconTile(symbol: group.category.symbol, tint: group.category.tint, size: 34, glows: selection != .none)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(group.category.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if group.category.needsReview {
                        StatusPill(title: String(localized: "Review"), symbol: "eye.fill", tint: Theme.Palette.warning)
                    }
                }
                Text(group.category.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Theme.Spacing.m)
            VStack(alignment: .trailing, spacing: 2) {
                Text(CleanupFormat.bytes(group.totalSize))
                    .font(Theme.Typography.numeral(17))
                    .foregroundStyle(Theme.textGradient)
                Text(countLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .contentTransition(.numericText())
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 16)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m + 2)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
        .onHover { isHeaderHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(isExpanded ? "Collapse" : "Expand"))
    }

    private var countLabel: String {
        let selected = group.items.lazy.filter { model.isSelected($0) }.count
        return String(localized: "\(selected) of \(group.items.count) selected")
    }

    // MARK: Items

    private var visibleItems: ArraySlice<CleanupItem> {
        showsAll ? group.items[...] : group.items.prefix(Self.collapsedLimit)
    }

    /// Removed-app leftovers are grouped by bundle identifier; every other category is a flat list.
    @ViewBuilder
    private var expandedContent: some View {
        if group.category == .removedAppLeftovers {
            CleanupOwnerSectionList(group: group, model: model)
        } else {
            items
        }
    }

    private var items: some View {
        // Plain VStack: a LazyVStack nested in a card mis-measured its height, leaving a gap.
        VStack(spacing: 0) {
            ForEach(visibleItems) { item in
                CleanupItemRow(item: item, isSelected: model.isSelected(item), tint: group.category.tint) {
                    model.toggle(item)
                }
            }
            if !showsAll, group.items.count > Self.collapsedLimit {
                Button {
                    withAnimation(Theme.Motion.content) { showsAll = true }
                } label: {
                    Label("Show all \(group.items.count)", systemImage: "chevron.down")
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .padding(.top, Theme.Spacing.s)
            }
        }
    }
}

// MARK: - Item row

/// One removable item: checkbox, name, muted location, last access and size.
struct CleanupItemRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let tint: Color
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            CleanupCheckbox(state: isSelected ? .all : .none, tint: tint, action: onToggle)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                Text(CleanupFormat.location(of: item.url))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Spacing.m)
            if isHovered {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.secondary)
                .controlSize(.mini)
                .help(Text("Show in Finder"))
                .transition(.opacity)
            }
            if let lastModified = item.lastModified {
                Text("Modified \(Text(lastModified, format: .relative(presentation: .named)))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .frame(minWidth: 80, alignment: .trailing)
            } else if let lastAccessed = item.lastAccessed {
                Text(lastAccessed, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .frame(minWidth: 80, alignment: .trailing)
            }
            Text(CleanupFormat.bytes(item.sizeInBytes))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 7)
        .hoverHighlight(isHovered, radius: Theme.Radius.s)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Checkbox

/// Glowing rounded checkbox with checked, mixed and empty states.
struct CleanupCheckbox: View {
    let state: CleanupModel.GroupSelection
    var tint: Color = Theme.Palette.brand
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Button(action: action) {
            ZStack {
                shape.fill(isOn ? AnyShapeStyle(Theme.gradient(for: tint)) : AnyShapeStyle(Color.white.opacity(isHovered ? 0.1 : 0.05)))
                shape.strokeBorder(isOn ? Color.white.opacity(0.35) : Color.white.opacity(isHovered ? 0.4 : 0.22), lineWidth: 1)
                if state != .none {
                    Image(systemName: state == .all ? "checkmark" : "minus")
                        .font(.system(size: 9.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 17, height: 17)
            .glow(tint, radius: isOn ? 6 : 0, opacity: isOn ? 0.7 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.press, value: state)
        .animation(Theme.Motion.hover, value: isHovered)
        .accessibilityValue(Text(accessibilityValue))
    }

    private var isOn: Bool { state != .none }

    private var accessibilityValue: String {
        switch state {
        case .all: String(localized: "Selected")
        case .some: String(localized: "Partially selected")
        case .none: String(localized: "Not selected")
        }
    }
}
