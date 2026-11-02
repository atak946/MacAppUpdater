import MaintenanceCore
import SwiftUI

enum DiskUsageStyle {
    static let tint = Color.orange
    static let icon: CGFloat = 26
    static let rowHorizontal: CGFloat = Theme.Spacing.l
    static let barWidth: CGFloat = 160
    static let sizeWidth: CGFloat = 86
    static let filesWidth: CGFloat = 92
    static let dividerInset: CGFloat = rowHorizontal + icon + Theme.Spacing.m

    /// Bar color by share of the parent: the heavy hitters stand out.
    static func barTint(for share: Double) -> Color {
        switch share {
        case 0.4...: Theme.Palette.danger
        case 0.15..<0.4: Theme.Palette.warning
        default: Theme.Palette.brandTertiary
        }
    }
}

/// One child of the folder on screen: icon, name, share bar, size and file count.
struct DiskUsageRow: View {
    let node: DiskUsageNode
    /// Nil for the folded "smaller files" row.
    let icon: NSImage?
    /// 0...1 of the parent folder's size.
    let share: Double
    /// The folder is being measured again; the size slot shows a spinner.
    var isRescanning = false
    let onOpen: () -> Void

    @State private var isHovered = false

    private var canOpen: Bool { node.isFolder && !node.children.isEmpty }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.m) {
                iconView
                nameColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                ShareBar(share: share)
                    .frame(width: DiskUsageStyle.barWidth)
                sizeLabel
                    .frame(width: DiskUsageStyle.sizeWidth, alignment: .trailing)
                Text(filesLabel)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(width: DiskUsageStyle.filesWidth, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .opacity(canOpen ? (isHovered ? 1 : 0.5) : 0)
            }
            .padding(.horizontal, DiskUsageStyle.rowHorizontal)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(isHovered ? Theme.Palette.hoverFill : .clear)
                    .padding(.horizontal, Theme.Spacing.xs)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Files stay enabled (not dimmed); opening them is a no-op in the model.
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityHint(canOpen ? Text("Opens the folder") : Text(""))
    }

    @ViewBuilder
    private var sizeLabel: some View {
        if isRescanning {
            ProgressView().controlSize(.small).tint(.white)
        } else {
            Text(node.sizeInBytes.formatted(.byteCount(style: .file)))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: DiskUsageStyle.icon, height: DiskUsageStyle.icon)
        } else {
            IconTile(symbol: "doc.on.doc.fill", tint: Color(white: 0.45), size: DiskUsageStyle.icon)
        }
    }

    private var nameColumn: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(displayName)
                .font(.system(size: 13, weight: node.isFolder ? .semibold : .regular))
                .foregroundStyle(node.kind == .smallFiles ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if node.isPartial {
                StatusPill(title: String(localized: "Partial"), symbol: "lock.fill", tint: Theme.Palette.warning)
                    .help(String(localized: "Some folders inside could not be read, so the real size may be larger."))
            }
        }
    }

    private var displayName: String {
        node.kind == .smallFiles
            ? String(localized: "\(node.fileCount) smaller files")
            : node.name
    }

    private var filesLabel: String {
        node.kind == .file ? "" : String(localized: "\(node.fileCount.formatted()) files")
    }
}

/// Horizontal share-of-parent bar with the percentage beside it.
private struct ShareBar: View {
    let share: Double

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule()
                        .fill(DiskUsageStyle.barTint(for: share).gradient)
                        .frame(width: max(2, proxy.size.width * min(1, share)))
                }
            }
            .frame(height: 6)
            Text(share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0))))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// Path from the scanned folder down to the one on screen; each crumb jumps back.
struct DiskUsageBreadcrumb: View {
    let trail: [DiskUsageNode]
    /// The folder on screen is being measured again.
    let isRescanning: Bool
    let onSelect: (Int) -> Void
    let onUp: () -> Void
    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button(action: onUp) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(trail.count < 2)
            .help("Up one level")
            .keyboardShortcut(.upArrow, modifiers: .command)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(trail.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        Button(node.name) { onSelect(index) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: index == trail.count - 1 ? .semibold : .medium))
                            .foregroundStyle(index == trail.count - 1 ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.trailing)
            Button(action: onRescan) {
                if isRescanning {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(IconButtonStyle())
            .disabled(isRescanning)
            .help("Rescan This Folder")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
    }
}
