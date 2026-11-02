import AppUpdaterCore
import SwiftUI

/// Settings › General › Backups: whether updates keep the previous version, and for how long.
struct BackupSettingsSection: View {
    /// Prunes right away so a shorter period frees space without waiting for the next launch.
    let onChange: () -> Void

    /// Read by `AppInstaller` before every install.
    @AppStorage(BackupSettings.enabledKey) private var isEnabled = true
    /// Read by `BackupStore` on every prune.
    @AppStorage(BackupSettings.retentionDaysKey) private var retentionDays = BackupSettings.defaultRetentionDays

    var body: some View {
        Section("Backups") {
            Toggle("Back up apps before updating", isOn: $isEnabled)
            Picker("Keep backups for", selection: $retentionDays) {
                ForEach(BackupSettings.retentionDayChoices, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
            .disabled(!isEnabled)
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: isEnabled) { _, _ in onChange() }
        .onChange(of: retentionDays) { _, _ in onChange() }
    }

    private var footnote: String {
        isEnabled
            ? String(localized: "The previous version of each updated app is kept so the update can be undone. Remove backups any time under Cleanup.")
            : String(localized: "Updates can't be undone while backups are off. Existing backups are kept until they expire.")
    }
}
