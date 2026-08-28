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
    case circuitOpen(retryAfterSeconds: Int)
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
}

public actor ResilienceController {
    private struct TargetState {
        var inFlight = 0
        var consecutiveFailures = 0
        var circuitOpenUntil: Date?
    }

    private var gatewayRequestDates: [Date] = []
    private var targets: [TargetRuntimeKey: TargetState] = [:]
    private var gatewayAllowed: UInt64 = 0
    private var gatewayRateLimited: UInt64 = 0
    private var targetAllowed: UInt64 = 0
    private var targetConcurrencyLimited: UInt64 = 0
    private var targetCircuitRejected: UInt64 = 0
    private var circuitsOpened: UInt64 = 0
    private var transientFailures: UInt64 = 0
    private var successfulTargets: UInt64 = 0

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
    }

    public func snapshot(for key: TargetRuntimeKey) -> TargetRuntimeSnapshot {
        let state = targets[key] ?? TargetState()
        return TargetRuntimeSnapshot(
            inFlight: state.inFlight,
            consecutiveFailures: state.consecutiveFailures,
            circuitOpenUntil: state.circuitOpenUntil
        )
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
            successfulTargets: successfulTargets
        )
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
