import Foundation
import os

/// A downloader that reports progress and honours cooperative Task cancellation.
public protocol ProgressReportingDownloading: UpdateDownloading {
    /// Downloads and verifies `update`. `progress` receives fractions in `0...1`
    /// (only when the server reports a content length) on an arbitrary queue;
    /// hop to the main actor before touching UI state.
    /// Cancelling the calling Task cancels the transfer and throws `CancellationError`.
    func download(_ update: AvailableUpdate, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// Bytes received so far; `expectedBytes` is nil when the server sends no content length.
public struct DownloadProgress: Sendable, Equatable {
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    /// Explicit fraction for sources that only know a ratio (no byte counts).
    private let reportedFraction: Double?

    public init(receivedBytes: Int64, expectedBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes.flatMap { $0 > 0 ? $0 : nil }
        self.reportedFraction = nil
    }

    public init(fractionCompleted: Double) {
        self.receivedBytes = 0
        self.expectedBytes = nil
        self.reportedFraction = min(1, max(0, fractionCompleted))
    }

    /// `0...1`, or nil when the total size is unknown.
    public var fractionCompleted: Double? {
        if let reportedFraction { return reportedFraction }
        guard let expectedBytes else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }
}

/// A downloader that also reports byte counts (for "120 MB of 1.5 GB" style detail).
public protocol DetailedProgressDownloading: ProgressReportingDownloading {
    func downloadReporting(_ update: AvailableUpdate, reporting: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
}

/// Raw transfer seam, so verification and cancellation can be tested without the network.
protocol DownloadTransport: Sendable {
    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    func transfer(from url: URL, reporting: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
}

extension DownloadTransport {
    /// Fraction-only transports (test stubs) report a ratio without byte counts.
    func transfer(from url: URL, reporting: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        try await download(from: url) { reporting(DownloadProgress(fractionCompleted: $0)) }
    }
}

/// URLSession-backed downloader with progress and cancellation.
///
/// Security: only HTTPS URLs are accepted, and redirects to non-HTTPS URLs are refused.
/// The downloaded file goes through `DownloadVerifier`: relocation into a private 0700
/// directory, quarantine (M-4), SHA-256 / SHA-512 checksums, and EdDSA — a Sparkle update for an
/// app that ships `SUPublicEDKey` must carry a valid signature (M-1). A rejected file is deleted.
public struct ProgressDownloader: DetailedProgressDownloading {

    private static let logger = Logger(subsystem: "com.macappupdater", category: "ProgressDownloader")

    private let transport: any DownloadTransport
    private let verifier: DownloadVerifier
    private let checksum: ChecksumLookup

    /// - Parameter checksum: expected digest per update; pass `ChecksumStore.lookup` to verify
    ///   electron-builder SHA-512 digests. Defaults to the update's `sha256` field.
    public init(
        publicEDKey: @escaping PublicKeyLookup = { _ in nil },
        checksum: @escaping ChecksumLookup = ExpectedChecksum.updateSHA256,
        configuration: URLSessionConfiguration = .default
    ) {
        self.init(
            transport: URLSessionDownloadTransport(configuration: configuration),
            publicEDKey: publicEDKey,
            checksum: checksum
        )
    }

    init(
        transport: any DownloadTransport,
        publicEDKey: @escaping PublicKeyLookup = { _ in nil },
        checksum: @escaping ChecksumLookup = ExpectedChecksum.updateSHA256
    ) {
        self.transport = transport
        self.verifier = DownloadVerifier(publicEDKey: publicEDKey)
        self.checksum = checksum
    }

    public func download(_ update: AvailableUpdate) async throws -> URL {
        try await download(update, progress: { _ in })
    }

    public func download(
        _ update: AvailableUpdate,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await downloadReporting(update, reporting: { report in
            if let fraction = report.fractionCompleted { progress(fraction) }
        })
    }

    public func downloadReporting(
        _ update: AvailableUpdate,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        try DownloadVerifier.requireHTTPS(update.downloadURL)
        let expected = await checksum(update)
        try Task.checkCancellation()
        let temporaryURL = try await transport.transfer(from: update.downloadURL, reporting: reporting)
        do {
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        let fileURL = try verifier.finalize(temporaryURL, for: update, expected: expected)
        reporting(DownloadProgress(fractionCompleted: 1))
        Self.logger.info("Downloaded \(update.id, privacy: .public)")
        return fileURL
    }
}

// MARK: - URLSession transport

struct URLSessionDownloadTransport: DownloadTransport {
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration)
    }

    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await transfer(from: url, reporting: { report in
            if let fraction = report.fractionCompleted { progress(fraction) }
        })
    }

    func transfer(from url: URL, reporting: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let delegate = DownloadTaskDelegate(progress: reporting)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                task.delegate = delegate
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Per-task delegate. All mutable state lives behind a lock, which makes the class `Sendable`.
final class DownloadTaskDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, any Error>?
        var task: URLSessionDownloadTask?
        var isCancelled = false
    }

    private static let logger = Logger(subsystem: "com.macappupdater", category: "ProgressDownloader")

    private let progress: @Sendable (DownloadProgress) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.progress = progress
    }

    /// Stores the continuation and resumes the task, unless cancellation already happened.
    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URL, any Error>) {
        let wasCancelled = state.withLock { state -> Bool in
            state.task = task
            state.continuation = continuation
            return state.isCancelled
        }
        if wasCancelled {
            task.cancel()
            finish(.failure(CancellationError()))
        } else {
            task.resume()
        }
    }

    func cancel() {
        let task = state.withLock { state -> URLSessionDownloadTask? in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
        if task != nil { finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<URL, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<URL, any Error>? in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(DownloadProgress(
            receivedBytes: totalBytesWritten,
            expectedBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        ))
    }

    /// The system deletes `location` when this returns, so the file is moved synchronously.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdaterError.network("HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.absoluteString ?? "download")")))
            return
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdaterDownload-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(UpdaterError.network("Cannot keep downloaded file: \(error.localizedDescription)")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        let isCancelled = state.withLock { $0.isCancelled }
        if isCancelled || (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            Self.logger.error("Download failed: \(error.localizedDescription, privacy: .public)")
            finish(.failure(UpdaterError.network(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            Self.logger.error("Refusing non-HTTPS redirect to host \(request.url?.host ?? "?", privacy: .public) (\(request.url?.absoluteString ?? "?", privacy: .private))")
            completionHandler(nil)
            task.cancel()
            finish(.failure(UpdaterError.network("Refusing non-HTTPS redirect")))
            return
        }
        completionHandler(request)
    }
}
