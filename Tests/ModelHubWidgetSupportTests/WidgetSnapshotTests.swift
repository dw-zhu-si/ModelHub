import Foundation
import XCTest
@testable import ModelHubWidgetSupport

final class WidgetSnapshotTests: XCTestCase {
    func testSnapshotRoundTripContainsOnlyOperationalMetrics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("widget-status.json")
        let snapshot = ModelHubWidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 123),
            isServerRunning: true,
            endpoint: "127.0.0.1:11435",
            providerCount: 4,
            routeCount: 2,
            availableModelCount: 18,
            totalRequests: 10,
            successfulRequests: 9
        )

        try ModelHubWidgetSnapshotStore.save(snapshot, to: url)
        let decoded = try ModelHubWidgetSnapshotStore.load(from: url)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.successRate, 90)
    }
}
