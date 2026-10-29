import AppKit
import SwiftUI

@main
struct AppUpdaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("App Updater", id: "main") {
            MainWindowView(
                viewModel: appDelegate.environment.viewModel,
                formulaeModel: appDelegate.environment.formulaeModel,
                cleanupModel: appDelegate.environment.cleanupModel,
                startupModel: appDelegate.environment.startupModel,
                securityModel: appDelegate.environment.securityModel,
                monitorModel: appDelegate.environment.monitorModel,
                githubMappings: appDelegate.environment.githubMappingDependencies,
                migrationModel: appDelegate.environment.migrationModel
            )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                CheckForAppUpdatesView(selfUpdater: appDelegate.environment.selfUpdater)
            }
        }

        // MDM `HideMenuBarIcon` removes the status item; the main window stays available.
        MenuBarExtra(
            "App Updater",
            systemImage: appDelegate.environment.viewModel.menuBarSymbol,
            isInserted: .constant(!appDelegate.environment.managedGate.isMenuBarIconHidden)
        ) {
            MenuBarView(viewModel: appDelegate.environment.viewModel, monitorModel: appDelegate.environment.monitorModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsTabs(environment: appDelegate.environment)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular app: Dock icon + main window; the menu bar item stays for quick access.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        environment.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon brings the main window back.
        if !flag { sender.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.stop()
    }
}
