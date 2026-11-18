import SwiftUI

/// Segmented glass capsule shared by list pages; the selected segment gets a lit brand fill that slides between options.
struct FilterCapsule<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    /// Badge count per option; nil hides the badges.
    var count: ((Option) -> Int)?

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.Palette.glass))
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Filter"))
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(Theme.Motion.content) { selection = option }
        } label: {
            HStack(spacing: 6) {
                Text(title(option))
                if let count {
                    Text("\(count(option))")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(isSelected ? 0.18 : 0.06)))
                    .contentTransition(.numericText())
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                        .glow(Theme.Palette.brand, radius: 8, opacity: 0.45)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}


/// The row between a page header and its list: the page's filters on the left and the page's
/// own search field on the right, so it is clear what the field searches.
struct PageToolbar<Filters: View>: View {
    /// Already localized, names what this page's search looks through.
    let prompt: String
    @Binding var search: String
    /// "N shown" while the search narrows the list; nil hides it.
    var shownCount: Int?
    @ViewBuilder var filters: Filters

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            filters
            Spacer(minLength: Theme.Spacing.l)
            if let shownCount, !SearchQuery(search).isEmpty {
                Text("\(shownCount) shown")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .contentTransition(.numericText())
            }
            GlassSearchField(prompt: prompt, text: $search)
        }
    }
}

extension PageToolbar where Filters == EmptyView {
    init(prompt: String, search: Binding<String>, shownCount: Int? = nil) {
        self.init(prompt: prompt, search: search, shownCount: shownCount) { EmptyView() }
    }
}
