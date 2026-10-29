import MaintenanceCore
import SwiftUI

/// Explains where "Open at Login" apps live and links to System Settings › Login Items.
struct StartupLoginItemsCard: View {
    let model: StartupModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                IconTile(symbol: "person.crop.circle.badge.checkmark", tint: Theme.Palette.warning, size: 30)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Login Items & background apps")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                    .buttonStyle(.primary)
            }
            if let items = model.loginItems, !items.isEmpty {
                GlassDivider()
                ForEach(items) { item in
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: "app.badge")
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(item.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(item.url.path)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(Theme.Spacing.l)
        .surface(.raised)
    }

    private var message: String {
        if model.loginItems != nil {
            return String(localized: "These apps are registered to open at login. Manage them in System Settings.")
        }
        return String(localized: "macOS keeps the list of apps that open at login private. They aren't shown here — review and switch them off in System Settings.")
    }
}
