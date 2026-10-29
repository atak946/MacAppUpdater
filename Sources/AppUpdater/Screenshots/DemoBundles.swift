import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Writes a minimal `.app` bundle per demo app into the sandbox, each with a generated icon, so the
/// real views' `NSWorkspace.icon(forFile:)` lookups show demo art instead of whatever the host has.
/// The bundles carry sandbox-only bundle ids, so Launch Services never confuses them with real apps.
@MainActor
enum DemoBundles {
    private static let iconPixelSizes = [16, 32, 64, 128, 256, 512]
    private static let executableName = "demo"

    /// Bundle URL per demo bundle id.
    static func make(in folder: URL) throws -> [String: URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [String: URL] = [:]
        for app in DemoFixtures.apps {
            let bundle = folder.appendingPathComponent(app.bundleFolderName, isDirectory: true)
            try write(app, to: bundle)
            urls[app.bundleID] = bundle
        }
        return urls
    }

    private static func write(_ app: DemoFixtures.App, to bundle: URL) throws {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        // Without an executable Finder badges the icon as "can't be opened". It is never run.
        let executable = executables.appendingPathComponent(executableName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let slug = app.bundleID.replacingOccurrences(of: ".", with: "-")
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.macappupdater.screenshots.demo.\(slug)",
            "CFBundleName": app.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": app.version,
            "CFBundleIconFile": "AppIcon",
            "CFBundleExecutable": executableName,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try writeIcon(for: app, to: resources.appendingPathComponent("AppIcon.icns"))
    }

    private static func writeIcon(for app: DemoFixtures.App, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.icns.identifier as CFString, iconPixelSizes.count, nil
        ) else { throw IconError.encoderUnavailable }
        for pixels in iconPixelSizes {
            let renderer = ImageRenderer(content: DemoIconArt(app: app).frame(width: 512, height: 512))
            renderer.scale = CGFloat(pixels) / 512
            guard let image = renderer.cgImage else { throw IconError.renderFailed }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw IconError.renderFailed }
    }

    enum IconError: Error {
        case encoderUnavailable
        case renderFailed
    }
}

/// A macOS-style squircle with a gradient and a white SF Symbol, on the standard icon grid
/// (824 of 1024 points with room for the shadow). Generic art, never a vendor's logo.
private struct DemoIconArt: View {
    let app: DemoFixtures.App

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 92, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(
                    colors: [Color(hex: app.colors.0), Color(hex: app.colors.1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            shape
                .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
            Image(systemName: app.symbol)
                .font(.system(size: 196, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
            shape.strokeBorder(.white.opacity(0.18), lineWidth: 3)
        }
        .frame(width: 412, height: 412)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .frame(width: 512, height: 512)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
