import XCTest
@testable import ModelHubCore

final class ProductEvolutionTests: XCTestCase {
    func testEndpointEditorRoundTripAndRejectsImplicitOrUnsafeValues() throws {
        let records = [
            "chat|alpha": "https://gateway.example.com/v1/chat/completions",
            "videoTask|video": "https://gateway.example.com/v1/tasks/{task_id}"
        ]
        let text = ProviderEndpointEditorCodec.text(from: records)
        XCTAssertEqual(try ProviderEndpointEditorCodec.records(from: text), records)
        XCTAssertThrowsError(try ProviderEndpointEditorCodec.records(from: "chat|alpha = /v1/chat/completions"))
        XCTAssertThrowsError(try ProviderEndpointEditorCodec.records(from: "chat|alpha = https://example.com/{task_id}"))
        XCTAssertThrowsError(try ProviderEndpointEditorCodec.records(from: "chat|alpha = https://example.com/a#secret"))
    }

    func testVerificationEvidenceDistinguishesLiveSuccessFromManualAvailability() {
        let provider = ProviderConfig(
            name: "P",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1/chat/completions",
            models: ["alpha"]
        )
        let live = ModelVerificationEvidence(
            provider: provider,
            model: "alpha",
            health: ModelHealthRecord(
                providerID: provider.id,
                model: "alpha",
                status: .available,
                statusCode: 200,
                detail: "在线验证成功"
            )
        )
        let manual = ModelVerificationEvidence(
            provider: provider,
            model: "alpha",
            health: ModelHealthRecord(
                providerID: provider.id,
                model: "alpha",
                status: .available,
                detail: "人工标记"
            )
        )
        XCTAssertTrue(live.isLiveVerified)
        XCTAssertFalse(manual.isLiveVerified)
    }

    func testRouteExplanationShowsSelectionExclusionAndExactEndpoint() async {
        let available = ProviderConfig(
            name: "fast",
            kind: .unifiedCompatible,
            baseURL: "https://fast.example.com/v1/chat/completions",
            models: ["alpha"]
        )
        let quarantined = ProviderConfig(
            name: "blocked",
            kind: .unifiedCompatible,
            baseURL: "https://blocked.example.com/custom",
            models: ["alpha"]
        )
        let route = RouteConfig(alias: "smart", targets: [
            RouteTarget(providerID: quarantined.id, model: "alpha", priority: 0),
            RouteTarget(providerID: available.id, model: "alpha", priority: 1)
        ])
        let report = await RoutingEngine().explain(
            requestedModel: "smart",
            routes: [route],
            providers: [available, quarantined],
            healthRecords: [
                ModelHealthRecord(providerID: available.id, model: "alpha", status: .available, latencyMilliseconds: 20),
                ModelHealthRecord(providerID: quarantined.id, model: "alpha", status: .unavailable)
            ]
        )
        XCTAssertEqual(report.selected?.providerName, "fast")
        XCTAssertEqual(report.selected?.endpoint, "https://fast.example.com/v1/chat/completions")
        XCTAssertEqual(report.candidates.first { $0.providerName == "blocked" }?.state, .excluded)
        XCTAssertTrue(report.candidates.first { $0.providerName == "blocked" }?.reasons.joined().contains("隔离") == true)
    }

    func testVirtualKeyDigestIsDeterministicAndRawTokenIsNotPersisted() throws {
        let token = "mhv_test-secret"
        let digest = AccessTokenHasher.digest(token)
        XCTAssertTrue(AccessTokenHasher.matches(token, digest: digest))
        XCTAssertFalse(AccessTokenHasher.matches("mhv_wrong", digest: digest))
        let key = VirtualAccessKey(name: "IDE", tokenDigest: digest)
        let data = try JSONEncoder().encode(key)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(token))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(digest))
    }

    func testWorkspacePrivacyAndAdaptiveConstraintsFailClosed() {
        let provider = ProviderConfig(
            name: "Proxy",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1/chat/completions",
            models: ["alpha"],
            modelProfiles: [
                "alpha": TargetProfile(
                    contextWindow: 8_000,
                    inputCostPerMillionTokens: 4,
                    outputCostPerMillionTokens: 8,
                    capabilities: [.chat]
                )
            ],
            privacyProfile: ProviderPrivacyProfile(
                dataRegion: .global,
                zeroDataRetention: false,
                mayUseForTraining: nil
            )
        )
        let target = RouteTarget(providerID: provider.id, model: "alpha")
        let reasons = RoutingPolicyEvaluator.exclusionReasons(
            target: target,
            provider: provider,
            health: ModelHealthIndex(records: [
                ModelHealthRecord(providerID: provider.id, model: "alpha", status: .available)
            ]),
            usage: [],
            requiredCapabilities: [.chat],
            constraints: RouteConstraints(
                maximumCombinedCostPerMillionTokens: 5,
                maximumP90LatencyMilliseconds: 200,
                minimumContextWindow: 32_000,
                requireKnownPrice: true
            ),
            access: RoutingAccessPolicy(
                allowedProviderIDs: [provider.id],
                privacy: WorkspacePrivacyPolicy(
                    allowedRegions: [.mainlandChina],
                    requireZeroDataRetention: true,
                    forbidTrainingUse: true
                )
            )
        )
        XCTAssertTrue(reasons.contains("价格超过路由上限"))
        XCTAssertTrue(reasons.contains("上下文窗口不足"))
        XCTAssertTrue(reasons.contains("P90 延迟未知或超过上限"))
        XCTAssertTrue(reasons.contains("数据地区不符合工作区策略"))
        XCTAssertTrue(reasons.contains("未核实零数据留存"))
        XCTAssertTrue(reasons.contains("未核实禁止训练使用"))
    }

    func testScopedRateLimiterSeparatesKeys() async {
        let limiter = ScopedRateLimiter()
        let first = UUID(), second = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let firstAdmission = await limiter.admit(keyID: first, requestsPerMinute: 1, now: now)
        let limited = await limiter.admit(keyID: first, requestsPerMinute: 1, now: now)
        let secondAdmission = await limiter.admit(keyID: second, requestsPerMinute: 1, now: now)
        XCTAssertEqual(firstAdmission, .allowed)
        XCTAssertEqual(limited, .rateLimited(retryAfterSeconds: 60))
        XCTAssertEqual(secondAdmission, .allowed)
    }

    func testUsageTracksBoundedLatencySamplesAndP90() {
        var rows: [UsageAggregate] = []
        let providerID = UUID()
        for latency in 1...150 {
            rows = UsageAccounting.recording(
                aggregates: rows,
                requestedModel: "smart",
                providerID: providerID,
                providerName: "P",
                model: "alpha",
                statusCode: 200,
                latencyMilliseconds: latency,
                tokens: .init(),
                estimatedCostUSD: nil,
                contextCharactersSaved: 0
            )
        }
        XCTAssertEqual(rows.first?.recentLatencyMilliseconds?.count, 100)
        XCTAssertEqual(rows.first?.p90LatencyMilliseconds, 140)
    }
}
