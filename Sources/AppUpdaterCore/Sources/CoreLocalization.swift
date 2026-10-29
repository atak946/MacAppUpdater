import Foundation

extension String {
    /// User-facing text localized from the core resource bundle (`Resources/Localizable.xcstrings`).
    ///
    /// Uses `CoreResourceBundle` instead of `Bundle.module`, which traps when the bundle is missing.
    /// When the bundle is unavailable the lookup falls back to the main bundle and, failing that,
    /// to the English source text, so callers always get a readable string.
    init(coreLocalized value: String.LocalizationValue) {
        self.init(localized: value, bundle: CoreResourceBundle.bundle)
    }
}
