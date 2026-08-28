import Foundation
import XCTest
@testable import ModelHub

final class GatewayHealthResponseTests: XCTestCase {
    @MainActor
    func testHealthResponseExposesOnlyBoundedAggregateObservability() async throws {
        let model = AppModel()
        let response = await model.handle(HTTPRequest(
            method: "GET",
            path: "/health",
            queryItems: [:],
            orderedQueryItems: [],
            headers: [:],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 200)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        let observability = try XCTUnwrap(root["observability"] as? [String: Any])
        XCTAssertNotNil(observability["cache"] as? [String: Any])
        XCTAssertNotNil(observability["proxy_sessions"] as? [String: Any])
        XCTAssertNotNil(observability["resilience"] as? [String: Any])

        let freshness = try XCTUnwrap(
            observability["model_health_freshness"] as? [String: Any]
        )
        XCTAssertNotNil(freshness["fresh"] as? Int)
        XCTAssertNotNil(freshness["stale"] as? Int)
        XCTAssertNotNil(freshness["never"] as? Int)
        XCTAssertEqual(
            freshness["fresh_window_seconds"] as? Int,
            24 * 60 * 60
        )

        let encoded = String(decoding: response.body, as: UTF8.self).lowercased()
        XCTAssertFalse(encoded.contains("api_key"))
        XCTAssertFalse(encoded.contains("authorization"))
        XCTAssertFalse(encoded.contains("request_id"))
        XCTAssertFalse(encoded.contains("prompt"))
    }
}
