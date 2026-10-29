import AppUpdaterCore
import Foundation

/// Display values for a running download: "245 MB" of "1.5 GB", 16 %, "12.3 MB/s", "About 2 min left".
struct DownloadStatus: Equatable {
    /// Speed and ETA need a little history before they mean anything.
    private static let minimumElapsed: TimeInterval = 1

    /// `0...1`, nil when the total size is unknown (indeterminate bar).
    let fraction: Double?
    let received: String?
    let total: String?
    let speed: String?
    let remaining: String?

    /// - Parameter knownSize: size from the pre-download HEAD probe, used when the transfer
    ///   itself does not report a content length.
    init(progress: DownloadProgress, knownSize: Int64? = nil, startedAt start: Date?, now: Date = .now) {
        let expected = progress.expectedBytes ?? knownSize
        let hasBytes = progress.receivedBytes > 0
        fraction = progress.fractionCompleted
            ?? expected.map { min(1, Double(progress.receivedBytes) / Double($0)) }.flatMap { hasBytes ? $0 : nil }
        received = hasBytes ? Self.bytes(progress.receivedBytes) : nil
        total = expected.map(Self.bytes)

        let elapsed = start.map { now.timeIntervalSince($0) } ?? 0
        guard hasBytes, elapsed >= Self.minimumElapsed else {
            speed = nil
            remaining = nil
            return
        }
        let bytesPerSecond = Double(progress.receivedBytes) / elapsed
        speed = String(localized: "\(Self.bytes(Int64(bytesPerSecond)))/s")
        if let expected, bytesPerSecond > 0, expected > progress.receivedBytes {
            remaining = Self.remaining(Double(expected - progress.receivedBytes) / bytesPerSecond)
        } else {
            remaining = nil
        }
    }

    /// "245 MB of 1.5 GB", "245 MB", "1.5 GB" or nil before anything is known.
    var amount: String? {
        switch (received, total) {
        case let (received?, total?): String(localized: "\(received) of \(total)")
        case let (received?, nil): received
        case let (nil, total?): total
        case (nil, nil): nil
        }
    }

    /// "12.3 MB/s · About 2 min left".
    var rate: String? {
        let parts = [speed, remaining].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One-line summary for compact places and accessibility.
    var summary: String {
        [amount, rate].compactMap { $0 }.joined(separator: " · ")
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func remaining(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute] : [.second])
        formatter.maximumUnitCount = 2
        let text = formatter.string(from: max(1, seconds.rounded())) ?? ""
        return String(localized: "About \(text) left")
    }
}
