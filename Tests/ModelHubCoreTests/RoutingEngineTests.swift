import XCTest
@testable import ModelHubCore

final class RoutingEngineTests: XCTestCase {
    func testRoutingUsagePerformanceBaseline() async {
        let provider = ProviderConfig(
            name: "Performance",
            kind: .unifiedCompatible,
            baseURL: "https://example.invalid"
        )
        let targets = (0..<500).map { index in
            RouteTarget(
                providerID: provider.id,
                model: "model-\(index)",
                priority: index % 5,
                profile: TargetProfile(
                    contextWindow: 32_000 + index,
                    inputCostPerMillionTokens: Double((index % 10) + 1),
                    outputCostPerMillionTokens: Double((index % 20) + 1)
                )
            )
        }
        let health = ModelHealthIndex(records: targets.map {
            ModelHealthRecord(
                providerID: $0.providerID,
                model: $0.model,
                status: .available,
                latencyMilliseconds: 100
            )
        })
        let usage = (0..<1_000).map { index in
            UsageAggregate(
                month: "2026-08",
                requestedModel: "performance",
                providerID: provider.id,
                providerName: provider.name,
                model: "model-\(index % targets.count)",
                requests: 10,
                successfulRequests: 5 + (index % 6),
                totalLatencyMilliseconds: 1_000 + index,
                recentLatencyMilliseconds: [50 + (index % 500), 100 + (index % 500)]
            )
        }
        let route = RouteConfig(
            alias: "performance",
            strategy: .balanced,
            targets: targets,
            constraints: RouteConstraints(maximumP90LatencyMilliseconds: 1_000)
        )
        let engine = RoutingEngine()
        let clock = ContinuousClock()
        let started = clock.now

        for _ in 0..<10 {
            let candidates = await engine.candidates(
                for: route.alias,
                routes: [route],
                providers: [provider],
                health: health,
                usage: usage
            )
            XCTAssertEqual(candidates.count, targets.count)
        }

        let duration = started.duration(to: clock.now)
        print("ROUTING_USAGE_BASELINE workload=500_targets_1000_usage_10_decisions duration=\(duration)")
#if !DEBUG
        XCTAssertLessThan(duration, .seconds(2))
#endif
    }

    func testP90ConstraintUsesIndexedMetricsAndExcludesSlowOrUnknownTargets() async {
        let provider = ProviderConfig(
            name: "Latency policy",
            kind: .unifiedCompatible,
            baseURL: "https://example.invalid"
        )
        let targets = ["fast", "slow", "unknown"].map {
            RouteTarget(providerID: provider.id, model: $0)
        }
        let health = ModelHealthIndex(records: targets.map {
            ModelHealthRecord(providerID: provider.id, model: $0.model, status: .available)
        })
        let usage = [
            UsageAggregate(
                month: "2026-08",
                requestedModel: "constrained",
                providerID: provider.id,
                providerName: provider.name,
                model: "fast",
                recentLatencyMilliseconds: [80, 120]
            ),
            UsageAggregate(
                month: "2026-08",
                requestedModel: "constrained",
                providerID: provider.id,
                providerName: provider.name,
                model: "slow",
                recentLatencyMilliseconds: [250, 400]
            )
        ]
        let route = RouteConfig(
            alias: "constrained",
            strategy: .priority,
            targets: targets,
            constraints: RouteConstraints(maximumP90LatencyMilliseconds: 200)
        )

        let candidates = await RoutingEngine().candidates(
            for: route.alias,
            routes: [route],
            providers: [provider],
            health: health,
            usage: usage
        )

        XCTAssertEqual(candidates.map(\.model), ["fast"])
    }

    func testUsageMetricIndexAggregatesLatencyAndStabilityOncePerTarget() throws {
        let providerID = UUID()
        let usage = [
            UsageAggregate(
                month: "2026-07",
                requestedModel: "route-a",
                providerID: providerID,
                providerName: "Performance",
                model: "model-a",
                requests: 10,
                successfulRequests: 8,
                recentLatencyMilliseconds: [100, 200, 300]
            ),
            UsageAggregate(
                month: "2026-08",
                requestedModel: "route-b",
                providerID: providerID,
                providerName: "Performance",
                model: "model-a",
                requests: 30,
                successfulRequests: 22,
                recentLatencyMilliseconds: [250, 400]
            )
        ]

        let index = UsageMetricIndex(usage: usage)

        XCTAssertEqual(
            index.p90LatencyMilliseconds(providerID: providerID, model: "model-a"),
            400
        )
        XCTAssertEqual(
            try XCTUnwrap(index.stability(providerID: providerID, model: "model-a")),
            0.75,
            accuracy: 0.000_001
        )
        XCTAssertNil(index.p90LatencyMilliseconds(providerID: providerID, model: "MODEL-A"))
        XCTAssertNil(index.stability(providerID: providerID, model: "missing"))
    }

