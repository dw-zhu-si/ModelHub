import XCTest
@testable import ModelHubCore

final class RoutingEngineTests: XCTestCase {
    func testBuiltInDefaultRulesAreExclusiveAndOrderSameModelCandidates() async {
        XCTAssertEqual(DefaultRoutingRule.allCases.count, 3)
        XCTAssertEqual(AppConfiguration().routing.activeRule, .sameModelLowestCost)

        let official = ProviderConfig(
            name: "OpenAI 官方",
            kind: .openAI,
            baseURL: "https://api.openai.com",
            models: ["gpt-4o"],
            modelProfiles: ["gpt-4o": TargetProfile(inputCostPerMillionTokens: 10, outputCostPerMillionTokens: 10)]
        )
        let compatible = ProviderConfig(
            name: "兼容代理",
            kind: .openAICompatible,
            baseURL: "https://proxy.example.com",
            models: ["gpt-4o"],
            modelProfiles: ["gpt-4o": TargetProfile(inputCostPerMillionTokens: 1, outputCostPerMillionTokens: 1)]
        )
        let health = [
            ModelHealthRecord(providerID: official.id, model: "gpt-4o", status: .available, latencyMilliseconds: 40),
            ModelHealthRecord(providerID: compatible.id, model: "gpt-4o", status: .available, latencyMilliseconds: 200)
        ]
        let engine = RoutingEngine()

        let cost = await engine.candidates(
            for: "gpt-4o", routes: [], providers: [official, compatible], healthRecords: health,
            defaultRule: .sameModelLowestCost
        )
        let speed = await engine.candidates(
            for: "gpt-4o", routes: [], providers: [official, compatible], healthRecords: health,
            defaultRule: .sameModelLowestLatency
        )
        let officialFirst = await engine.candidates(
            for: "gpt-4o", routes: [], providers: [compatible, official], healthRecords: health,
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
        let provider = ProviderConfig(name: "P", kind: .openAICompatible, baseURL: "https://example.com")
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
            kind: .openAICompatible,
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
        let enabled = ProviderConfig(name: "Enabled", kind: .openAI, baseURL: "https://example.com")
        var disabled = ProviderConfig(name: "Disabled", kind: .openAI, baseURL: "https://example.com")
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
        let provider = ProviderConfig(name: "P", kind: .openAI, baseURL: "https://example.com")
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
            name: "OpenAI",
            kind: .openAI,
            baseURL: "https://api.openai.com",
            models: ["gpt-test"]
        )

        let result = await RoutingEngine().candidates(
            for: "OpenAI/gpt-test",
            routes: [],
            providers: [provider],
            healthRecords: [
                ModelHealthRecord(providerID: provider.id, model: "gpt-test", status: .available)
            ]
        )

        XCTAssertEqual(result.first?.providerID, provider.id)
        XCTAssertEqual(result.first?.model, "gpt-test")
    }

    func testUnavailableAndUnknownTargetsAreQuarantined() async {
        let provider = ProviderConfig(
            name: "Provider",
            kind: .openAI,
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
            kind: .openAI,
            baseURL: "https://one.example.com",
            models: ["shared-model"]
        )
        let available = ProviderConfig(
            name: "Available",
            kind: .openAI,
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
            kind: .openAI,
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
            kind: .openAI,
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
