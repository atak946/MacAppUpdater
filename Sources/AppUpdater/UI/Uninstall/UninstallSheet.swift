import AppKit
import AppUpdaterCore
import SwiftUI

/// Standalone sheet: dry-run scan → user picks items → confirm → Move to Trash → summary.
struct UninstallSheet: View {
    typealias ScanAction = @Sendable () async throws -> UninstallPlan
    typealias UninstallAction = @Sendable (UninstallPlan, Set<URL>) async throws -> UninstallReport

    let app: InstalledApp
    let icon: NSImage
    let scan: ScanAction
    let uninstall: UninstallAction
    /// Optional: offered when the app is running (e.g. `RunningAppTerminator`). Scan is retried afterwards.
    var quitApp: (@Sendable () async throws -> Void)?
    /// Called once after an uninstall attempt completed (refresh the app list here).
    var onFinished: (UninstallReport) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .scanning
    @State private var selection: Set<URL> = []
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var appIsRunning = false
    /// Average color of the app icon, used for the hero glow.
    @State private var iconTint: Color = Theme.Palette.danger

    enum Phase {
        case scanning
        case ready(UninstallPlan)
        case trashing(UninstallPlan)
        case finished(UninstallReport)
        case refused(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            UninstallHeader(app: app, icon: icon, tint: iconTint, subtitle: subtitle, teamIdentifier: integrity?.teamIdentifier)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.xl + Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.l)
            if let integrity, integrity.signatureProblem != nil || integrity.hasDuplicates {
                UninstallIntegrityBanners(app: app, integrity: integrity)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.m)
            }
            if let errorMessage {
                UninstallBanner(symbol: "exclamationmark.triangle.fill", tint: Theme.Palette.warning, title: errorMessage) {
                    if appIsRunning, quitApp != nil {
                        Button("Quit \(app.name)") { Task { await quitAndRetry() } }
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.m)
            }
            if let plan = activePlan {
                UninstallReclaimSummary(
                    bytes: plan.totalSize(of: selection),
                    selectedCount: selection.count,
                    totalCount: plan.leftovers.count + 1
                )
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.s)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
                .padding(.horizontal, Theme.Spacing.l + 4)
                .padding(.vertical, Theme.Spacing.m)
                .glassSheetFooter()
        }
        .frame(width: 520, height: 720)
        .sheetBackdrop()
        .animation(Theme.Motion.content, value: phaseKey)
        .task {
            iconTint = icon.dominantTint ?? Theme.Palette.danger
            await runScan()
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $isConfirming
        ) {
            Button("Move to Trash", role: .destructive) { Task { await runUninstall() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can restore them from the Trash until it is emptied.")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            UninstallScanningView(appName: app.name)
        case .ready(let plan):
            UninstallItemList(plan: plan, selection: $selection, isDisabled: false)
        case .trashing(let plan):
            UninstallItemList(plan: plan, selection: $selection, isDisabled: true)
                .opacity(0.6)
                .overlay {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Moving to Trash…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    .padding(.horizontal, Theme.Spacing.l + 2)
                    .padding(.vertical, Theme.Spacing.m)
                    .surface(.elevated, radius: Theme.Radius.xl)
                    .glow(Theme.Palette.danger, radius: 24, opacity: 0.35)
                }
        case .finished(let report):
            ScrollView { UninstallSummary(report: report).padding(Theme.Spacing.xl) }
        case .refused(let reason):
            EmptyStateView(
                symbol: "lock.fill",
                tint: Theme.Palette.textSecondary,
                title: String(localized: "Can't uninstall this app"),
                message: reason
            )
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.s) {
            if case .ready(let plan) = phase {
                Text("\(plan.totalSize(of: selection).formatted(.byteCount(style: .file))) selected")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            switch phase {
            case .finished:
                Button("Done") { dismiss() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            case .ready:
                Button("Cancel") { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) { isConfirming = true } label: {
                    Label("Move to Trash…", systemImage: "trash.fill")
                }
                .buttonStyle(.primary(tint: Theme.Palette.danger))
                .controlSize(.large)
                .disabled(selection.isEmpty)
            default:
                Button("Cancel") { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isTrashing)
            }
        }
        .controlSize(.regular)
    }

    private var subtitle: String {
        switch phase {
        case .finished(let report):
            String(localized: "\(report.reclaimedBytes.formatted(.byteCount(style: .file))) moved to the Trash")
        default:
            app.isFromAppStore ? String(localized: "Uninstall · Mac App Store app") : String(localized: "Uninstall")
        }
    }

    private var integrity: BundleIntegrity? {
        switch phase {
        case .ready(let plan), .trashing(let plan): plan.integrity
        default: nil
        }
    }

    /// The plan whose selection is on screen (ready or trashing).
    private var activePlan: UninstallPlan? {
        switch phase {
        case .ready(let plan), .trashing(let plan): plan
        default: nil
        }
    }

    /// Stable identity of the phase, for animating between steps.
    private var phaseKey: Int {
        switch phase {
        case .scanning: 0
        case .ready: 1
        case .trashing: 2
        case .finished: 3
        case .refused: 4
        }
    }

    private var isTrashing: Bool {
        if case .trashing = phase { return true }
        return false
    }

    private var confirmationTitle: String {
        guard case .ready(let plan) = phase, selection.contains(plan.bundle.url) else {
            return String(localized: "Move \(selection.count) selected item(s) to the Trash?")
        }
        return String(localized: "Move \(app.name) and \(selection.count - 1) related item(s) to the Trash?")
    }

    // MARK: Actions

    private func runScan() async {
        phase = .scanning
        do {
            let plan = try await scan()
            selection = plan.defaultSelection
            phase = .ready(plan)
        } catch {
            phase = .refused(error.localizedDescription)
        }
    }

    private func runUninstall() async {
        guard case .ready(let plan) = phase else { return }
        phase = .trashing(plan)
        errorMessage = nil
        do {
            let report = try await uninstall(plan, selection)
            phase = .finished(report)
            onFinished(report)
        } catch {
            appIsRunning = (error as? UninstallError).map { if case .appIsRunning = $0 { true } else { false } } ?? false
            errorMessage = error.localizedDescription
            phase = .ready(plan)
        }
    }

    private func quitAndRetry() async {
        guard let quitApp else { return }
        do {
            try await quitApp()
            appIsRunning = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
