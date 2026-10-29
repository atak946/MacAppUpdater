import AppKit
import SwiftUI

/// Deep canvas with large blurred color fields that drift slowly, plus fine film grain.
/// Drawn once behind the whole window; glass surfaces blur it.
struct AppBackdrop: View {
    var isAnimated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    private static let driftDuration: Double = 22

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Theme.Palette.canvas
                field(Theme.Palette.brand, diameter: size.width * 0.75, opacity: 0.55)
                    .offset(x: size.width * (phase ? -0.28 : -0.18), y: size.height * (phase ? -0.30 : -0.22))
                field(Theme.Palette.brandSecondary, diameter: size.width * 0.55, opacity: 0.32)
                    .offset(x: size.width * (phase ? 0.34 : 0.26), y: size.height * (phase ? -0.12 : -0.24))
                field(Theme.Palette.brandTertiary, diameter: size.width * 0.6, opacity: 0.22)
                    .offset(x: size.width * (phase ? 0.10 : 0.22), y: size.height * (phase ? 0.46 : 0.36))
                // Vignette keeps the edges deep so content stays legible.
                RadialGradient(
                    colors: [.clear, Theme.Palette.canvas.opacity(0.75)],
                    center: .center,
                    startRadius: min(size.width, size.height) * 0.3,
                    endRadius: max(size.width, size.height) * 0.85
                )
                GrainOverlay()
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard isAnimated, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: Self.driftDuration).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }

    /// A soft color field. A radial gradient looks like a heavily blurred circle but needs no
    /// blur pass, which SwiftUI would otherwise re-run on the CPU whenever the window updates.
    private func field(_ color: Color, diameter: CGFloat, opacity: Double) -> some View {
        RadialGradient(
            stops: [
                .init(color: color.opacity(opacity), location: 0),
                .init(color: color.opacity(opacity * 0.55), location: 0.35),
                .init(color: color.opacity(opacity * 0.18), location: 0.65),
                .init(color: .clear, location: 1),
            ],
            center: .center,
            startRadius: 0,
            endRadius: diameter * 0.8
        )
        .frame(width: diameter * 1.6, height: diameter * 1.6)
    }
}

/// Tiled monochrome noise at very low opacity; removes gradient banding and adds texture.
private struct GrainOverlay: View {
    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(nsImage: Self.noise), scale: 0.5))
            .opacity(0.05)
            .blendMode(.overlay)
    }

    private static let noise: NSImage = {
        let side = 128
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceWhite, bytesPerRow: side, bitsPerPixel: 8
        ), let data = rep.bitmapData else { return NSImage() }
        var generator = SystemRandomNumberGenerator()
        for index in 0..<(side * side) {
            data[index] = UInt8.random(in: 0...255, using: &generator)
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }()
}
