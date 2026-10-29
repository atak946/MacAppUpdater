import Foundation

/// An app whose updates are owned by a vendor tool (Setapp, Creative Cloud, MAU, Keystone, Toolbox).
/// Installing such an update ourselves can break licensing or fight the vendor updater, so the UI
/// should route the user to `openTarget` instead.
public struct VendorManagement: Sendable, Hashable {
    public enum Vendor: String, Sendable, Hashable, CaseIterable {
        case setapp
        case adobeCreativeCloud
        case microsoftAutoUpdate
        case googleKeystone
        case jetBrainsToolbox
    }

    /// What to open so the user can update through the vendor.
    public enum OpenTarget: Sendable, Hashable {
        /// Launch this application bundle (the vendor updater, or the managed app itself).
        case application(URL)
        /// Open this URL (custom scheme or web page).
        case url(URL)
    }

    public let vendor: Vendor
    /// Human-readable updater name, e.g. "Setapp" or "Microsoft AutoUpdate".
    public let updaterName: String
    public let openTarget: OpenTarget

    public init(vendor: Vendor, updaterName: String, openTarget: OpenTarget) {
        self.vendor = vendor
        self.updaterName = updaterName
        self.openTarget = openTarget
    }
}

extension VendorManagement.Vendor {
    /// Default display name for the vendor's updater.
    public var updaterName: String {
        switch self {
        case .setapp: "Setapp"
        case .adobeCreativeCloud: "Adobe Creative Cloud"
        case .microsoftAutoUpdate: "Microsoft AutoUpdate"
        case .googleKeystone: "Google Software Update"
        case .jetBrainsToolbox: "JetBrains Toolbox"
        }
    }
}
