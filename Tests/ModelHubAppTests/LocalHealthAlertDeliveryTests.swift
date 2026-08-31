import Foundation
import XCTest
@testable import ModelHub
import ModelHubCore

final class LocalHealthAlertDeliveryTests: XCTestCase {
    func testDeliveryIsDisabledByDefaultUntilExplicitlyEnabled() async throws {
        let sink = FakeLocalHealthNotificationSink(authorization: .allowed)
        let bridge = LocalHealthAlertDeliveryBridge(sink: sink)

        let disabledOutcome = try await bridge.deliver(sampleAlert(kind: .failureRate))
        let disabledDeliveries = await sink.deliveries()
        let authorizationChecks = await sink.authorizationCheckCount()
        XCTAssertEqual(disabledOutcome, .skippedDisabled)
        XCTAssertTrue(disabledDeliveries.isEmpty)
        XCTAssertEqual(authorizationChecks, 0)

        await bridge.setEnabled(true)
        let enabledOutcome = try await bridge.deliver(sampleAlert(kind: .failureRate))
        let enabledDeliveries = await sink.deliveries()
        XCTAssertEqual(enabledOutcome, .delivered)
        XCTAssertEqual(enabledDeliveries.count, 1)
    }

    func testUnauthorizedAndUndeterminedStatesNeverSend() async throws {
        for authorization in [
            LocalHealthNotificationAuthorization.denied,
            .notDetermined
        ] {
            let sink = FakeLocalHealthNotificationSink(authorization: authorization)
            let bridge = LocalHealthAlertDeliveryBridge(sink: sink, isEnabled: true)

            let outcome = try await bridge.deliver(sampleAlert(kind: .highLatency))
            let deliveries = await sink.deliveries()
            XCTAssertEqual(outcome, .skippedUnauthorized(authorization))
            XCTAssertTrue(deliveries.isEmpty)
        }
    }

    func testMappedNotificationIsGenericAndDoesNotExposeAlertTarget() {
        let providerID = UUID()
        let targetMarker = "PRIVATE-MODEL-MARKER"
        let alert = PassiveHealthAlert(
            providerID: providerID,
            targetID: targetMarker,
            kind: .failureRate,
            matchingEventCount: 9,
            emittedAt: Date(timeIntervalSince1970: 100)
        )

        let notification = LocalHealthAlertNotificationMapper.map(alert)
        let rendered = [notification.identifier, notification.title, notification.message]
            .joined(separator: " ")
            .lowercased()

        XCTAssertFalse(rendered.contains(providerID.uuidString.lowercased()))
        XCTAssertFalse(rendered.contains(targetMarker.lowercased()))
        XCTAssertFalse(rendered.contains("prompt"))
        XCTAssertFalse(rendered.contains("api_key"))
        XCTAssertFalse(rendered.contains("authorization"))
        XCTAssertFalse(rendered.contains("https://"))
        XCTAssertFalse(rendered.contains("http://"))
    }

    func testEachAlertKindMapsToAUsefulGenericLocalMessage() {
        let failure = LocalHealthAlertNotificationMapper.map(sampleAlert(kind: .failureRate))
        let latency = LocalHealthAlertNotificationMapper.map(sampleAlert(kind: .highLatency))
        let recovered = LocalHealthAlertNotificationMapper.map(sampleAlert(kind: .recovered))

        XCTAssertEqual(failure.title, "ModelHub 健康提醒")
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertFalse(latency.message.isEmpty)
        XCTAssertFalse(recovered.message.isEmpty)
        XCTAssertNotEqual(failure.message, latency.message)
        XCTAssertNotEqual(latency.message, recovered.message)
    }

    private func sampleAlert(kind: PassiveHealthAlertKind) -> PassiveHealthAlert {
        PassiveHealthAlert(
            providerID: UUID(),
            targetID: "model-a",
            kind: kind,
            matchingEventCount: 3,
            emittedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private actor FakeLocalHealthNotificationSink: LocalHealthNotificationSinking {
    private let authorization: LocalHealthNotificationAuthorization
    private var sent: [LocalHealthNotification] = []
    private var authorizationChecks = 0

    init(authorization: LocalHealthNotificationAuthorization) {
        self.authorization = authorization
    }

    func authorizationStatus() async -> LocalHealthNotificationAuthorization {
        authorizationChecks += 1
        return authorization
    }

    func deliver(_ notification: LocalHealthNotification) async throws {
        sent.append(notification)
    }

    func deliveries() -> [LocalHealthNotification] {
        sent
    }

    func authorizationCheckCount() -> Int {
        authorizationChecks
    }
}
