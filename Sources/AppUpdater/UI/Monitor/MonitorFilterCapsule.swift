import SwiftUI

/// Segmented glass capsule for the Processes filter; the lit brand fill slides between options.
struct MonitorFilterCapsule: View {
    @Binding var selection: ProcessFilter
    let count: (ProcessFilter) -> Int

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProcessFilter.allCases) { option in
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

    private func segment(_ option: ProcessFilter) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(Theme.Motion.content) { selection = option }
        } label: {
            HStack(spacing: 6) {
                Text(option.title)
                Text("\(count(option))")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(isSelected ? 0.18 : 0.06)))
                    .contentTransition(.numericText())
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
        .help(option.help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
