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

public actor ResilienceController {
    private struct TargetState {
        var inFlight = 0
        var consecutiveFailures = 0
        var circuitOpenUntil: Date?
    }

    private var gatewayRequestDates: [Date] = []
    private var targets: [TargetRuntimeKey: TargetState] = [:]

    public init() {}

    public func admitGatewayRequest(
        settings: ResilienceSettings,
        now: Date = .now
    ) -> GatewayAdmission {
        let oneMinuteAgo = now.addingTimeInterval(-60)
        gatewayRequestDates.removeAll { $0 <= oneMinuteAgo }
        let limit = max(1, settings.requestsPerMinute)
        guard gatewayRequestDates.count < limit else {
            let retry = gatewayRequestDates.first.map {
                max(1, Int(ceil($0.addingTimeInterval(60).timeIntervalSince(now))))
            } ?? 1
            return .rateLimited(retryAfterSeconds: retry)
        }
        gatewayRequestDates.append(now)
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
                let retry = max(1, Int(ceil(openUntil.timeIntervalSince(now))))
                return .circuitOpen(retryAfterSeconds: retry)
            }
            state.circuitOpenUntil = nil
            state.consecutiveFailures = 0
        }
        guard state.inFlight < max(1, settings.maxConcurrentRequestsPerTarget) else {
            return .concurrencyLimited
        }
        state.inFlight += 1
        targets[key] = state
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
            state.consecutiveFailures = 0
            state.circuitOpenUntil = nil
        } else if transientFailure {
            state.consecutiveFailures += 1
            if state.consecutiveFailures >= max(1, settings.failureThreshold) {
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
