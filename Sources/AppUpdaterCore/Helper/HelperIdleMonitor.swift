import Dispatch
import Foundation
import os

/// Calls `onIdle` once nothing (connection or install) has been active for `timeout`.
///
/// The privileged helper uses it to exit when unused; launchd relaunches it on demand
/// via its Mach service.
public final class HelperIdleMonitor: Sendable {
    private struct State {
        var activeCount = 0
        var generation: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "\(HelperConstants.machServiceName).idle")
    private let onIdle: @Sendable () -> Void

    public init(timeout: TimeInterval = HelperConstants.idleExitSeconds, onIdle: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onIdle = onIdle
    }

    /// Arms the timer for the initial idle period (no connection yet).
    public func start() {
        let generation = state.withLock { $0.activeCount == 0 ? $0.generation : nil }
        if let generation { schedule(generation) }
    }

    public func begin() {
        state.withLock {
            $0.activeCount += 1
            $0.generation &+= 1
        }
    }

    public func end() {
        let generation = state.withLock { state -> UInt64? in
            state.activeCount = max(0, state.activeCount - 1)
            state.generation &+= 1
            return state.activeCount == 0 ? state.generation : nil
        }
        if let generation { schedule(generation) }
    }

    public var activeCount: Int { state.withLock { $0.activeCount } }

    private func schedule(_ generation: UInt64) {
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            let stillIdle = state.withLock { $0.activeCount == 0 && $0.generation == generation }
            if stillIdle { onIdle() }
        }
    }
}
