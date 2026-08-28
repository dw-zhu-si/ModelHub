import Foundation
import XCTest
@testable import ModelHubCore

final class GatewayObservabilityTests: XCTestCase {
    func testResilienceMetricsUseBoundedAggregateCounters() async {
        let controller = ResilienceController()
        let settings = ResilienceSettings(
            requestsPerMinute: 1,
            maxConcurrentRequestsPerTarget: 1,
            failureThreshold: 1,
            cooldownSeconds: 60
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let key = TargetRuntimeKey(providerID: UUID(), model: "model")

        let gatewayAllowed = await controller.admitGatewayRequest(settings: settings, now: now)
        XCTAssertEqual(gatewayAllowed, .allowed)
        guard case .rateLimited = await controller.admitGatewayRequest(settings: settings, now: now) else {
            return XCTFail("second gateway request should be rate limited")
        }
        let targetAllowed = await controller.beginTarget(key, settings: settings, now: now)
        let targetLimited = await controller.beginTarget(key, settings: settings, now: now)
        XCTAssertEqual(targetAllowed, .allowed)
        XCTAssertEqual(targetLimited, .concurrencyLimited)
        await controller.finishTarget(
            key,
            succeeded: false,
            transientFailure: true,
            settings: settings,
            now: now
        )
        guard case .circuitOpen = await controller.beginTarget(key, settings: settings, now: now) else {
            return XCTFail("circuit should reject while open")
        }

        let metrics = await controller.metrics()
        XCTAssertEqual(metrics.gatewayAllowed, 1)
        XCTAssertEqual(metrics.gatewayRateLimited, 1)
        XCTAssertEqual(metrics.targetAllowed, 1)
        XCTAssertEqual(metrics.targetConcurrencyLimited, 1)
        XCTAssertEqual(metrics.targetCircuitRejected, 1)
        XCTAssertEqual(metrics.circuitsOpened, 1)
        XCTAssertEqual(metrics.transientFailures, 1)
    }

    func testProxySessionPoolMetricsTrackCreationReuseAndBoundedEviction() async {
        await ProviderClient.resetProxySessionMetricsForTesting()
        let capacity = ProviderProxySessionPoolPolicy.maximumSessionCount
        let first = ProviderProxyEndpoint(kind: .http, host: "127.0.0.1", port: 20_000)
        _ = await ProviderClient.proxySessionForTesting(first)
        _ = await ProviderClient.proxySessionForTesting(first)
        for offset in 1...capacity {
            _ = await ProviderClient.proxySessionForTesting(
                ProviderProxyEndpoint(
                    kind: .http,
                    host: "127.0.0.1",
                    port: 20_000 + offset
                )
            )
        }

        let metrics = await ProviderClient.proxySessionMetrics()
        XCTAssertEqual(metrics.capacity, capacity)
        XCTAssertEqual(metrics.activeSessions, capacity)
        XCTAssertEqual(metrics.createdSessions, UInt64(capacity + 1))
        XCTAssertEqual(metrics.reusedSessions, 1)
        XCTAssertEqual(metrics.evictions, 1)
        await ProviderClient.resetProxySessionMetricsForTesting()
    }
}
