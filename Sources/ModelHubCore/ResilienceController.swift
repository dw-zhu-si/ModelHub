import Foundation

public struct TargetRuntimeKey: Hashable, Sendable {
    public let providerID: UUID
    public let model: String

    public init(providerID: UUID, model: String) {
        self.providerID = providerID
        self.model = model
    }
}

public enum GatewayAdmission: Equatable, Sendable {
    case allowed
    case rateLimited(retryAfterSeconds: Int)
}

public enum TargetAdmission: Equatable, Sendable {
    case allowed
    case concurrencyLimited
    case queueFull
    case queueTimedOut
    case cancelled
    case circuitOpen(retryAfterSeconds: Int)
}

public struct TargetQueueSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var capacityPerTarget: Int
    public var maximumWaitMilliseconds: Int

    public init(
        enabled: Bool = false,
        capacityPerTarget: Int = 0,
        maximumWaitMilliseconds: Int = 5_000
    ) {
        self.enabled = enabled
        self.capacityPerTarget = min(128, max(0, capacityPerTarget))
        self.maximumWaitMilliseconds = min(30_000, max(1, maximumWaitMilliseconds))
    }

    public var sanitized: Self {
        .init(
            enabled: enabled,
            capacityPerTarget: capacityPerTarget,
            maximumWaitMilliseconds: maximumWaitMilliseconds
        )
    }
}

public struct TargetQueueSnapshot: Equatable, Sendable {
    public let waiting: Int
    public let activeScopes: Int
}

public struct TargetRuntimeSnapshot: Equatable, Sendable {
    public let inFlight: Int
    public let consecutiveFailures: Int
    public let circuitOpenUntil: Date?
}

public struct ResilienceMetricsSnapshot: Equatable, Sendable {
    public let gatewayAllowed: UInt64
    public let gatewayRateLimited: UInt64
    public let targetAllowed: UInt64
    public let targetConcurrencyLimited: UInt64
    public let targetCircuitRejected: UInt64
    public let circuitsOpened: UInt64
    public let transientFailures: UInt64
    public let successfulTargets: UInt64
    public let queuedWaiting: Int
    public let queuedAccepted: UInt64
    public let queueFullRejected: UInt64
    public let queueTimedOut: UInt64
    public let queueCancelled: UInt64
}

