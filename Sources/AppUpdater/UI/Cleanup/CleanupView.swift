import MaintenanceCore
import SwiftUI

/// Cleanup screen: scan for reclaimable space, review it per category and move the selection to the Trash.
struct CleanupView: View {
    let model: CleanupModel

    @State private var isConfirmingClean = false

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.bottom, Theme.Spacing.page)
                .padding(.top, Theme.Spacing.s)
                .frame(maxWidth: Theme.Spacing.contentWidth)
                .frame(maxWidth: .infinity)
                .animation(Theme.Motion.content, value: stateKey)
        }
        .scrollIndicators(.automatic)
        .pageBackground()
        .confirmationDialog(confirmTitle, isPresented: $isConfirmingClean, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.cleanSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .onAppear(perform: loadSampleIfRequested)
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            hero(.idle)
        case .scanning(let progress, let category):
            hero(.scanning(progress: progress, category: category))
        case .cleaning:
            hero(.cleaning)
        case .ready(let report):
            if report.groups.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.seal.fill",
                    tint: Theme.Palette.success,
                    title: String(localized: "Nothing to clean up"),
                    message: String(localized: "Your Mac has no caches, logs or leftovers worth removing right now."),
                    actionTitle: String(localized: "Rescan"),
                    action: model.startScan
                )
                .frame(minHeight: 420)
            } else {
                ready(report)
            }
        case .finished(let result):
            CleanupFinishedView(result: result, onDone: model.dismissResult)
                .frame(minHeight: 420)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case .failed(let message):
            EmptyStateView(
                symbol: "exclamationmark.triangle.fill",
                tint: Theme.Palette.warning,
                title: String(localized: "Couldn't finish the scan"),
                message: message,
                actionTitle: String(localized: "Try Again"),
                action: model.startScan
            )
            .frame(minHeight: 420)
        }
    }

    private func hero(_ phase: CleanupScanHero.Phase) -> some View {
        CleanupScanHero(phase: phase, onScan: model.startScan, onCancel: model.cancel)
            .padding(.vertical, Theme.Spacing.xl)
            .frame(minHeight: 420)
            .transition(.opacity)
    }

    private func ready(_ report: CleanupScanReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            CleanupSummaryHero(report: report, model: model) { isConfirmingClean = true }
            VStack(spacing: Theme.Spacing.m) {
                ForEach(report.groups) { group in
                    CleanupGroupCard(group: group, model: model)
                }
            }
            Text("Scanned \(report.scannedAt.formatted(.relative(presentation: .named)))")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(maxWidth: .infinity)
        }
        .transition(.opacity)
    }

    /// Changes whenever the screen switches between states, to animate the swap.
    private var stateKey: Int {
        switch model.state {
        case .idle: 0
        case .scanning: 1
        case .ready: 2
        case .cleaning: 3
        case .finished: 4
        case .failed: 5
        }
    }

    // MARK: Confirmation

    private var confirmTitle: String {
        String(localized: "Move \(model.selectedItems.count) items to the Trash?")
    }

    private var confirmMessage: String {
        let size = CleanupFormat.bytes(model.selectedSize)
        let base = String(localized: "This frees \(size). Items go to the Trash, so you can restore them until you empty it.")
        guard model.selectionIncludesTrash else { return base }
        return base + " " + String(localized: "Items already in the Trash are deleted permanently.")
    }

    // MARK: Debug

    private func loadSampleIfRequested() {
        #if DEBUG
        if CleanupSample.isRequested, model.state == .idle { model.loadSample() }
        #endif
    }
}
