import Foundation
import XCTest
@testable import ModelHubCore

final class PassiveHealthMonitoringTests: XCTestCase {
    func testRateLimitSaturationIsRecordedWithoutTriggeringProviderFailure() async {
        let monitor = PassiveHealthMonitor(
            configuration: .init(
                eventLimit: 200,
                windowSize: 3,
                failureThreshold: 3,
                cooldownSeconds: 0
            )
        )
        let providerID = UUID()

        for offset in 0..<3 {
            let alert = await monitor.record(PassiveHealthEvent(
                providerID: providerID,
                targetID: "quota-limited-model",
                outcome: .http(statusCode: 429),
                latencyMilliseconds: 50,
                recordedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            ))
            XCTAssertNil(alert)
        }

        let history = await monitor.history()
        let alerts = await monitor.activeAlerts()
        XCTAssertEqual(history.count, 3)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testRateLimitSaturationDoesNotFalselyRecoverAnActiveFailure() async {
        let monitor = PassiveHealthMonitor(
            configuration: .init(
                eventLimit: 20,
                windowSize: 2,
                failureThreshold: 2,
                cooldownSeconds: 0
            )
        )
        let providerID = UUID()
        _ = await monitor.record(failure(providerID, at: 0))
        let failureAlert = await monitor.record(failure(providerID, at: 1))

        let saturationAlert = await monitor.record(PassiveHealthEvent(
            providerID: providerID,
            targetID: "model-a",
            outcome: .http(statusCode: 429),
            latencyMilliseconds: 10,
            recordedAt: Date(timeIntervalSince1970: 2)
        ))

        XCTAssertEqual(failureAlert?.kind, .failureRate)
        XCTAssertNil(saturationAlert)
        let alerts = await monitor.activeAlerts()
        XCTAssertEqual(alerts.map(\.kind), [.failureRate])
    }

    func testRateLimitSaturationDoesNotDisplaceFailureEvidenceFromWindow() async {
        let monitor = PassiveHealthMonitor(
            configuration: .init(
                eventLimit: 20,
                windowSize: 3,
                failureThreshold: 3,
                cooldownSeconds: 0
            )
        )
        let providerID = UUID()

        _ = await monitor.record(failure(providerID, at: 0))
        _ = await monitor.record(failure(providerID, at: 1))
        for offset in 2..<252 {
            let alert = await monitor.record(PassiveHealthEvent(
                providerID: providerID,
                targetID: "model-a",
                outcome: .http(statusCode: 429),
                latencyMilliseconds: 10,
                recordedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            ))
            XCTAssertNil(alert)
        }

        let alert = await monitor.record(failure(providerID, at: 252))
        XCTAssertEqual(alert?.kind, .failureRate)
        XCTAssertEqual(alert?.matchingEventCount, 3)
    }

    func testHistoryIsBoundedToTwoHundredRealRequestEvents() async {
        let monitor = PassiveHealthMonitor()
        let providerID = UUID()

        for offset in 0..<250 {
            _ = await monitor.record(
                PassiveHealthEvent(
                    providerID: providerID,
                    targetID: "model-a",
                    outcome: .http(statusCode: 200),
                    latencyMilliseconds: offset,
                    recordedAt: Date(timeIntervalSince1970: TimeInterval(offset))
                )
            )
        }

        let history = await monitor.history()
        XCTAssertEqual(history.count, 200)
        XCTAssertEqual(history.first?.latencyMilliseconds, 50)
        XCTAssertEqual(history.last?.latencyMilliseconds, 249)
    }

    func testFailureThresholdDeduplicatesDuringCooldownAndSuccessRecovers() async {
        let providerID = UUID()
        let monitor = PassiveHealthMonitor(
            configuration: PassiveHealthConfiguration(
                windowSize: 5,
                failureThreshold: 3,
                highLatencyThreshold: 3,
                highLatencyMilliseconds: 1_000,
                cooldownSeconds: 60
            )
        )

        let firstFailure = await monitor.record(failure(providerID, at: 0))
        let secondFailure = await monitor.record(failure(providerID, at: 1))
        XCTAssertNil(firstFailure)
        XCTAssertNil(secondFailure)
        let degraded = await monitor.record(failure(providerID, at: 2))
        XCTAssertEqual(degraded?.kind, .failureRate)

        let duplicate = await monitor.record(failure(providerID, at: 3))
        XCTAssertNil(duplicate)
        let recovered = await monitor.record(success(providerID, at: 4))
        XCTAssertEqual(recovered?.kind, .recovered)

        let cooldownFirst = await monitor.record(failure(providerID, at: 10))
        let cooldownSecond = await monitor.record(failure(providerID, at: 11))
        let cooldownThird = await monitor.record(failure(providerID, at: 12))
        XCTAssertNil(cooldownFirst)
        XCTAssertNil(cooldownSecond)
        XCTAssertNil(cooldownThird)
        let activeKinds = await monitor.activeAlerts().map(\.kind)
        XCTAssertEqual(activeKinds, [.failureRate])

        let afterCooldown = await monitor.record(failure(providerID, at: 70))
        XCTAssertEqual(afterCooldown?.kind, .failureRate)
    }

    func testOrdinaryClientErrorsDoNotDegradeProviderHealth() async {
        let providerID = UUID()
        let monitor = PassiveHealthMonitor(
            configuration: PassiveHealthConfiguration(
                windowSize: 4,
                failureThreshold: 2,
                highLatencyThreshold: 2,
                highLatencyMilliseconds: 1_000,
                cooldownSeconds: 30
            )
        )

        for (offset, statusCode) in [400, 401, 403, 404, 409, 422].enumerated() {
            let alert = await monitor.record(
                PassiveHealthEvent(
                    providerID: providerID,
                    targetID: "model-a",
                    outcome: .http(statusCode: statusCode),
                    latencyMilliseconds: 5,
                    recordedAt: Date(timeIntervalSince1970: TimeInterval(offset))
                )
            )
            XCTAssertNil(alert)
        }

        let activeAlerts = await monitor.activeAlerts()
        XCTAssertTrue(activeAlerts.isEmpty)
    }

    func testRepeatedHighLatencyAlertsAndFastSuccessRecovers() async {
        let providerID = UUID()
        let monitor = PassiveHealthMonitor(
            configuration: PassiveHealthConfiguration(
                windowSize: 4,
                failureThreshold: 3,
                highLatencyThreshold: 2,
                highLatencyMilliseconds: 500,
                cooldownSeconds: 30
            )
        )

        let firstSlowSample = await monitor.record(success(providerID, at: 0, latency: 700))
        XCTAssertNil(firstSlowSample)
        let latencyAlert = await monitor.record(success(providerID, at: 1, latency: 800))
        XCTAssertEqual(latencyAlert?.kind, .highLatency)
        let duplicate = await monitor.record(success(providerID, at: 2, latency: 900))
        XCTAssertNil(duplicate)

        let recovered = await monitor.record(success(providerID, at: 3, latency: 20))
        XCTAssertEqual(recovered?.kind, .recovered)
        let activeAlerts = await monitor.activeAlerts()
        XCTAssertTrue(activeAlerts.isEmpty)
    }

    func testEventBufferUsesOneBoundedQueueUnderSlowProcessing() async {
        let buffer = BoundedPassiveHealthEventBuffer(capacity: 1) { _ in
            try? await Task.sleep(for: .milliseconds(150))
        }
        let providerID = UUID()
        let event = success(providerID, at: 0)

        let acceptedFirst = await buffer.enqueue(event)
        XCTAssertTrue(acceptedFirst)
        try? await Task.sleep(for: .milliseconds(20))
        let acceptedSecond = await buffer.enqueue(event)
        let acceptedThird = await buffer.enqueue(event)
        let dropped = await buffer.droppedCount()
        let pending = await buffer.pendingCount()
        XCTAssertTrue(acceptedSecond)
        XCTAssertFalse(acceptedThird)
        XCTAssertEqual(dropped, 1)
        XCTAssertLessThanOrEqual(pending, 1)

        try? await Task.sleep(for: .milliseconds(320))
        let finalPending = await buffer.pendingCount()
        XCTAssertEqual(finalPending, 0)
    }

    func testTargetStateCapacityEvictsInactiveBeforeRecentlyActiveState() async {
        let monitor = PassiveHealthMonitor(
            configuration: .init(
                eventLimit: 20,
                windowSize: 1,
                failureThreshold: 1,
                cooldownSeconds: 0,
                targetStateLimit: 2,
                targetStateTTLSeconds: 60
            )
        )
        let providerID = UUID()

        _ = await monitor.record(failure(providerID, targetID: "active", at: 0))
        _ = await monitor.record(failure(providerID, targetID: "inactive", at: 1))
        _ = await monitor.record(success(providerID, targetID: "inactive", at: 2))
        _ = await monitor.record(failure(providerID, targetID: "replacement", at: 3))

        let trackedTargetIDs = await monitor.debugTrackedTargetIDs()
        let activeTargetIDs = await monitor.activeAlerts().map(\.targetID)
        let stats = await monitor.debugMaintenanceStats()
        XCTAssertEqual(trackedTargetIDs, ["active", "replacement"])
        XCTAssertEqual(activeTargetIDs, ["active", "replacement"])
        XCTAssertEqual(stats.trackedTargets, 2)
    }

    func testTargetStateTTLCanEvictStaleActiveStateButNeverExceedsCapacity() async {
        let monitor = PassiveHealthMonitor(
            configuration: .init(
                eventLimit: 20,
                windowSize: 1,
                failureThreshold: 1,
                cooldownSeconds: 0,
                targetStateLimit: 1,
                targetStateTTLSeconds: 10
            )
        )
        let providerID = UUID()

        _ = await monitor.record(failure(providerID, targetID: "stale-active", at: 0))
        _ = await monitor.record(failure(providerID, targetID: "current-active", at: 11))

        let trackedTargetIDs = await monitor.debugTrackedTargetIDs()
        let activeTargetIDs = await monitor.activeAlerts().map(\.targetID)
        let stats = await monitor.debugMaintenanceStats()
        XCTAssertEqual(trackedTargetIDs, ["current-active"])
        XCTAssertEqual(activeTargetIDs, ["current-active"])
        XCTAssertEqual(stats.trackedTargets, 1)
    }

    func testTargetStateCapacityDropsNewStateWhenEveryTrackedStateIsRecentlyActive() async {
        let monitor = PassiveHealthMonitor(
            configuration: .init(
                eventLimit: 20,
                windowSize: 1,
                failureThreshold: 1,
                cooldownSeconds: 0,
                targetStateLimit: 2,
                targetStateTTLSeconds: 60
            )
        )
        let providerID = UUID()

        _ = await monitor.record(failure(providerID, targetID: "active-a", at: 0))
        _ = await monitor.record(failure(providerID, targetID: "active-b", at: 1))
        let rejected = await monitor.record(
            failure(providerID, targetID: "cannot-displace-active", at: 2)
        )

        XCTAssertNil(rejected)
        let trackedTargetIDs = await monitor.debugTrackedTargetIDs()
        let stats = await monitor.debugMaintenanceStats()
        XCTAssertEqual(trackedTargetIDs, ["active-a", "active-b"])
        XCTAssertEqual(stats.trackedTargets, 2)
        XCTAssertEqual(stats.droppedNewTargets, 1)
    }

    func testEvictedTargetStartsWithFreshHealthEvidenceWhenItReturns() async {
        let monitor = PassiveHealthMonitor(
            configuration: .init(
                eventLimit: 20,
                windowSize: 3,
                failureThreshold: 2,
                cooldownSeconds: 0,
                targetStateLimit: 2,
                targetStateTTLSeconds: 60
            )
        )
        let providerID = UUID()

        _ = await monitor.record(failure(providerID, targetID: "evicted", at: 0))
        _ = await monitor.record(failure(providerID, targetID: "protected", at: 1))
        _ = await monitor.record(failure(providerID, targetID: "protected", at: 2))
        _ = await monitor.record(failure(providerID, targetID: "replacement", at: 3))
        let returningTarget = await monitor.record(
            failure(providerID, targetID: "evicted", at: 4)
        )

        XCTAssertNil(returningTarget)
        let activeTargetIDs = await monitor.activeAlerts().map(\.targetID)
        XCTAssertEqual(activeTargetIDs, ["protected"])
    }

    func testExistingTargetHotPathDoesNotScanStateTable() async {
        let monitor = PassiveHealthMonitor(
            configuration: .init(
                eventLimit: 200,
                windowSize: 1,
                failureThreshold: 1,
                cooldownSeconds: 0,
                targetStateLimit: 2,
                targetStateTTLSeconds: 60
            )
        )
        let providerID = UUID()
        _ = await monitor.record(failure(providerID, targetID: "active-a", at: 0))
        _ = await monitor.record(failure(providerID, targetID: "active-b", at: 1))
        let scansBefore = await monitor.debugMaintenanceStats().fullStateScans

        for offset in 2..<102 {
            _ = await monitor.record(
                failure(providerID, targetID: "active-a", at: TimeInterval(offset))
            )
        }

        let stats = await monitor.debugMaintenanceStats()
        XCTAssertEqual(stats.fullStateScans, scansBefore)
        XCTAssertEqual(stats.trackedTargets, 2)
    }

    private func failure(
        _ providerID: UUID,
        targetID: String = "model-a",
        at offset: TimeInterval
    ) -> PassiveHealthEvent {
        PassiveHealthEvent(
            providerID: providerID,
            targetID: targetID,
            outcome: .http(statusCode: 503),
            latencyMilliseconds: 25,
            recordedAt: Date(timeIntervalSince1970: offset)
        )
    }

    private func success(
        _ providerID: UUID,
        targetID: String = "model-a",
        at offset: TimeInterval,
        latency: Int = 25
    ) -> PassiveHealthEvent {
        PassiveHealthEvent(
            providerID: providerID,
            targetID: targetID,
            outcome: .http(statusCode: 200),
            latencyMilliseconds: latency,
            recordedAt: Date(timeIntervalSince1970: offset)
        )
    }
}
