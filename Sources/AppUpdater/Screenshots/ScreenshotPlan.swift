import SwiftUI

/// The README screenshots: which real view each one draws, and at what size.
@MainActor
enum ScreenshotPlan {
    struct Shot {
        let name: String
        /// Points; nil sizes the view to fit (the menu bar panel).
        let size: CGSize?
        /// Points the page is scrolled down first, for sections below the fold; clamped to the end.
        var scrollOffset: CGFloat = 0
        let content: @MainActor (DemoStage) -> AnyView
    }

    static let windowSize = CGSize(width: 1280, height: 800)
    static let scale: CGFloat = 2

    static var shots: [Shot] {
        [
            page("hero", .overview),
            page("updates", .updates),
            Shot(name: "menubar", size: nil) { stage in
                AnyView(MenuBarView(viewModel: stage.menuBarViewModel, monitorModel: stage.monitorModel))
            },
            // Past the gauges, so the charts, top consumers and the 24-hour history card all show.
            page("system", .system, size: CGSize(width: 1280, height: 860), scrollOffset: 350),
            page("processes", .processes),
            page("cleanup", .cleanup),
            page("insights", .insights, scrollOffset: .greatestFiniteMagnitude),
        ]
    }

    private static func page(
        _ name: String, _ item: SidebarItem, size: CGSize = windowSize, scrollOffset: CGFloat = 0
    ) -> Shot {
        Shot(name: name, size: size, scrollOffset: scrollOffset) { stage in
            AnyView(MainWindowView(
                viewModel: stage.viewModel,
                formulaeModel: stage.formulaeModel,
                cleanupModel: stage.cleanupModel,
                startupModel: stage.startupModel,
                securityModel: stage.securityModel,
                monitorModel: stage.monitorModel,
                initialSelection: item
            ))
        }
    }
}
