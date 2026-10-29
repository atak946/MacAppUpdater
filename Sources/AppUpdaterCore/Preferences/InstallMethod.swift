import Foundation

/// How an update can be applied, decided before downloading.
///
/// The download file name is the download URL's last path component (see
/// `DownloadVerifier.fileName(for:)`), so the URL extension is the file format.
/// Only an allowlist of formats is ever handled by this app (security review H-1):
/// anything else becomes `.manualDownload` and is never downloaded, opened or auto-installed.
public enum InstallMethod: Sendable, Equatable {
    /// dmg/zip: downloaded, verified and replaced in place.
    case automatic
    /// Mac App Store app: the store handles the update.
    case appStore
    /// .pkg/.mpkg: installed by the privileged helper or handed to Installer.app.
    case installerPackage
    /// Unknown or missing extension (`.tar.gz`, `.terminal`, `.webloc`, extension-less, …):
    /// the user is sent to the vendor's release page in the browser; nothing is downloaded.
    case manualDownload

    public init(update: AvailableUpdate) {
        if update.source == .appStore {
            self = .appStore
            return
        }
        switch PackageFormat(fileURL: update.downloadURL) {
        case .dmg, .zip: self = .automatic
        case .pkg: self = .installerPackage
        case .unknown: self = .manualDownload
        }
    }

    /// True for formats `AppInstaller` replaces in place (dmg/zip).
    public static func isInPlaceFormat(_ format: PackageFormat) -> Bool {
        format == .dmg || format == .zip
    }

    /// The page to open for a manual update: the release notes page, else the download URL
    /// itself (the browser downloads it with quarantine). HTTPS only; never a local file.
    public static func manualDownloadPage(for update: AvailableUpdate) -> URL? {
        [update.releaseNotesURL, update.downloadURL]
            .compactMap { $0 }
            .first { $0.scheme?.lowercased() == "https" }
    }
}

/// `InstallMethod` plus vendor-managed apps (Setapp, Creative Cloud, MAU, Keystone, Toolbox).
///
/// Kept as a separate enum so adding the vendor case does not break the exhaustive
/// `switch`es over `InstallMethod` elsewhere. Call sites that know about vendor management
/// switch over this type; everything else keeps using `InstallMethod`.
public enum ResolvedInstallMethod: Sendable, Equatable {
    /// One of the regular, in-app install paths.
    case standard(InstallMethod)
    /// The vendor's updater owns this app; route the user there instead of installing.
    case vendorManaged(VendorManagement)

    /// Vendor management wins over the update's own install path, except for App Store apps.
    public init(update: AvailableUpdate, vendorManagement: VendorManagement?) {
        let standard = InstallMethod(update: update)
        if let vendorManagement, standard != .appStore {
            self = .vendorManaged(vendorManagement)
        } else {
            self = .standard(standard)
        }
    }

    /// The regular method, or nil when the vendor must handle the update.
    public var standardMethod: InstallMethod? {
        if case .standard(let method) = self { method } else { nil }
    }

    public var vendorManagement: VendorManagement? {
        if case .vendorManaged(let management) = self { management } else { nil }
    }

    /// True only for in-place installs this app may perform without user interaction.
    public var isAutomatic: Bool { standardMethod == .automatic }
}

extension InstallMethod {
    /// Resolves the install path taking vendor management (see `VendorManagementDetector`) into account.
    public static func resolve(update: AvailableUpdate, vendorManagement: VendorManagement?) -> ResolvedInstallMethod {
        ResolvedInstallMethod(update: update, vendorManagement: vendorManagement)
    }
}
