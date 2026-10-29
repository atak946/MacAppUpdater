import Foundation
import MonitorCore

/// Fixed-size history of samples; the oldest value drops off once `capacity` is reached.
struct SampleHistory: Equatable, Sendable {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var latest: Double? { values.last }
    var peak: Double { values.max() ?? 0 }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

/// What a visible screen needs sampled. Higher demands include the lower ones.
enum MonitorDemand: Int, Comparable, Sendable, CaseIterable {
    /// Whole-machine stats only (menu bar strip).
    case system
    /// Plus the process list (System page top consumers).
    case processes
    /// Plus listening ports (Processes page).
    case ports

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension ProcessGroup {
    /// Unique listening ports of all members, ascending.
    func listeningPorts(in ports: [Int32: [ListeningPort]]) -> [UInt16] {
        Array(Set(processes.flatMap { (ports[$0.pid] ?? []).map(\.port) })).sorted()
    }
}
