import Foundation

/// Parses `nettop -P -L 1 -J bytes_in,bytes_out -x` CSV into cumulative byte counters per pid.
enum NettopOutputParser {
    /// Lines look like `Google Chrome H.4987,57195,84058,`: a name truncated to 15 characters
    /// (it may contain spaces and dots), a dot, the pid, then the two counters. The header row
    /// (`,bytes_in,bytes_out,`) and malformed lines are skipped; a pid seen twice is summed.
    static func parse(_ output: String) -> [Int32: NetworkCounters] {
        var counters: [Int32: NetworkCounters] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let row = row(from: line) else { continue }
            let previous = counters[row.pid] ?? NetworkCounters(bytesIn: 0, bytesOut: 0)
            counters[row.pid] = NetworkCounters(bytesIn: previous.bytesIn &+ row.bytesIn,
                                                bytesOut: previous.bytesOut &+ row.bytesOut)
        }
        return counters
    }

    static func row(from line: Substring) -> (pid: Int32, bytesIn: UInt64, bytesOut: UInt64)? {
        // Read from the right: the name may contain commas in theory, the numbers never do.
        var fields = line.split(separator: ",", omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count >= 3,
              let bytesOut = UInt64(fields[fields.count - 1]),
              let bytesIn = UInt64(fields[fields.count - 2]) else { return nil }
        let label = fields[..<(fields.count - 2)].joined(separator: ",")
        guard let dot = label.lastIndex(of: "."),
              let pid = Int32(label[label.index(after: dot)...]), pid >= 0 else { return nil }
        return (pid, bytesIn, bytesOut)
    }
}
