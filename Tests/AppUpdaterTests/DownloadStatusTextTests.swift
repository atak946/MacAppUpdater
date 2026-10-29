import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

@Suite("DownloadStatus")
struct DownloadStatusTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("shows received of total, percent, speed and time left")
    func full() {
        let status = DownloadStatus(
            progress: DownloadProgress(receivedBytes: 100_000_000, expectedBytes: 1_000_000_000),
            startedAt: start, now: start.addingTimeInterval(10)
        )
        #expect(status.fraction == 0.1)
        #expect(status.total != nil && status.received != nil)
        #expect(status.speed?.hasSuffix("/s") == true || status.speed?.hasSuffix("/sn") == true)
        #expect(status.remaining != nil)
        #expect(status.summary.components(separatedBy: " · ").count == 3)
    }

    @Test("the pre-download size fills in when the transfer reports no length")
    func knownSizeFallback() {
        let status = DownloadStatus(
            progress: DownloadProgress(receivedBytes: 250, expectedBytes: nil), knownSize: 1_000,
            startedAt: start, now: start.addingTimeInterval(5)
        )
        #expect(status.fraction == 0.25)
        #expect(status.total != nil)
    }

    @Test("unknown size: no fraction, received bytes and speed only")
    func unknownSize() {
        let status = DownloadStatus(
            progress: DownloadProgress(receivedBytes: 5_000_000, expectedBytes: nil),
            startedAt: start, now: start.addingTimeInterval(5)
        )
        #expect(status.fraction == nil)
        #expect(status.total == nil)
        #expect(status.remaining == nil)
        #expect(status.speed != nil)
    }

    @Test("before the first byte only the known total shows; no speed in the first second")
    func early() {
        let waiting = DownloadStatus(
            progress: DownloadProgress(receivedBytes: 0, expectedBytes: nil), knownSize: 2_000, startedAt: start
        )
        #expect(waiting.fraction == nil)
        #expect(waiting.amount == waiting.total)
        let fresh = DownloadStatus(
            progress: DownloadProgress(receivedBytes: 1_000, expectedBytes: 10_000),
            startedAt: start, now: start.addingTimeInterval(0.2)
        )
        #expect(fresh.rate == nil)
    }

    @Test("fraction comes from bytes, or from an explicit ratio")
    func fraction() {
        #expect(DownloadProgress(receivedBytes: 25, expectedBytes: 100).fractionCompleted == 0.25)
        #expect(DownloadProgress(fractionCompleted: 1.4).fractionCompleted == 1)
    }
}
