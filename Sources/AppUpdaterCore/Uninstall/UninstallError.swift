import Foundation

/// Why an uninstall (or one item of it) was refused or failed.
public enum UninstallError: Error, Sendable, Hashable, LocalizedError {
    /// Apple system app (under /System or with a `com.apple.` bundle identifier).
    case systemApp(name: String)
    /// The organization disabled the uninstaller (MDM `DisableUninstaller`).
    case disabledByOrganization
    /// The updater itself or another explicitly protected app.
    case protectedApp(name: String)
    /// The app has running instances; the user must quit it first.
    case appIsRunning(name: String)
    /// The bundle identifier is empty or contains path characters.
    case invalidBundleIdentifier(String)
    /// `uninstall` was called with an empty selection.
    case nothingSelected
    /// A selected URL was not part of the scanned plan.
    case notInPlan(URL)
    /// The path is not (or no longer) inside an allowlisted ~/Library folder with a matching name.
    case outsideAllowlist(URL)
    /// The path is, or resolves through, a symbolic link pointing elsewhere.
    case symlinkEscape(URL)
    /// The app bundle on disk no longer matches the scanned app.
    case bundleMismatch(URL)
    /// The item disappeared between scan and uninstall.
    case itemMissing(URL)
    /// Leftover skipped because the app bundle itself could not be moved to the Trash.
    case skippedBecauseBundleFailed(URL)
    /// FileManager refused to move the item to the Trash.
    case trashFailed(url: URL, message: String)

    public var errorDescription: String? {
        switch self {
        case .systemApp(let name): String(coreLocalized: "\(name) is part of macOS and cannot be uninstalled.")
        case .disabledByOrganization: String(coreLocalized: "Your organization has disabled the uninstaller.")
        case .protectedApp(let name): String(coreLocalized: "\(name) cannot uninstall itself.")
        case .appIsRunning(let name): String(coreLocalized: "\(name) is running. Quit it before uninstalling.")
        case .invalidBundleIdentifier(let id): String(coreLocalized: "Invalid bundle identifier: \(id)")
        case .nothingSelected: String(coreLocalized: "Nothing is selected.")
        case .notInPlan(let url): String(coreLocalized: "\(url.path) was not part of the scan.")
        case .outsideAllowlist(let url): String(coreLocalized: "\(url.path) is outside the allowed folders.")
        case .symlinkEscape(let url): String(coreLocalized: "\(url.path) is a symbolic link and was skipped.")
        case .bundleMismatch(let url): String(coreLocalized: "\(url.path) no longer contains the scanned app.")
        case .itemMissing(let url): String(coreLocalized: "\(url.path) no longer exists.")
        case .skippedBecauseBundleFailed(let url):
            String(coreLocalized: "\(url.lastPathComponent) was kept because the app could not be moved to the Trash.")
        case .trashFailed(let url, let message): String(coreLocalized: "Could not move \(url.lastPathComponent) to the Trash: \(message)")
        }
    }
}