    func testWeightedRandomUsesDeterministicCumulativeBoundaries() async {
        let provider = ProviderConfig(
            name: "Weighted",
            kind: .unifiedCompatible,
            baseURL: "https://example.invalid"
        )
        let targets = [
            RouteTarget(providerID: provider.id, model: "a", weight: 1),
            RouteTarget(providerID: provider.id, model: "b", weight: 3),
            RouteTarget(providerID: provider.id, model: "c", weight: 2)
        ]
        let route = RouteConfig(alias: "weighted", strategy: .weightedRandom, targets: targets)
        let health = ModelHealthIndex(records: targets.map {
            ModelHealthRecord(providerID: $0.providerID, model: $0.model, status: .available)
        })

        func firstModel(at draw: Int) async -> String? {
            let engine = RoutingEngine(weightedRandomValue: { upperBound in
                XCTAssertEqual(upperBound, 6)
                return draw
            })
            return await engine.candidates(
                for: route.alias,
                routes: [route],
                providers: [provider],
                health: health
            ).first?.model
        }

        var selected: [String?] = []
        for draw in [0, 1, 3, 4, 5] {
            selected.append(await firstModel(at: draw))
        }
        XCTAssertEqual(selected, ["a", "b", "b", "c", "c"])
    }

    func testBuiltInDefaultRulesAreExclusiveAndOrderSameModelCandidates() async {
        XCTAssertEqual(DefaultRoutingRule.allCases.count, 3)
        XCTAssertEqual(AppConfiguration().routing.activeRule, .sameModelLowestCost)

        let official = ProviderConfig(
            name: "Anthropic 官方",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com",
            models: ["claude-sonnet"],
            modelProfiles: ["claude-sonnet": TargetProfile(inputCostPerMillionTokens: 10, outputCostPerMillionTokens: 10)]
        )
        let compatible = ProviderConfig(
            name: "兼容代理",
            kind: .unifiedCompatible,
            baseURL: "https://proxy.example.com",
            models: ["claude-sonnet"],
            modelProfiles: ["claude-sonnet": TargetProfile(inputCostPerMillionTokens: 1, outputCostPerMillionTokens: 1)]
        )
        let health = [
            ModelHealthRecord(providerID: official.id, model: "claude-sonnet", status: .available, latencyMilliseconds: 40),
            ModelHealthRecord(providerID: compatible.id, model: "claude-sonnet", status: .available, latencyMilliseconds: 200)
        ]
        let engine = RoutingEngine()

        let cost = await engine.candidates(
            for: "claude-sonnet", routes: [], providers: [official, compatible], healthRecords: health,
            defaultRule: .sameModelLowestCost
        )
        let speed = await engine.candidates(
            for: "claude-sonnet", routes: [], providers: [official, compatible], healthRecords: health,
            defaultRule: .sameModelLowestLatency
        )
        let officialFirst = await engine.candidates(
            for: "claude-sonnet", routes: [], providers: [compatible, official], healthRecords: health,
            defaultRule: .sameModelOfficial
        )

        XCTAssertEqual(cost.first?.providerID, compatible.id)
        XCTAssertEqual(speed.first?.providerID, official.id)
        XCTAssertEqual(officialFirst.first?.providerID, official.id)
    }

