import MaintenanceCore
import SwiftUI

/// Security & privacy screen: a weighted score of the macOS protections, a card per check and
/// the apps holding privacy permissions, with their own search.
struct SecurityView: View {
    let model: SecurityModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                SecurityHero(model: model)
                    .padding(.vertical, Theme.Spacing.l)
                if let report = model.report {
                    SecurityChecksGrid(results: report.results)
                        .transition(.opacity)
                    SecurityPermissionsSection(model: model)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.page)
            .padding(.top, Theme.Spacing.s)
            .frame(maxWidth: Theme.Spacing.contentWidth)
            .frame(maxWidth: .infinity)
            .animation(Theme.Motion.content, value: model.report == nil)
        }
        .scrollIndicators(.automatic)
        .pageBackground()
        .onAppear(perform: model.runIfNeeded)
    }
}
