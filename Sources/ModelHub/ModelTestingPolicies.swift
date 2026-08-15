import Foundation
import ModelHubCore

enum ModelTestCatalogRefreshScope {
    case singleModel
    case batch
}

enum ModelTestCatalogRefreshPolicy {
    static func shouldRefreshCatalog(for scope: ModelTestCatalogRefreshScope) -> Bool {
        switch scope {
        case .singleModel: false
        case .batch: true
        }
    }
}

struct ModelProbeResult: Sendable {
    let record: ModelHealthRecord
    let transientNetworkFailure: Bool
    let attemptCount: Int
    let deferredNativeProbe: Bool

    init(
        providerID: UUID,
        model: String,
        status: ModelAvailability,
        checkedAt: Date = .now,
        latencyMilliseconds: Int? = nil,
        statusCode: Int? = nil,
        detail: String = "",
        transientNetworkFailure: Bool = false,
        attemptCount: Int = 0,
        deferredNativeProbe: Bool = false
    ) {
        self.record = ModelHealthRecord(
            providerID: providerID,
            model: model,
            status: status,
            checkedAt: checkedAt,
            latencyMilliseconds: latencyMilliseconds,
            statusCode: statusCode,
            detail: detail
        )
        self.transientNetworkFailure = transientNetworkFailure
        self.attemptCount = max(0, attemptCount)
        self.deferredNativeProbe = deferredNativeProbe
    }
}

struct ModelTestRunAccumulator: Sendable {
    let id: UUID
    let total: Int
    let providerID: UUID?
    let startedAt: Date
    private(set) var completed = 0
    private(set) var available = 0
    private(set) var unavailable = 0
    private(set) var skipped = 0
    private(set) var preservedAvailable = 0
    private(set) var transientFailures = 0
    private(set) var retryAttempts = 0
    private(set) var circuitOpenedProviderIDs: Set<UUID> = []
    private(set) var circuitSkipped = 0

    init(
        id: UUID = UUID(),
        total: Int,
        providerID: UUID?,
        startedAt: Date = .now
    ) {
        self.id = id
        self.total = max(0, total)
        self.providerID = providerID
        self.startedAt = startedAt
    }

    mutating func observe(
        _ result: ModelProbeResult,
        preservedAvailable wasPreserved: Bool
    ) {
        completed += 1
        retryAttempts += max(0, result.attemptCount - 1)
        if result.transientNetworkFailure {
            transientFailures += 1
        }
        if wasPreserved {
            preservedAvailable += 1
            skipped += 1
            return
        }
        switch result.record.status {
        case .available:
            available += 1
        case .unavailable:
            unavailable += 1
        case .unknown, .configurationRequired, .unsupported:
            skipped += 1
        }
    }

    mutating func observeCircuitOpened(providerID: UUID, skipped count: Int) {
        circuitOpenedProviderIDs.insert(providerID)
        let boundedCount = max(0, count)
        circuitSkipped += boundedCount
        skipped += boundedCount
        completed += boundedCount
    }

    mutating func observePreflightSkipped(_ count: Int) {
        let boundedCount = max(0, count)
        skipped += boundedCount
        completed += boundedCount
    }

    func activity(completedAt: Date = .now, cancelled: Bool) -> ModelHealthActivity {
        ModelHealthActivity(
            id: id,
            kind: .probe,
            startedAt: startedAt,
            completedAt: completedAt,
            providerID: providerID,
            total: total,
            completed: completed,
            available: available,
            unavailable: unavailable,
            skipped: skipped,
            preservedAvailable: preservedAvailable,
            transientFailures: transientFailures,
            retryAttempts: retryAttempts,
            circuitOpenedProviderIDs: Array(circuitOpenedProviderIDs),
            circuitSkipped: circuitSkipped,
            cancelled: cancelled
        )
    }
}

enum ModelTestHealthUpdatePolicy {
    static func shouldPreserve(
        existing: ModelHealthRecord?,
        after result: ModelProbeResult
    ) -> Bool {
        (result.transientNetworkFailure && existing?.status == .available)
            || (result.deferredNativeProbe && existing != nil)
    }
}

struct ModelTestProviderCircuitBreaker {
    private static let postCanaryTransientThreshold = 2
    private var suspendedProviderIDs: Set<UUID> = []
    private var consecutiveTransientBatchesByProviderID: [UUID: Int] = [:]

    func shouldSkip(providerID: UUID) -> Bool {
        suspendedProviderIDs.contains(providerID)
    }

    @discardableResult
    mutating func observe(
        providerID: UUID,
        wasCanary: Bool,
        transientNetworkFailures: [Bool]
    ) -> Bool {
        guard !transientNetworkFailures.isEmpty else { return false }
        let allTransient = transientNetworkFailures.allSatisfy { $0 }
        if wasCanary {
            consecutiveTransientBatchesByProviderID[providerID] = allTransient ? 1 : 0
            guard allTransient else { return false }
            suspendedProviderIDs.insert(providerID)
            return true
        }
        guard allTransient else {
            consecutiveTransientBatchesByProviderID[providerID] = 0
            return false
        }
        let consecutive = (consecutiveTransientBatchesByProviderID[providerID] ?? 0) + 1
        consecutiveTransientBatchesByProviderID[providerID] = consecutive
        let shouldSuspend = consecutive >= Self.postCanaryTransientThreshold
        guard shouldSuspend else { return false }
        suspendedProviderIDs.insert(providerID)
        return true
    }
}

enum ModelTestCircuitDiagnostics {
    static func latestBlockingActivity(
        providerID: UUID,
        activities: [ModelHealthActivity]
    ) -> ModelHealthActivity? {
        let latestRelevantProbe = activities
            .filter { activity in
                activity.kind == .probe
                    && (activity.providerID == nil || activity.providerID == providerID)
            }
            .max { lhs, rhs in
                if lhs.completedAt == rhs.completedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.completedAt < rhs.completedAt
            }
        guard let latestRelevantProbe,
              latestRelevantProbe.transientFailures > 0,
              latestRelevantProbe.circuitSkipped > 0,
              latestRelevantProbe.circuitOpenedProviderIDs.contains(providerID)
        else { return nil }
        return latestRelevantProbe
    }
}
