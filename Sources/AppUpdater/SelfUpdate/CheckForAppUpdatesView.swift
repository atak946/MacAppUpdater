import SwiftUI

/// Menu command: "Check for App Updater Updates…".
///
/// Usage (in `AppUpdaterApp.commands`):
/// ```swift
/// CommandGroup(after: .appInfo) {
///     CheckForAppUpdatesView(selfUpdater: appDelegate.environment.selfUpdater)
/// }
/// ```
struct CheckForAppUpdatesView: View {
    let selfUpdater: SelfUpdater

    var body: some View {
        Button("Check for App Updater Updates…", action: selfUpdater.checkForUpdates)
            .disabled(!selfUpdater.canCheckForUpdates)
    }
}
