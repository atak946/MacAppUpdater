import SwiftUI

/// Download progress in the brand palette: a dark recessed track, glowing gradient fill with a moving sheen,
/// amount and percent above it and speed / time left below (large style).
/// Without a known size the bar shows a sliding indeterminate segment.
struct DownloadProgressBar: View {
    enum Style {
        /// Update rows: thin bar, one caption line.
        case compact
        /// Detail window banner: thicker bar, big percent, speed and ETA.
        case large
    }

    let status: DownloadStatus?
    var style: Style = .compact

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gradient = LinearGradient(
        colors: [Theme.Palette.brand, Theme.Palette.brandSecondary.opacity(0.9), Theme.Palette.info],
        startPoint: .leading, endPoint: .trailing
    )

    private var barHeight: CGFloat { style == .large ? 10 : 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .large ? 6 : 3) {
            labels
            bar
            if style == .large, let rate = status?.rate {
                Text(rate)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Download progress"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var labels: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(status?.amount ?? String(localized: "Connecting…"))
                .font((style == .large ? Font.callout : .caption).monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
            if style == .compact, let rate = status?.rate {
                Text(rate)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let fraction = status?.fraction {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(style == .large ? Theme.Typography.numeral(20) : .system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.brandGradient)
                    .glow(Theme.Palette.brand, radius: 6, opacity: 0.5)
                    .contentTransition(.numericText())
            }
        }
    }

    /// Only the indeterminate segment is clipped, so the determinate fill's glow can bleed past the track.
    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                track
                if let fraction = status?.fraction {
                    determinateFill(width: max(barHeight, proxy.size.width * min(max(fraction, 0), 1)))
                } else {
                    IndeterminateSegment(height: barHeight, gradient: Self.gradient, animated: !reduceMotion)
                        .clipShape(Capsule())
                        .glow(Theme.Palette.brand, radius: barHeight, opacity: 0.5)
                }
            }
        }
        .frame(height: barHeight)
        .animation(Theme.Motion.content, value: status?.fraction)
    }

    /// Dark recessed groove: deep fill, inner top shadow and a hairline rim.
    private var track: some View {
        Capsule()
            .fill(Color.black.opacity(0.38))
            .overlay(
                Capsule().fill(
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
                )
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func determinateFill(width: CGFloat) -> some View {
        Capsule()
            .fill(Self.gradient)
            .overlay { if !reduceMotion { Sheen() } }
            .clipShape(Capsule())
            .frame(width: width)
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            )
            .glow(Theme.Palette.brandSecondary, radius: barHeight * 1.2, opacity: 0.45)
            .glow(Theme.Palette.brand, radius: barHeight * 0.6, opacity: 0.6)
    }

    private var accessibilityValue: String {
        let percent = status?.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
        return [percent, status?.summary].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A soft highlight sweeping across the filled part.
private struct Sheen: View {
    @State private var offset: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.35)
                .offset(x: offset * proxy.size.width)
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { offset = 1.2 }
                }
        }
        .allowsHitTesting(false)
    }
}

/// Sliding segment for downloads whose size is unknown.
private struct IndeterminateSegment: View {
    let height: CGFloat
    let gradient: LinearGradient
    let animated: Bool

    @State private var offset: CGFloat = -0.35

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(gradient)
                .frame(width: proxy.size.width * 0.35, height: height)
                .offset(x: (animated ? offset : 0.3) * proxy.size.width)
                .onAppear {
                    guard animated else { return }
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { offset = 0.65 }
                }
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        DownloadProgressBar(status: nil)
        DownloadProgressBar(
            status: DownloadStatus(
                progress: .init(receivedBytes: 640_000_000, expectedBytes: 1_524_936_162),
                startedAt: .now.addingTimeInterval(-40)
            ),
            style: .large
        )
    }
    .padding()
    .frame(width: 420)
}
