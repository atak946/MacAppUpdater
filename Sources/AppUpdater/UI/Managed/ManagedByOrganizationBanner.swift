import SwiftUI

/// Banner explaining that some settings are enforced by the organization (MDM profile).
struct ManagedByOrganizationBanner: View {
    var message: String = String(localized: "Some settings are managed by your organization and can't be changed here.")

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "building.2.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Managed by your organization")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ManagedByOrganizationBanner()
        .padding()
        .frame(width: 420)
}