    func testLegacyConfigurationGetsNonDeletableDefaultRoutingRule() throws {
        let legacy = Data(#"{"providers":[],"routes":[],"server":{"port":11435,"requireAuthentication":true,"startAutomatically":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: legacy)
        XCTAssertEqual(decoded.routing.activeRule, .sameModelLowestCost)
        let encoded = try JSONEncoder().encode(decoded)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(root["routing"])
    }

    func testCapabilityRequirementsExcludeExplicitlyIncompatibleTargets() async {
        let provider = ProviderConfig(name: "P", kind: .unifiedCompatible, baseURL: "https://example.com")
        let route = RouteConfig(
            alias: "vision",
            targets: [
                RouteTarget(
                    providerID: provider.id,
                    model: "text-only",
                    profile: TargetProfile(capabilities: [.chat])
                ),
                RouteTarget(
                    providerID: provider.id,
                    model: "vision-model",
                    profile: TargetProfile(capabilities: [.chat, .vision])
                )
            ]
        )
        let result = await RoutingEngine().candidates(
            for: "vision",
            routes: [route],
            providers: [provider],
            healthRecords: [
                ModelHealthRecord(providerID: provider.id, model: "text-only", status: .available),
                ModelHealthRecord(providerID: provider.id, model: "vision-model", status: .available)
            ],
            requiredCapabilities: [.chat, .vision]
        )
        XCTAssertEqual(result.map(\.model), ["vision-model"])
    }

    func testOperationalStrategiesUseDeclaredMetadataAndMeasuredLatency() async {
        let providerID = UUID()
        let provider = ProviderConfig(
            id: providerID,
            name: "测试",
            kind: .unifiedCompatible,
            baseURL: "https://example.com",
            models: ["fast", "cheap", "large"]
        )
        let targets = [
            RouteTarget(
                providerID: providerID,
                model: "fast",
                profile: TargetProfile(
                    contextWindow: 32_000,
                    inputCostPerMillionTokens: 8,
                    outputCostPerMillionTokens: 16
                )
            ),
            RouteTarget(
                providerID: providerID,
                model: "cheap",
                profile: TargetProfile(
                    contextWindow: 64_000,
                    inputCostPerMillionTokens: 1,
                    outputCostPerMillionTokens: 2
                )
            ),
            RouteTarget(
                providerID: providerID,
                model: "large",
                profile: TargetProfile(
                    contextWindow: 1_000_000,
                    inputCostPerMillionTokens: 4,
                    outputCostPerMillionTokens: 8
                )
            )
        ]
        let health = ModelHealthIndex(records: [
            ModelHealthRecord(providerID: providerID, model: "fast", status: .available, latencyMilliseconds: 50),
            ModelHealthRecord(providerID: providerID, model: "cheap", status: .available, latencyMilliseconds: 500),
            ModelHealthRecord(providerID: providerID, model: "large", status: .available, latencyMilliseconds: 300)
        ])
        let engine = RoutingEngine()
        let usage = [
            UsageAggregate(month: "2026-08", requestedModel: "auto", providerID: providerID, providerName: "测试", model: "fast", requests: 10, successfulRequests: 5),
            UsageAggregate(month: "2026-08", requestedModel: "auto", providerID: providerID, providerName: "测试", model: "cheap", requests: 10, successfulRequests: 9),
            UsageAggregate(month: "2026-08", requestedModel: "auto", providerID: providerID, providerName: "测试", model: "large", requests: 10, successfulRequests: 7)
        ]

        func first(_ strategy: RouteStrategy) async -> String? {
            await engine.candidates(
                for: "auto",
                routes: [RouteConfig(alias: "auto", strategy: strategy, targets: targets)],
                providers: [provider],
                health: health,
                usage: usage
            ).first?.model
        }

        let fastest = await first(.lowestLatency)
        let cheapest = await first(.lowestCost)
        let largest = await first(.largestContext)
        let stable = await first(.highestStability)

        XCTAssertEqual(fastest, "fast")
        XCTAssertEqual(cheapest, "cheap")
        XCTAssertEqual(largest, "large")
        XCTAssertEqual(stable, "cheap")
    }
    func testPriorityRouteSkipsDisabledProviderAndOrdersTargets() async {
        let enabled = ProviderConfig(name: "Enabled", kind: .unifiedCompatible, baseURL: "https://example.com")
        var disabled = ProviderConfig(name: "Disabled", kind: .unifiedCompatible, baseURL: "https://example.com")
        disabled.enabled = false

        let route = RouteConfig(
            alias: "smart",
            targets: [
                RouteTarget(providerID: enabled.id, model: "slow", priority: 10),
                RouteTarget(providerID: disabled.id, model: "disabled", priority: 0),
                RouteTarget(providerID: enabled.id, model: "fast", priority: 0)
            ]
        )

        let result = await RoutingEngine().candidates(
            for: "SMART",
            routes: [route],
            providers: [enabled, disabled],
            healthRecords: [
                ModelHealthRecord(providerID: enabled.id, model: "slow", status: .available),
                ModelHealthRecord(providerID: disabled.id, model: "disabled", status: .available),
                ModelHealthRecord(providerID: enabled.id, model: "fast", status: .available)
            ]
        )

        XCTAssertEqual(result.map(\.model), ["fast", "slow"])
    }

    func testRoundRobinRotatesFirstCandidate() async {
        let provider = ProviderConfig(name: "P", kind: .unifiedCompatible, baseURL: "https://example.com")
        let route = RouteConfig(
            alias: "balanced",
            strategy: .roundRobin,
            targets: [
                RouteTarget(providerID: provider.id, model: "a"),
                RouteTarget(providerID: provider.id, model: "b")
            ]
        )
        let engine = RoutingEngine()

        let health = [
            ModelHealthRecord(providerID: provider.id, model: "a", status: .available),
            ModelHealthRecord(providerID: provider.id, model: "b", status: .available)
        ]
        let first = await engine.candidates(
            for: "balanced",
            routes: [route],
            providers: [provider],
            healthRecords: health
        )
        let second = await engine.candidates(
            for: "balanced",
            routes: [route],
            providers: [provider],
            healthRecords: health
        )

        XCTAssertEqual(first.first?.model, "a")
        XCTAssertEqual(second.first?.model, "b")
    }

    func testDirectModelCanUseProviderPrefix() async {
        let provider = ProviderConfig(
            name: "兼容供应商",
            kind: .unifiedCompatible,
            baseURL: "https://gateway.example.com",
            models: ["text-test"]
        )

        let result = await RoutingEngine().candidates(
            for: "兼容供应商/text-test",
            routes: [],
            providers: [provider],
            healthRecords: [
                ModelHealthRecord(providerID: provider.id, model: "text-test", status: .available)
            ]
        )

        XCTAssertEqual(result.first?.providerID, provider.id)
        XCTAssertEqual(result.first?.model, "text-test")
    }

    func testUnavailableAndUnknownTargetsAreQuarantined() async {
        let provider = ProviderConfig(
            name: "Provider",
            kind: .unifiedCompatible,
            baseURL: "https://example.com",
            models: ["configured-first", "healthy", "unknown"]
        )
        let route = RouteConfig(
            alias: "smart",
            strategy: .priority,
            targets: [
                RouteTarget(providerID: provider.id, model: "configured-first", priority: 0),
                RouteTarget(providerID: provider.id, model: "unknown", priority: 5),
                RouteTarget(providerID: provider.id, model: "healthy", priority: 10)
            ]
        )
        let health = [
            ModelHealthRecord(
                providerID: provider.id,
                model: "configured-first",
                status: .unavailable
            ),
            ModelHealthRecord(
                providerID: provider.id,
                model: "healthy",
                status: .available
            )
        ]

        let result = await RoutingEngine().candidates(
            for: "smart",
            routes: [route],
            providers: [provider],
            healthRecords: health
        )

        XCTAssertEqual(result.map(\.model), ["healthy"])
    }

    func testDirectMatchesPreferAvailableProvider() async {
        let unavailable = ProviderConfig(
            name: "Unavailable",
            kind: .unifiedCompatible,
            baseURL: "https://one.example.com",
            models: ["shared-model"]
        )
        let available = ProviderConfig(
            name: "Available",
            kind: .unifiedCompatible,
            baseURL: "https://two.example.com",
            models: ["shared-model"]
        )
        let health = [
            ModelHealthRecord(
                providerID: unavailable.id,
                model: "shared-model",
                status: .unavailable
            ),
            ModelHealthRecord(
                providerID: available.id,
                model: "shared-model",
                status: .available
            )
        ]

        let result = await RoutingEngine().candidates(
            for: "shared-model",
            routes: [],
            providers: [unavailable, available],
            healthRecords: health
        )

        XCTAssertEqual(result.map(\.providerID), [available.id])
    }

    func testQuarantinedTargetReturnsOnlyAfterStatusChangesToAvailable() async {
        let provider = ProviderConfig(
            name: "Provider",
            kind: .unifiedCompatible,
            baseURL: "https://example.com",
            models: ["model"]
        )
        let route = RouteConfig(
            alias: "smart",
            targets: [RouteTarget(providerID: provider.id, model: "model")]
        )
        let quarantined = [
            ModelHealthRecord(
                providerID: provider.id,
                model: "model",
                status: .unavailable
            )
        ]
        let restored = [
            ModelHealthRecord(
                providerID: provider.id,
                model: "model",
                status: .available
            )
        ]

        let blocked = await RoutingEngine().candidates(
            for: "smart",
            routes: [route],
            providers: [provider],
            healthRecords: quarantined
        )
        let allowed = await RoutingEngine().candidates(
            for: "smart",
            routes: [route],
            providers: [provider],
            healthRecords: restored
        )

        XCTAssertTrue(blocked.isEmpty)
        XCTAssertEqual(allowed.map(\.model), ["model"])
    }

    func testCredentialAndUnsupportedStatusesAreNeverRouted() async {
        let provider = ProviderConfig(
            name: "Provider",
            kind: .unifiedCompatible,
            baseURL: "https://example.com",
            models: ["credential", "unsupported"]
        )
        let route = RouteConfig(
            alias: "smart",
            targets: [
                RouteTarget(providerID: provider.id, model: "credential"),
                RouteTarget(providerID: provider.id, model: "unsupported")
            ]
        )
        let health = [
            ModelHealthRecord(
                providerID: provider.id,
                model: "credential",
                status: .configurationRequired
            ),
            ModelHealthRecord(
                providerID: provider.id,
                model: "unsupported",
                status: .unsupported
            )
        ]

        let result = await RoutingEngine().candidates(
            for: "smart",
            routes: [route],
            providers: [provider],
            healthRecords: health
        )

        XCTAssertTrue(result.isEmpty)
    }
}
