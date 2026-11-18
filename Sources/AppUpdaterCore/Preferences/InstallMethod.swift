import Foundation

/// How an update can be applied, decided before downloading.
///
/// The download file name is the download URL's last path component (see
/// `DownloadVerifier.fileName(for:)`), so the URL extension is the file format.
/// Only an allowlist of formats is ever installed by this app (security review H-1). A URL
/// without a recognisable extension (`…/download`, `get.php?os=mac`) is `.detectedAfterDownload`:
/// the file is downloaded, verified and identified by its bytes (`PackageSniffer`), and only a
/// real dmg/zip/pkg is installed. Known non-package types (`.tar.gz`, `.terminal`, `.webloc`, …)
/// are `.manualDownload` and are never downloaded, opened or auto-installed.
public enum InstallMethod: Sendable, Equatable {
    /// dmg/zip: downloaded, verified and replaced in place.
    case automatic
    /// Mac App Store app: the store handles the update.
    case appStore
    /// .pkg/.mpkg: installed by the privileged helper or handed to Installer.app.
    case installerPackage
    /// No recognisable extension: downloaded (with the user's go), then installed only when its
    /// bytes prove a dmg/zip/pkg; otherwise deleted and the vendor's page is opened. Never
    /// installed unattended.
    case detectedAfterDownload
    /// A known non-package type (`.tar.gz`, `.terminal`, `.webloc`, …): the user is sent to the
    /// vendor's release page in the browser; nothing is downloaded.
    case manualDownload

    /// `knownFormat` is what an earlier download from the same app and host proved to be
    /// (`DetectedFormatStoring`) or what the server announced; it only refines
    /// `.detectedAfterDownload` URLs.
    public init(update: AvailableUpdate, knownFormat: PackageFormat? = nil) {
        if update.source == .appStore {
            self = .appStore
            return
        }
        switch Self.effectiveFormat(of: update, knownFormat: knownFormat) {
        case .dmg, .zip, .tarball: self = .automatic
        case .pkg: self = .installerPackage
        case .unknown:
            self = Self.isKnownNonPackage(update.downloadURL) ? .manualDownload : .detectedAfterDownload
        }
    }

    /// The URL's format, or `knownFormat` for an extension-less URL that is not a known
    /// non-package type.
    public static func effectiveFormat(of update: AvailableUpdate, knownFormat: PackageFormat?) -> PackageFormat {
        let urlFormat = PackageFormat(fileURL: update.downloadURL)
        guard urlFormat == .unknown, !isKnownNonPackage(update.downloadURL), let knownFormat else { return urlFormat }
        return knownFormat
    }

    /// Extensions that name something other than an installable package. Anything else
    /// unrecognised (no extension, `php`, a version digit such as `App-1.2.3`) may still be a
    /// package served without its extension, so it is worth sniffing.
    static let nonPackageExtensions: Set<String> = [
        // Bare compressed files (not `.tar.*`, which is a tarball) and other archivers.
        "gz", "bz2", "xz", "zst", "7z", "rar", "lz", "lzma",
        "terminal", "webloc", "inetloc", "fileloc", "url",
        "html", "htm", "txt", "md", "rtf", "pdf", "json", "xml",
        "sh", "command", "tool", "app", "exe", "msi", "deb", "rpm", "appimage", "jar", "iso",
    ]

    static func isKnownNonPackage(_ url: URL) -> Bool {
        nonPackageExtensions.contains(url.pathExtension.lowercased())
    }

    /// True for formats `AppInstaller` replaces in place (dmg, zip, tar archives).
    public static func isInPlaceFormat(_ format: PackageFormat) -> Bool {
        format == .dmg || format == .zip || format == .tarball
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
    public init(update: AvailableUpdate, vendorManagement: VendorManagement?, knownFormat: PackageFormat? = nil) {
        let standard = InstallMethod(update: update, knownFormat: knownFormat)
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