public actor ResilienceController {
    private struct TargetState {
        var inFlight = 0
        var consecutiveFailures = 0
        var circuitOpenUntil: Date?
    }

    private struct TargetWaiter {
        let id: UUID
        let scope: String
        let continuation: CheckedContinuation<TargetAdmission, Never>
    }

    private struct TargetQueueState {
        var waitersByScope: [String: [TargetWaiter]] = [:]
        var scopeOrder: [String] = []
        var cursor = 0
        var waiting = 0
    }

    private var gatewayRequestDates: [Date] = []
    private var targets: [TargetRuntimeKey: TargetState] = [:]
    private var targetQueues: [TargetRuntimeKey: TargetQueueState] = [:]
    private var gatewayAllowed: UInt64 = 0
    private var gatewayRateLimited: UInt64 = 0
    private var targetAllowed: UInt64 = 0
    private var targetConcurrencyLimited: UInt64 = 0
    private var targetCircuitRejected: UInt64 = 0
    private var circuitsOpened: UInt64 = 0
    private var transientFailures: UInt64 = 0
    private var successfulTargets: UInt64 = 0
    private var queuedAccepted: UInt64 = 0
    private var queueFullRejected: UInt64 = 0
    private var queueTimedOut: UInt64 = 0
    private var queueCancelled: UInt64 = 0

    public init() {}

    public func admitGatewayRequest(
        settings: ResilienceSettings,
        now: Date = .now
    ) -> GatewayAdmission {
        let oneMinuteAgo = now.addingTimeInterval(-60)
        gatewayRequestDates.removeAll { $0 <= oneMinuteAgo }
        let limit = max(1, settings.requestsPerMinute)
        guard gatewayRequestDates.count < limit else {
            gatewayRateLimited &+= 1
            let retry = gatewayRequestDates.first.map {
                max(1, Int(ceil($0.addingTimeInterval(60).timeIntervalSince(now))))
            } ?? 1
            return .rateLimited(retryAfterSeconds: retry)
        }
        gatewayRequestDates.append(now)
        gatewayAllowed &+= 1
        return .allowed
    }

    public func beginTarget(
        _ key: TargetRuntimeKey,
        settings: ResilienceSettings,
        now: Date = .now
    ) -> TargetAdmission {
        var state = targets[key] ?? TargetState()
        if let openUntil = state.circuitOpenUntil {
            if openUntil > now {
                targetCircuitRejected &+= 1
                let retry = max(1, Int(ceil(openUntil.timeIntervalSince(now))))
                return .circuitOpen(retryAfterSeconds: retry)
            }
            state.circuitOpenUntil = nil
            state.consecutiveFailures = 0
        }
        guard state.inFlight < max(1, settings.maxConcurrentRequestsPerTarget) else {
            targetConcurrencyLimited &+= 1
            return .concurrencyLimited
        }
        state.inFlight += 1
        targets[key] = state
        targetAllowed &+= 1
        return .allowed
    }

    /// Acquires a target slot, optionally waiting in a bounded queue that rotates
    /// between access scopes. The access scope must be a non-secret stable ID
    /// (for example, a virtual-key UUID), never a bearer token.
    public func acquireTarget(
        _ key: TargetRuntimeKey,
        accessScope: String,
        settings: ResilienceSettings,
        queue: TargetQueueSettings,
        now: Date = .now
    ) async -> TargetAdmission {
        let immediate = beginTarget(key, settings: settings, now: now)
        guard immediate == .concurrencyLimited else { return immediate }
        guard queue.enabled, queue.capacityPerTarget > 0 else { return immediate }

        let currentWaiting = targetQueues[key]?.waiting ?? 0
        guard currentWaiting < queue.capacityPerTarget else {
            queueFullRejected &+= 1
            return .queueFull
        }

        let waiterID = UUID()
        let normalizedScope = accessScope.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeScope = normalizedScope.isEmpty ? "primary" : normalizedScope
        let timeout = queue.maximumWaitMilliseconds

        return await withTaskCancellationHandler {
            if Task.isCancelled { return .cancelled }
            return await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                enqueue(
                    TargetWaiter(id: waiterID, scope: safeScope, continuation: continuation),
                    for: key
                )
                Task {
                    try? await Task.sleep(for: .milliseconds(timeout))
                    self.expireWaiter(waiterID, for: key)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key) }
        }
    }

    public func finishTarget(
        _ key: TargetRuntimeKey,
        succeeded: Bool,
        transientFailure: Bool,
        settings: ResilienceSettings,
        now: Date = .now
    ) {
        var state = targets[key] ?? TargetState()
        state.inFlight = max(0, state.inFlight - 1)
        if succeeded {
            successfulTargets &+= 1
            state.consecutiveFailures = 0
            state.circuitOpenUntil = nil
        } else if transientFailure {
            transientFailures &+= 1
            state.consecutiveFailures += 1
            if state.consecutiveFailures >= max(1, settings.failureThreshold) {
                if state.circuitOpenUntil == nil || state.circuitOpenUntil! <= now {
                    circuitsOpened &+= 1
                }
                state.circuitOpenUntil = now.addingTimeInterval(
                    TimeInterval(max(1, settings.cooldownSeconds))
                )
            }
        }
        targets[key] = state

        if let openUntil = state.circuitOpenUntil, openUntil > now {
            drainQueue(
                for: key,
                with: .circuitOpen(
                    retryAfterSeconds: max(1, Int(ceil(openUntil.timeIntervalSince(now))))
                )
            )
        } else if state.inFlight < max(1, settings.maxConcurrentRequestsPerTarget) {
            grantNextWaiter(for: key)
        }
    }

    public func snapshot(for key: TargetRuntimeKey) -> TargetRuntimeSnapshot {
        let state = targets[key] ?? TargetState()
        return TargetRuntimeSnapshot(
            inFlight: state.inFlight,
            consecutiveFailures: state.consecutiveFailures,
            circuitOpenUntil: state.circuitOpenUntil
        )
    }

    public func queueSnapshot(for key: TargetRuntimeKey) -> TargetQueueSnapshot {
        let queue = targetQueues[key] ?? TargetQueueState()
        return TargetQueueSnapshot(waiting: queue.waiting, activeScopes: queue.scopeOrder.count)
    }

    public func metrics() -> ResilienceMetricsSnapshot {
        ResilienceMetricsSnapshot(
            gatewayAllowed: gatewayAllowed,
            gatewayRateLimited: gatewayRateLimited,
            targetAllowed: targetAllowed,
            targetConcurrencyLimited: targetConcurrencyLimited,
            targetCircuitRejected: targetCircuitRejected,
            circuitsOpened: circuitsOpened,
            transientFailures: transientFailures,
            successfulTargets: successfulTargets,
            queuedWaiting: targetQueues.values.reduce(0) { $0 + $1.waiting },
            queuedAccepted: queuedAccepted,
            queueFullRejected: queueFullRejected,
            queueTimedOut: queueTimedOut,
            queueCancelled: queueCancelled
        )
    }

    private func enqueue(_ waiter: TargetWaiter, for key: TargetRuntimeKey) {
        var queue = targetQueues[key] ?? TargetQueueState()
        if queue.waitersByScope[waiter.scope] == nil {
            queue.waitersByScope[waiter.scope] = []
            queue.scopeOrder.append(waiter.scope)
        }
        queue.waitersByScope[waiter.scope, default: []].append(waiter)
        queue.waiting += 1
        targetQueues[key] = queue
        queuedAccepted &+= 1
    }

    private func grantNextWaiter(for key: TargetRuntimeKey) {
        guard let waiter = dequeueNextWaiter(for: key) else { return }
        var state = targets[key] ?? TargetState()
        state.inFlight += 1
        targets[key] = state
        targetAllowed &+= 1
        waiter.continuation.resume(returning: .allowed)
    }

    private func dequeueNextWaiter(for key: TargetRuntimeKey) -> TargetWaiter? {
        guard var queue = targetQueues[key], queue.waiting > 0, !queue.scopeOrder.isEmpty else {
            targetQueues.removeValue(forKey: key)
            return nil
        }

        queue.cursor = min(queue.cursor, max(0, queue.scopeOrder.count - 1))
        let scope = queue.scopeOrder[queue.cursor]
        guard var scopeWaiters = queue.waitersByScope[scope], !scopeWaiters.isEmpty else {
            queue.waitersByScope.removeValue(forKey: scope)
            queue.scopeOrder.remove(at: queue.cursor)
            if !queue.scopeOrder.isEmpty { queue.cursor %= queue.scopeOrder.count }
            targetQueues[key] = queue
            return dequeueNextWaiter(for: key)
        }

        let waiter = scopeWaiters.removeFirst()
        queue.waiting -= 1
        if scopeWaiters.isEmpty {
            queue.waitersByScope.removeValue(forKey: scope)
            queue.scopeOrder.remove(at: queue.cursor)
            if !queue.scopeOrder.isEmpty { queue.cursor %= queue.scopeOrder.count }
        } else {
            queue.waitersByScope[scope] = scopeWaiters
            queue.cursor = (queue.cursor + 1) % queue.scopeOrder.count
        }

        if queue.waiting == 0 {
            targetQueues.removeValue(forKey: key)
        } else {
            targetQueues[key] = queue
        }
        return waiter
    }

    private func expireWaiter(_ waiterID: UUID, for key: TargetRuntimeKey) {
        guard let waiter = removeWaiter(waiterID, for: key) else { return }
        queueTimedOut &+= 1
        waiter.continuation.resume(returning: .queueTimedOut)
    }

    private func cancelWaiter(_ waiterID: UUID, for key: TargetRuntimeKey) {
        guard let waiter = removeWaiter(waiterID, for: key) else { return }
        queueCancelled &+= 1
        waiter.continuation.resume(returning: .cancelled)
    }

    private func removeWaiter(_ waiterID: UUID, for key: TargetRuntimeKey) -> TargetWaiter? {
        guard var queue = targetQueues[key] else { return nil }
        for (scopeIndex, scope) in queue.scopeOrder.enumerated() {
            guard var waiters = queue.waitersByScope[scope],
                  let waiterIndex = waiters.firstIndex(where: { $0.id == waiterID })
            else { continue }

            let waiter = waiters.remove(at: waiterIndex)
            queue.waiting -= 1
            if waiters.isEmpty {
                queue.waitersByScope.removeValue(forKey: scope)
                queue.scopeOrder.remove(at: scopeIndex)
                if queue.scopeOrder.isEmpty {
                    queue.cursor = 0
                } else if scopeIndex < queue.cursor {
                    queue.cursor -= 1
                } else {
                    queue.cursor %= queue.scopeOrder.count
                }
            } else {
                queue.waitersByScope[scope] = waiters
            }

            if queue.waiting == 0 {
                targetQueues.removeValue(forKey: key)
            } else {
                targetQueues[key] = queue
            }
            return waiter
        }
        return nil
    }

    private func drainQueue(for key: TargetRuntimeKey, with result: TargetAdmission) {
        guard let queue = targetQueues.removeValue(forKey: key) else { return }
        for scope in queue.scopeOrder {
            for waiter in queue.waitersByScope[scope] ?? [] {
                waiter.continuation.resume(returning: result)
            }
        }
    }

    public nonisolated static func backoffDuration(
        attempt: Int,
        baseMilliseconds: Int
    ) -> Duration {
        let exponent = min(max(0, attempt), 8)
        let base = max(0, baseMilliseconds)
        let milliseconds = min(30_000, base * (1 << exponent))
        return .milliseconds(milliseconds)
    }
}
