import AppKit
import os
import SwiftUI

/// Renders the README screenshots from demo data, writes them as PNGs and quits. Launched with
/// `--render-screenshots <dir>`; the language comes from the process (`-AppleLanguages (tr)`).
@MainActor
enum ScreenshotRenderer {
    /// Lets `.task` / `.onAppear` work and layout passes settle before a snapshot.
    private static let settleDelay: Duration = .milliseconds(600)
    private static let logger = Logger(subsystem: "com.macappupdater", category: "Screenshots")

    /// Runs the render loop when screenshot mode was requested and never returns in that case;
    /// returns false otherwise so the caller starts the regular app.
    static func runIfRequested() -> Bool {
        guard let directory = ScreenshotMode.outputDirectory() else { return false }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let succeeded = await render(to: directory)
            exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        app.run()
        return true
    }

    private static func render(to directory: URL) async -> Bool {
        let stage: DemoStage
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stage = try DemoStage(now: Date())
        } catch {
            report("Screenshot setup failed: \(error.localizedDescription)")
            return false
        }
        defer { stage.environment.cleanUp() }
        await stage.prepare()
        var failures = 0
        for shot in ScreenshotPlan.shots {
            let url = directory.appendingPathComponent("\(shot.name).png")
            if await !write(shot, stage: stage, to: url) { failures += 1 }
        }
        report("Rendered \(ScreenshotPlan.shots.count - failures) of \(ScreenshotPlan.shots.count) screenshots")
        return failures == 0
    }

    private static func write(_ shot: ScreenshotPlan.Shot, stage: DemoStage, to url: URL) async -> Bool {
        let view = shot.content(stage)
            .environment(\.locale, Locale.current)
            .defaultAppStorage(stage.environment.defaults)
            // Entrance and list animations would otherwise be caught mid-flight.
            .transaction { $0.disablesAnimations = true }
        guard let image = await snapshot(of: view, size: shot.size, scrollOffset: shot.scrollOffset),
              let data = PNGQuantizer.pngData(from: image) else {
            report("Could not render \(shot.name)")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            report("Could not write \(shot.name): \(error.localizedDescription)")
            return false
        }
    }

    /// An offscreen window hosts the view, so AppKit-backed controls (scroll views, menus, pickers)
    /// draw for real; `ImageRenderer` would show them as placeholders.
    private static func snapshot(of view: some View, size: CGSize?, scrollOffset: CGFloat) async -> CGImage? {
        let host = NSHostingView(rootView: view)
        let fitted = size ?? host.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: fitted),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: fitted)
        window.orderFrontRegardless()
        try? await Task.sleep(for: settleDelay)
        prepareScrollViews(in: host, offset: scrollOffset)
        try? await Task.sleep(for: settleDelay)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(fitted.width * ScreenshotPlan.scale), pixelsHigh: Int(fitted.height * ScreenshotPlan.scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = fitted
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    /// Hides scrollers (they would flash in the shot) and scrolls the page, the widest scroll view,
    /// down by `offset` points, at most to its end.
    private static func prepareScrollViews(in root: NSView, offset: CGFloat) {
        let scrollViews = descendants(of: root).compactMap { $0 as? NSScrollView }
        for scrollView in scrollViews {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
        }
        guard offset > 0,
              let page = scrollViews.max(by: { $0.frame.width < $1.frame.width }),
              let document = page.documentView else { return }
        let overflow = document.frame.height - page.contentView.bounds.height
        guard overflow > 0 else { return }
        let distance = min(offset, overflow)
        let target = document.isFlipped ? distance : overflow - distance
        page.contentView.scroll(to: NSPoint(x: 0, y: target))
        page.reflectScrolledClipView(page.contentView)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// Progress goes to stderr too, because the render script runs the binary from a terminal.
    private static func report(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
