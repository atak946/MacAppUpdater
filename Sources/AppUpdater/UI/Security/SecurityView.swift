import MaintenanceCore
import SwiftUI

/// Security & privacy screen: a weighted score of the macOS protections, a card per check and
/// the apps holding privacy permissions. The sidebar search filters permissions by app name.
struct SecurityView: View {
    let model: SecurityModel
    let searchText: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                SecurityHero(model: model)
                    .padding(.vertical, Theme.Spacing.l)
                if let report = model.report {
                    SecurityChecksGrid(results: report.results)
                        .transition(.opacity)
                    SecurityPermissionsSection(model: model, searchText: searchText)
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
