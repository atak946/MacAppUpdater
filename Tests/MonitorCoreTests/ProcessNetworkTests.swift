import Foundation
import Testing
@testable import MonitorCore

// MARK: - nettop parser

@Suite("nettop parser")
struct NettopOutputParserTests {
    /// Trimmed `nettop -P -L 1 -n -J bytes_in,bytes_out -x` output from macOS 26, with app names replaced.
    /// Kept quirks: header row, trailing commas, names truncated to 15 characters with spaces,
    /// names that contain dots or look like version numbers, and large cumulative counters.
    static let fixture = """
    ,bytes_in,bytes_out,
    launchd.1,0,0,
    syslogd.555,0,20906,
    apsd.561,7035618,539409,
    mDNSResponder.653,946614616,825184920,
    2.1.312.98554,1263710,8816395,
    Example Browser.49870,57195,84058,
    Example Browser.20276,5650809,7075,
    helper.arm64.4410,312,0,
    """

    @Test("rows by pid from the right, header and quirks handled")
    func parse() {
        let counters = NettopOutputParser.parse(Self.fixture)
        #expect(counters.count == 8)
        #expect(counters[1] == NetworkCounters(bytesIn: 0, bytesOut: 0))
        #expect(counters[653] == NetworkCounters(bytesIn: 946_614_616, bytesOut: 825_184_920))
        #expect(counters[98554] == NetworkCounters(bytesIn: 1_263_710, bytesOut: 8_816_395))
        #expect(counters[49870] == NetworkCounters(bytesIn: 57195, bytesOut: 84058))
        #expect(counters[4410] == NetworkCounters(bytesIn: 312, bytesOut: 0))
    }

    @Test("malformed lines are skipped; a repeated pid is summed")
    func malformed() {
        let output = """
        ,bytes_in,bytes_out,
        nopid,1,2,
        name.12,abc,2,
        name.13,5
        odd,name.14,7,8,
        dup.15,1,2,
        dup.15,10,20,
        """
        let counters = NettopOutputParser.parse(output)
        #expect(counters == [
            14: NetworkCounters(bytesIn: 7, bytesOut: 8),
            15: NetworkCounters(bytesIn: 11, bytesOut: 22),
        ])
        #expect(NettopOutputParser.parse("").isEmpty)
    }
}

// MARK: - Rates

@Suite("Per-process network rates")
struct ProcessNetworkRateTests {
    private static let second: UInt64 = 1_000_000_000

    @Test("rates from deltas; new and gone pids dropped; resets yield 0")
    func deltas() {
        let previous: [Int32: NetworkCounters] = [
            1: NetworkCounters(bytesIn: 1000, bytesOut: 500),
            2: NetworkCounters(bytesIn: 10, bytesOut: 10),
            3: NetworkCounters(bytesIn: 9000, bytesOut: 9000),
        ]
        let current: [Int32: NetworkCounters] = [
            1: NetworkCounters(bytesIn: 3000, bytesOut: 1500),
            3: NetworkCounters(bytesIn: 100, bytesOut: 9400),
            4: NetworkCounters(bytesIn: 5000, bytesOut: 5000),
        ]
        let rates = NetworkMath.throughput(previous: previous, current: current, elapsed: 2)
        #expect(rates == [
            1: NetworkThroughput(bytesInPerSecond: 1000, bytesOutPerSecond: 500),
            3: NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 200),
        ])
        #expect(NetworkMath.throughput(previous: previous, current: current, elapsed: 0).isEmpty)
    }

    @Test("sampler: first read and stale reads are baselines")
    func baselines() async {
        let sampler = NettopNetworkSampler(maxInterval: 30)
        let first: [Int32: NetworkCounters] = [7: NetworkCounters(bytesIn: 0, bytesOut: 0)]
        let second: [Int32: NetworkCounters] = [7: NetworkCounters(bytesIn: 6000, bytesOut: 600)]

        #expect(await sampler.record(first, at: 10 * Self.second) == nil)
        #expect(await sampler.record(second, at: 16 * Self.second) == [
            7: NetworkThroughput(bytesInPerSecond: 1000, bytesOutPerSecond: 100),
        ])
        // Hidden for a minute: the delta is too old to average, so this read only re-baselines.
        #expect(await sampler.record(second, at: 76 * Self.second) == nil)
        #expect(await sampler.record(second, at: 82 * Self.second)?[7]?.bytesInPerSecond == 0)
    }
}
