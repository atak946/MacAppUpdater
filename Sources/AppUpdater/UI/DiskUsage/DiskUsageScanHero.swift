import MaintenanceCore
import SwiftUI

/// Start and scanning states of Disk Usage: an orb beside the headline, then the largest
/// top-level folders filling in as they finish. Every text slot has a fixed size, so the
/// layout never moves while the numbers tick.
struct DiskUsageScanHero: View {
    enum Phase: Equatable {
        case idle
        case scanning(DiskUsageScanProgress?)
    }

    let phase: Phase
    /// Name of the folder being (or about to be) scanned.
    let rootName: String
    let onScanHome: () -> Void
    let onChooseFolder: () -> Void
    let onCancel: () -> Void

    private static let orbDiameter: CGFloat = 180
    private static let copyWidth: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            HStack(alignment: .center, spacing: Theme.Spacing.xxxl) {
                orb
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    copy
                    actions
                }
                .frame(width: Self.copyWidth, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            if case .scanning(let progress) = phase {
                DiskUsageLiveFolders(progress: progress)
            }
        }
        .padding(.top, Theme.Spacing.l)
    }

    // MARK: Orb

    private var progress: DiskUsageScanProgress? {
        if case .scanning(let progress) = phase { return progress }
        return nil
    }

    private var isScanning: Bool { phase != .idle }

    private var orb: some View {
        ScanOrb(tint: DiskUsageStyle.tint, isActive: isScanning, diameter: Self.orbDiameter) {
            if let progress, progress.foldersTotal > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int((progress.fractionCompleted * 100).rounded()))")
                        .font(Theme.Typography.numeral(50))
                        .contentTransition(.numericText())
                    Text(verbatim: "%")
                        .font(Theme.Typography.numeral(20))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .foregroundStyle(Theme.textGradient)
                .animation(Theme.Motion.content, value: progress.foldersDone)
            } else {
                Image(systemName: "chart.bar.doc.horizontal.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.white, DiskUsageStyle.tint], startPoint: .top, endPoint: .bottom))
                    .glow(DiskUsageStyle.tint, radius: 16, opacity: 0.6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(headline))
    }

    // MARK: Copy

    private var copy: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("DISK USAGE")
                .font(Theme.Typography.eyebrow)
                .tracking(1.6)
                .foregroundStyle(DiskUsageStyle.tint)
            Text(headline)
                .font(Theme.Typography.hero)
                .tracking(Theme.Typography.displayTracking)
                .foregroundStyle(Theme.textGradient)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            detail
                .frame(height: 40, alignment: .topLeading)
        }
    }

    private var headline: String {
        isScanning
            ? String(localized: "Measuring \(rootName)…")
            : String(localized: "Find what fills your disk")
    }

    @ViewBuilder
    private var detail: some View {
        if isScanning {
            // Monospaced digits in fixed columns: the line never reflows as the counts grow.
            HStack(spacing: Theme.Spacing.l) {
                counter(progress?.itemsScanned.formatted() ?? "—", label: String(localized: "items"))
                counter(progress?.bytesScanned.formatted(.byteCount(style: .file)) ?? "—", label: String(localized: "found"))
                counter(
                    progress.map { "\($0.foldersDone)/\($0.foldersTotal)" } ?? "—",
                    label: String(localized: "folders")
                )
            }
        } else {
            Text("Scan your home folder, or choose any folder, to see its size broken down by subfolder.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
        }
    }

    private func counter(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(width: 120, alignment: .leading)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if isScanning {
            Button("Stop", action: onCancel)
                .buttonStyle(.secondary)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        } else {
            HStack(spacing: Theme.Spacing.s) {
                Button(action: onScanHome) {
                    Label("Scan Home Folder", systemImage: "house.fill")
                }
                .buttonStyle(.primary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button(action: onChooseFolder) {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .buttonStyle(.secondary)
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Live folders

/// The largest finished top-level folders while the scan runs. A fixed number of row slots
/// keeps the card's height constant; empty slots are placeholders.
private struct DiskUsageLiveFolders: View {
    let progress: DiskUsageScanProgress?

    private static let slots = 8
    private static let rowHeight: CGFloat = 30

    var body: some View {
        let folders = progress?.finishedFolders ?? []
        let largest = max(folders.first?.sizeInBytes ?? 1, 1)
        VStack(alignment: .leading, spacing: 0) {
            Text("LARGEST SO FAR")
                .font(Theme.Typography.eyebrow)
                .tracking(1.2)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
            GlassDivider()
            VStack(spacing: 0) {
                ForEach(0..<Self.slots, id: \.self) { index in
                    slot(index < folders.count ? folders[index] : nil, largest: largest)
                        .frame(height: Self.rowHeight)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .padding(.horizontal, Theme.Spacing.l)
        }
        .surface(.raised)
        .animation(Theme.Motion.content, value: folders)
    }

    @ViewBuilder
    private func slot(_ folder: DiskUsageScanProgress.Folder?, largest: Int64) -> some View {
        if let folder {
            let share = Double(folder.sizeInBytes) / Double(largest)
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskUsageStyle.tint)
                Text(folder.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(DiskUsageStyle.tint.gradient)
                            .frame(width: max(2, proxy.size.width * share))
                    }
                }
                .frame(width: 220, height: 6)
                Text(folder.sizeInBytes.formatted(.byteCount(style: .file)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 80, alignment: .trailing)
            }
            .transition(.opacity)
        } else {
            HStack(spacing: Theme.Spacing.m) {
                Capsule().fill(Color.white.opacity(0.04)).frame(width: 140, height: 8)
                Spacer()
            }
        }
    }
}
