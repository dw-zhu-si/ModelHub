import Foundation
import ModelHubCore
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
        XCTAssertNotNil(observability["idempotency"] as? [String: Any])
        XCTAssertNotNil(observability["sticky_sessions"] as? [String: Any])
        XCTAssertNotNil(observability["passive_health"] as? [String: Any])
        XCTAssertNotNil(observability["media_batch"] as? [String: Any])
        let credentials = try XCTUnwrap(
            observability["provider_credentials"] as? [String: Any]
        )
        XCTAssertEqual(credentials["bound"] as? Int, 0)
        XCTAssertEqual(credentials["missing"] as? Int, 0)
        XCTAssertEqual(credentials["invalid_or_mismatched"] as? Int, 0)
        XCTAssertEqual(credentials["temporarily_unreadable"] as? Int, 0)

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

    @MainActor
    func testGatewayIdempotencyReplaysOnlyAnIdenticalScopedRequest() async throws {
        let model = AppModel()
        model.configuration = AppConfiguration(
            server: ServerSettings(
                requireAuthentication: false,
                startAutomatically: false
            )
        )
        let original = HTTPRequest(
            method: "POST",
            path: "/v1/chat/completions",
            queryItems: [:],
            orderedQueryItems: [],
            headers: ["idempotency-key": "gateway-case-1"],
            body: Data(#"{"model":"missing-a","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        )

        let first = await model.handle(original)
        let replay = await model.handle(original)

        XCTAssertEqual(first.statusCode, 404)
        XCTAssertEqual(first.headers["X-ModelHub-Idempotent-Replay"], "false")
        XCTAssertEqual(replay.statusCode, first.statusCode)
        XCTAssertEqual(replay.body, first.body)
        XCTAssertEqual(replay.headers["X-ModelHub-Idempotent-Replay"], "true")

        let conflict = await model.handle(HTTPRequest(
            method: "POST",
            path: "/v1/chat/completions",
            queryItems: [:],
            orderedQueryItems: [],
            headers: ["idempotency-key": "gateway-case-1"],
            body: Data(#"{"model":"missing-b","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        ))
        XCTAssertEqual(conflict.statusCode, 409)
        XCTAssertTrue(String(decoding: conflict.body, as: UTF8.self).contains("idempotency_conflict"))
    }

    @MainActor
    func testIdempotencyHeaderFailsClosedOnReadOnlyEndpoint() async {
        let model = AppModel()
        model.configuration = AppConfiguration(
            server: ServerSettings(
                requireAuthentication: false,
                startAutomatically: false
            )
        )

        let response = await model.handle(HTTPRequest(
            method: "GET",
            path: "/v1/models",
            queryItems: [:],
            orderedQueryItems: [],
            headers: ["idempotency-key": "read-only-key"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(
            String(decoding: response.body, as: UTF8.self)
                .contains("idempotency_not_supported")
        )
    }

    @MainActor
    func testIdempotencyReplayRechecksChangedVirtualKeyAllowlist() async {
        let model = AppModel()
        let token = "mhv_test_idempotency_policy"
        let keyID = UUID()
        model.configuration = AppConfiguration(
            server: ServerSettings(requireAuthentication: true, startAutomatically: false),
            virtualKeys: [VirtualAccessKey(
                id: keyID,
                name: "idempotency-policy",
                tokenDigest: AccessTokenHasher.digest(token),
                allowedModels: ["missing-a"]
            )]
        )
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/chat/completions",
            queryItems: [:],
            orderedQueryItems: [],
            headers: [
                "authorization": "Bearer \(token)",
                "idempotency-key": "policy-change-case"
            ],
            body: Data(
                #"{"model":"missing-a","messages":[{"role":"user","content":"hello"}]}"#.utf8
            )
        )

        let first = await model.handle(request)
        XCTAssertEqual(first.statusCode, 404)

        model.configuration.virtualKeys[0].allowedModels = ["different-model"]
        let afterPolicyChange = await model.handle(request)

        XCTAssertEqual(afterPolicyChange.statusCode, 403)
        XCTAssertNil(afterPolicyChange.headers["X-ModelHub-Idempotent-Replay"])
        XCTAssertTrue(
            String(decoding: afterPolicyChange.body, as: UTF8.self)
                .contains("model_not_allowed")
        )
    }

    @MainActor
    func testVirtualAccessKeyCannotReadGlobalUsageLedger() async {
        let model = AppModel()
        let token = "mhv_test_ledger_scope"
        model.configuration = AppConfiguration(
            server: ServerSettings(
                requireAuthentication: true,
                startAutomatically: false
            ),
            virtualKeys: [VirtualAccessKey(
                name: "restricted",
                tokenDigest: AccessTokenHasher.digest(token)
            )]
        )

        let response = await model.handle(HTTPRequest(
            method: "GET",
            path: "/v1/analytics/ledger",
            queryItems: [:],
            orderedQueryItems: [],
            headers: ["authorization": "Bearer \(token)"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 403)
        XCTAssertTrue(
            String(decoding: response.body, as: UTF8.self)
                .contains("usage_ledger_forbidden")
        )
    }
}
