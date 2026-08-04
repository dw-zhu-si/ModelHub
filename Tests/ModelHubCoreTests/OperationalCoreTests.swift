import Foundation
import XCTest
@testable import ModelHubCore

final class OperationalCoreTests: XCTestCase {
    func testRateLimitConcurrencyCircuitAndCooldown() async {
        let controller = ResilienceController()
        let providerID = UUID()
        let key = TargetRuntimeKey(providerID: providerID, model: "m")
        let now = Date(timeIntervalSince1970: 1_000)
        let settings = ResilienceSettings(
            requestsPerMinute: 2,
            maxConcurrentRequestsPerTarget: 1,
            failureThreshold: 2,
            cooldownSeconds: 10,
            maxFallbackAttempts: 3,
            backoffBaseMilliseconds: 50
        )

        let gateway1 = await controller.admitGatewayRequest(settings: settings, now: now)
        let gateway2 = await controller.admitGatewayRequest(settings: settings, now: now)
        let gateway3 = await controller.admitGatewayRequest(settings: settings, now: now)
        XCTAssertEqual(gateway1, .allowed)
        XCTAssertEqual(gateway2, .allowed)
        XCTAssertEqual(gateway3, .rateLimited(retryAfterSeconds: 60))
        let target1 = await controller.beginTarget(key, settings: settings, now: now)
        let target2 = await controller.beginTarget(key, settings: settings, now: now)
        XCTAssertEqual(target1, .allowed)
        XCTAssertEqual(target2, .concurrencyLimited)
        await controller.finishTarget(key, succeeded: false, transientFailure: true, settings: settings, now: now)
        let target3 = await controller.beginTarget(key, settings: settings, now: now)
        XCTAssertEqual(target3, .allowed)
        await controller.finishTarget(key, succeeded: false, transientFailure: true, settings: settings, now: now)
        let target4 = await controller.beginTarget(key, settings: settings, now: now)
        let target5 = await controller.beginTarget(
            key,
            settings: settings,
            now: now.addingTimeInterval(11)
        )
        XCTAssertEqual(target4, .circuitOpen(retryAfterSeconds: 10))
        XCTAssertEqual(target5, .allowed)
    }

    func testUsageAccountingDoesNotInventUnknownPrices() throws {
        let response = Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":500}}"#.utf8)
        let tokens = UsageAccounting.tokenCounts(from: response)
        XCTAssertEqual(tokens, UsageTokenCounts(input: 1_000, output: 500))
        XCTAssertNil(UsageAccounting.estimatedCostUSD(tokens: tokens, profile: nil))
        XCTAssertNil(UsageAccounting.estimatedCostUSD(
            tokens: tokens,
            profile: TargetProfile(inputCostPerMillionTokens: 1)
        ))
        let estimated = try XCTUnwrap(
            UsageAccounting.estimatedCostUSD(
                tokens: tokens,
                profile: TargetProfile(
                    inputCostPerMillionTokens: 1,
                    outputCostPerMillionTokens: 2,
                    pricingSource: "manual"
                )
            )
        )
        XCTAssertEqual(estimated, 0.002, accuracy: 0.000_001)

        let eventStream = Data("data: {\"usage\":{\"input_tokens\":12,\"output_tokens\":7}}\n\ndata: [DONE]\n\n".utf8)
        XCTAssertEqual(
            UsageAccounting.tokenCounts(fromEventStream: eventStream),
            UsageTokenCounts(input: 12, output: 7)
        )
    }

    func testContextOptimizerPreservesToolArgumentsAndCodeBlocks() throws {
        let body = Data(#"{"model":"m","messages":[{"role":"user","content":"hello   \n\n\n\nworld"},{"role":"assistant","content":"```swift\nlet x = 1   \n```","tool_calls":[{"function":{"arguments":"{  \\\"x\\\": 1 }"}}]}]}"#.utf8)
        let originalRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let originalMessages = try XCTUnwrap(originalRoot["messages"] as? [[String: Any]])
        let originalCalls = try XCTUnwrap(originalMessages[1]["tool_calls"] as? [[String: Any]])
        let originalFunction = try XCTUnwrap(originalCalls[0]["function"] as? [String: Any])
        let result = ContextOptimizer.optimizeChatBody(
            body,
            settings: ContextOptimizationSettings(mode: .conservative, minimumCharacters: 1)
        )
        XCTAssertGreaterThan(result.charactersSaved, 0)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[1]["content"] as? String, "```swift\nlet x = 1   \n```")
        let calls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["arguments"] as? String, originalFunction["arguments"] as? String)
    }

    func testBackupRoundTripContainsConfigurationButNoSecretField() throws {
        let configuration = AppConfiguration(
            providers: [ProviderConfig(name: "Local", kind: .ollama, baseURL: "http://127.0.0.1:11434")],
            routes: [RouteConfig(alias: "smart")]
        )
        let data = try ConfigurationBackup.exportData(configuration: configuration, appVersion: "1.7.0")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("api_key"))
        let preview = try ConfigurationBackup.preview(data)
        XCTAssertEqual(preview.providerCount, 1)
        XCTAssertEqual(preview.routeCount, 1)
        XCTAssertEqual(try ConfigurationBackup.configuration(from: data).providers.first?.name, "Local")
        XCTAssertThrowsError(
            try ConfigurationBackup.preview(Data(count: ConfigurationBackup.maximumBytes + 1))
        )
    }

    func testMCPToolsAreReadOnlyAndOnlyExposeAvailableModels() throws {
        let snapshot = AgentReadOnlySnapshot(
            serviceRunning: true,
            baseURL: "http://127.0.0.1:11435/v1",
            availableModels: ["usable"],
            enabledProviders: 1,
            enabledRoutes: 1,
            month: "2026-08",
            requests: 3,
            successfulRequests: 2,
            estimatedCostUSD: 0.1
        )
        let listRequest = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let listResponse = LocalAgentProtocols.mcp(requestBody: listRequest, snapshot: snapshot)
        let listText = String(decoding: listResponse.body, as: UTF8.self)
        XCTAssertTrue(listText.contains("readOnlyHint"))
        XCTAssertFalse(listText.contains("write"))

        let callRequest = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_available_models","arguments":{}}}"#.utf8)
        let callResponse = LocalAgentProtocols.mcp(requestBody: callRequest, snapshot: snapshot)
        let callText = String(decoding: callResponse.body, as: UTF8.self)
        XCTAssertTrue(callText.contains("usable"))
        XCTAssertFalse(callText.contains("quarantined"))

        let initializeRequest = Data(#"{"jsonrpc":"2.0","id":3,"method":"initialize"}"#.utf8)
        let initializeText = String(
            decoding: LocalAgentProtocols.mcp(
                requestBody: initializeRequest,
                snapshot: snapshot
            ).body,
            as: UTF8.self
        )
        XCTAssertTrue(initializeText.contains(#""version":"1.8.0""#))
        XCTAssertTrue(String(
            decoding: LocalAgentProtocols.a2aAgentCard(baseURL: "http://127.0.0.1"),
            as: UTF8.self
        ).contains(#""version":"1.8.0""#))
        XCTAssertTrue(String(
            decoding: LocalAgentProtocols.acpManifest(baseURL: "http://127.0.0.1"),
            as: UTF8.self
        ).contains(#""version":"1.8.0""#))
    }
}
