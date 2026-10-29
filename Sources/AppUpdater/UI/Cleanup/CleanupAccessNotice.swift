import AppKit
import SwiftUI

/// Explains the macOS folder prompts a scan triggers (Downloads, Desktop, Documents) and offers
/// Full Disk Access instead. Hidden once access is granted.
struct CleanupAccessNotice: View {
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    var body: some View {
        if !hasFullDiskAccess {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                IconTile(symbol: "lock.shield.fill", tint: Theme.Palette.warning, size: 26)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Grant Full Disk Access for a complete scan")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Without it, macOS asks before App Updater can look in Downloads, Desktop and Documents.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings…", action: FullDiskAccess.openSettings)
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                        .padding(.top, Theme.Spacing.xxs)
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.inset, radius: Theme.Radius.m)
            // The user may grant access in System Settings and come back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                hasFullDiskAccess = FullDiskAccess.isGranted
            }
        }
    }
}

/// Full Disk Access detection: the per-user TCC database is only readable with it.
enum FullDiskAccess {
    static var isGranted: Bool {
        let tcc = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
        return FileManager.default.isReadableFile(atPath: tcc.path)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
