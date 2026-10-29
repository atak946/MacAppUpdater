import SwiftUI

/// Small lock shown next to a control whose value is enforced by a configuration profile.
struct ManagedLockBadge: View {
    var help: String = String(localized: "Managed by your organization. This setting can't be changed.")

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel("Managed")
            .accessibilityHint(help)
    }
}

extension View {
    /// Disables the control and appends a `ManagedLockBadge` when `isLocked` is true.
    @ViewBuilder
    func managedLock(_ isLocked: Bool) -> some View {
        if isLocked {
            HStack(spacing: 6) {
                disabled(true)
                ManagedLockBadge()
            }
        } else {
            self
        }
    }
}
