import AppKit
import os
import SwiftUI
import WebKit

/// Script-free `WKWebView` for release-notes HTML. Clicked links open in the default browser,
/// and the page itself can never navigate away from the notes.
struct ReleaseNotesWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    /// Opt-in hook: allow https images/media/styles/fonts. Off by default because remote images
    /// work as tracking pixels for feed owners (L-8).
    var allowsRemoteImages = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Lets the window background show through so it matches the surrounding UI.
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let document = ReleaseNotesHTML.wrap(html, allowsRemoteImages: allowsRemoteImages)
        guard context.coordinator.loadedDocument != document else { return }
        context.coordinator.loadedDocument = document
        // Drop any pending navigation of the previous document before re-arming the gate.
        webView.stopLoading()
        context.coordinator.gate = ReleaseNotesNavigationGate()
        webView.loadHTMLString(document, baseURL: baseURL)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedDocument: String?
        var gate = ReleaseNotesNavigationGate()
        private let logger = Logger(subsystem: "com.macappupdater", category: "ReleaseNotesWebView")

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences
        ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            preferences.allowsContentJavaScript = false
            let decision = gate.decide(
                isLinkActivation: navigationAction.navigationType == .linkActivated,
                isOtherNavigation: navigationAction.navigationType == .other,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                url: navigationAction.request.url
            )
            return (apply(decision), preferences)
        }

        private func apply(_ decision: ReleaseNotesNavigationGate.Decision) -> WKNavigationActionPolicy {
            switch decision {
            case .allowInitialLoad:
                return .allow
            case .openExternally(let url):
                NSWorkspace.shared.open(url)
                return .cancel
            case .blockedScheme(let scheme):
                logger.notice("Blocked release-notes link with scheme \(scheme ?? "none", privacy: .public)")
                return .cancel
            case .cancel:
                return .cancel
            }
        }
    }
}

/// Pure navigation policy for the release-notes web view (L-8).
///
/// Exactly one navigation is allowed: the first main-frame load, i.e. our own `loadHTMLString`.
/// The flag flips in the decision itself, not in `didFinish`, so a `<meta http-equiv="refresh">`
/// or any other self-initiated navigation that fires before the load completes is cancelled.
/// User-clicked links never navigate the view; allowed schemes are handed to the default browser.
struct ReleaseNotesNavigationGate: Equatable {
    enum Decision: Equatable {
        case allowInitialLoad
        case openExternally(URL)
        case blockedScheme(String?)
        case cancel
    }

    static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    private(set) var hasAllowedInitialLoad = false

    mutating func decide(isLinkActivation: Bool, isOtherNavigation: Bool, isMainFrame: Bool, url: URL?) -> Decision {
        if isLinkActivation {
            guard let url else { return .cancel }
            let scheme = url.scheme?.lowercased()
            guard let scheme, Self.externalSchemes.contains(scheme) else { return .blockedScheme(url.scheme) }
            return .openExternally(url)
        }
        guard isOtherNavigation, isMainFrame, !hasAllowedInitialLoad else { return .cancel }
        hasAllowedInitialLoad = true
        return .allowInitialLoad
    }
}

/// Wraps untrusted HTML with a strict CSP and system-matching styles.
enum ReleaseNotesHTML {
    /// No scripts, frames, forms, plugins or remote fetches: images and fonts only from `data:`,
    /// styles only inline. Remote content would let feed owners track who reads the notes.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "img-src data:",
        "style-src 'unsafe-inline'",
        "font-src data:",
        "media-src 'none'",
        "form-action 'none'",
    ].joined(separator: "; ")

    /// Opt-in variant (`allowsRemoteImages`): images, media, styles and fonts may load from https.
    static let remoteContentSecurityPolicy = [
        "default-src 'none'",
        "img-src https: data:",
        "style-src 'unsafe-inline' https:",
        "font-src https: data:",
        "media-src https:",
        "form-action 'none'",
    ].joined(separator: "; ")

    static let stylesheet = """
    :root { color-scheme: light dark; }
    html, body { background: transparent !important; }
    body {
      font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif; font-size: 13px;
      line-height: 1.5; color: CanvasText; margin: 16px; word-wrap: break-word;
    }
    h1, h2, h3 { line-height: 1.25; margin: 1.1em 0 0.4em; }
    h1 { font-size: 1.45em; } h2 { font-size: 1.25em; } h3 { font-size: 1.1em; }
    ul, ol { padding-left: 1.4em; }
    li { margin: 0.2em 0; }
    a { color: -apple-system-blue; text-decoration: none; }
    a:hover { text-decoration: underline; }
    img, video { max-width: 100%; height: auto; }
    pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; }
    pre { padding: 8px 10px; border-radius: 6px; overflow-x: auto; background: rgba(127, 127, 127, 0.12); }
    hr { border: none; border-top: 1px solid rgba(127, 127, 127, 0.3); }
    """

    /// Elements before `<html>` are hoisted into `<head>` by the HTML parser, so this
    /// works for both fragments (Sparkle `<description>`) and full documents.
    static func wrap(_ html: String, allowsRemoteImages: Bool = false) -> String {
        let policy = allowsRemoteImages ? remoteContentSecurityPolicy : contentSecurityPolicy
        return """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="color-scheme" content="light dark">
        <style>\(stylesheet)</style>
        \(html)
        """
    }
}
