import Combine
import Foundation
import Observation
import os
import Sparkle

/// Updates App Updater itself via Sparkle.
///
/// Sparkle is only started when the process runs from a real `.app` bundle whose
/// Info.plist declares `SUFeedURL`. Under `swift run` (bare executable) the updater
/// stays inert so development builds never try to replace themselves.
@MainActor
@Observable
final class SelfUpdater {
    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check is running or when inert).
    private(set) var canCheckForUpdates = false
    /// True when Sparkle was actually started.
    let isActive: Bool

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var cancellable: AnyCancellable?
    @ObservationIgnored private let logger = Logger(subsystem: "com.macappupdater", category: "SelfUpdater")

    init(bundle: Bundle = .main) {
        guard let reason = Self.inactiveReason(for: bundle) else {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            self.controller = controller
            self.isActive = true
            self.canCheckForUpdates = controller.updater.canCheckForUpdates
            observeCanCheck(controller.updater)
            logger.info("Sparkle self-updater started")
            return
        }
        self.controller = nil
        self.isActive = false
        logger.info("Sparkle self-updater inactive: \(reason, privacy: .public)")
    }

    /// Shows Sparkle's standard "check for updates" UI. No-op when inert.
    func checkForUpdates() {
        guard let controller else {
            logger.notice("checkForUpdates ignored: self-updater is inactive")
            return
        }
        controller.checkForUpdates(nil)
    }

    private func observeCanCheck(_ updater: SPUUpdater) {
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
    }

    /// Returns why Sparkle must not start, or nil when it is safe to start.
    nonisolated static func inactiveReason(for bundle: Bundle) -> String? {
        guard bundle.bundleURL.pathExtension == "app" else {
            return "not running from an .app bundle (\(bundle.bundleURL.path))"
        }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https" else {
            return "Info.plist has no https SUFeedURL"
        }
        return nil
    }
}
