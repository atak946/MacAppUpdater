import AppKit
import Foundation
import MonitorCore
import SwiftUI

/// Number formatting shared by the monitor screens and the menu bar strip.
enum MonitorFormat {
    /// 0...1 → "42%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, fraction) * 100).rounded()))%"
    }

    /// Process CPU (percent of one core) → "12.3%", "142%".
    static func cpu(_ percent: Double) -> String {
        percent >= 100 || percent == 0
            ? "\(Int(percent.rounded()))%"
            : String(format: "%.1f%%", percent)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func diskBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    /// Bytes per second → "1.2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let amount = ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .file)
        return String(localized: "\(amount)/s")
    }

    /// Uptime → "3d 4h".
    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, interval)) ?? "—"
    }

    static func minutes(_ minutes: Int) -> String {
        duration(TimeInterval(minutes * 60))
    }
}

extension MemoryPressure {
    var tint: Color {
        switch self {
        case .normal: Theme.Palette.brand
        case .warning: Theme.Palette.warning
        case .critical: Theme.Palette.danger
        }
    }

    var title: String {
        switch self {
        case .normal: String(localized: "Normal pressure")
        case .warning: String(localized: "Elevated pressure")
        case .critical: String(localized: "High pressure")
        }
    }
}

extension ThermalLevel {
    var tint: Color {
        switch self {
        case .nominal: Theme.Palette.success
        case .fair: Theme.Palette.info
        case .serious: Theme.Palette.warning
        case .critical: Theme.Palette.danger
        }
    }

    var title: String {
        switch self {
        case .nominal: String(localized: "Thermal: Normal")
        case .fair: String(localized: "Thermal: Fair")
        case .serious: String(localized: "Thermal: Serious")
        case .critical: String(localized: "Thermal: Critical")
        }
    }
}

/// CPU load tint: cyan when calm, amber when busy, red when pegged.
func cpuTint(_ fraction: Double) -> Color {
    if fraction >= 0.85 { return Theme.Palette.danger }
    if fraction >= 0.6 { return Theme.Palette.warning }
    return Theme.Palette.brandTertiary
}

/// Keeps a model sampling while the view is actually visible on screen. `onAppear` alone isn't
/// enough: a menu bar popover's content stays "appeared" after it closes, and a hidden, minimized
/// or fully covered window would keep sampling. Balanced even if appear fires twice.
private struct MonitorObservation: ViewModifier {
    let model: MonitorModel
    let demand: MonitorDemand

    @State private var isAppeared = false
    @State private var isWindowVisible = false
    @State private var isObserving = false

    func body(content: Content) -> some View {
        content
            .background(WindowVisibilityReader(isVisible: $isWindowVisible))
            .onAppear { isAppeared = true; sync() }
            .onDisappear { isAppeared = false; sync() }
            .onChange(of: isWindowVisible) { _, _ in sync() }
    }

    private func sync() {
        let shouldObserve = isAppeared && isWindowVisible
        guard shouldObserve != isObserving else { return }
        isObserving = shouldObserve
        if shouldObserve { model.beginObserving(demand) } else { model.endObserving(demand) }
    }
}

/// Reports whether the hosting window is on screen and not fully occluded.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) {}

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Removing from the window (incl. teardown) drops the observers.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return report() }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let isClosing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.report(forceHidden: isClosing) }
                }
            }
            report()
        }

        private func report(forceHidden: Bool = false) {
            guard let window, !forceHidden else { onChange?(false); return }
            onChange?(window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }
    }
}

extension View {
    func monitorObservation(_ model: MonitorModel, demand: MonitorDemand) -> some View {
        modifier(MonitorObservation(model: model, demand: demand))
    }
}
