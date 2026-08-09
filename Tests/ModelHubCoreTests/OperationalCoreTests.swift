import Foundation
import XCTest
@testable import ModelHubCore

final class OperationalCoreTests: XCTestCase {
    func testFixedPerRequestPriceAccountsForMediaWithoutTokenUsage() {
        let profile = TargetProfile(requestCostUSD: 0.08, pricingSource: "official")

        XCTAssertEqual(
            UsageAccounting.estimatedCostUSD(tokens: .init(), profile: profile),
            0.08
        )
    }

    func testFixedPerRequestPriceDoesNotHideMissingTokenRate() {
        let profile = TargetProfile(
            inputCostPerMillionTokens: 1,
            requestCostUSD: 0.08,
            pricingSource: "official"
        )

        XCTAssertNil(UsageAccounting.estimatedCostUSD(
            tokens: UsageTokenCounts(input: 100, output: 50),
            profile: profile
        ))
    }

    func testPricingScheduleDefaultsToLocalMidnightAndSupportsConfiguredTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 8, hour: 10, minute: 15
        )))

        let defaults = PricingUpdateSettings()
        let mostRecent = try XCTUnwrap(defaults.mostRecentScheduledDate(
            before: now,
            calendar: calendar
        ))
        XCTAssertEqual(calendar.component(.hour, from: mostRecent), 0)
        XCTAssertEqual(calendar.component(.day, from: mostRecent), 8)

        let configured = PricingUpdateSettings(localHour: 6, localMinute: 30)
        let next = try XCTUnwrap(configured.nextScheduledDate(after: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: next), 9)
        XCTAssertEqual(calendar.component(.hour, from: next), 6)
        XCTAssertEqual(calendar.component(.minute, from: next), 30)

        let sanitized = PricingUpdateSettings(localHour: 99, localMinute: -3).sanitized
        XCTAssertEqual(sanitized.localHour, 23)
        XCTAssertEqual(sanitized.localMinute, 0)
    }

    func testPricingScheduleDoesNotRunCatchUpOnFirstLaunch() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 8, hour: 10, minute: 15
        )))
        let beforeMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 7, hour: 23, minute: 50
        )))
        let afterMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 8, hour: 0, minute: 5
        )))

        XCTAssertFalse(PricingUpdateSettings().shouldCatchUp(at: now, calendar: calendar))
        XCTAssertTrue(
            PricingUpdateSettings(lastAttemptAt: beforeMidnight)
                .shouldCatchUp(at: now, calendar: calendar)
        )
        XCTAssertFalse(
            PricingUpdateSettings(lastAttemptAt: afterMidnight)
                .shouldCatchUp(at: now, calendar: calendar)
        )
    }

    func testLegacyOperationalSettingsDecodeWithDefaultPricingSchedule() throws {
        let encoded = try JSONEncoder().encode(OperationalSettings())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "pricingUpdate")
        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(OperationalSettings.self, from: legacy)
        XCTAssertNil(decoded.pricingUpdate)
        XCTAssertEqual((decoded.pricingUpdate ?? .init()).localHour, 0)
    }

    func testLegacyOperationalSettingsDecodeWithDefaultDisplayCurrency() throws {
        let encoded = try JSONEncoder().encode(OperationalSettings())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "currencyDisplay")
        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(OperationalSettings.self, from: legacy)

        XCTAssertNil(decoded.currencyDisplay)
        XCTAssertEqual((decoded.currencyDisplay ?? .init()).currency, .usd)
    }

    func testCurrencyDisplayConvertsAndFormatsWithoutChangingStoredUSD() throws {
        let settings = CurrencyDisplaySettings(
            currency: .cny,
            unitsPerUSD: ["USD": 1, "CNY": 7.2]
        )
        XCTAssertEqual(settings.convertedFromUSD(2), 14.4, accuracy: 0.000_001)
        XCTAssertTrue(settings.formattedUSD(2).contains("14.4000"))
    }

    func testParsesOfficialEURReferenceRatesIntoUSDConversions() throws {
        let xml = Data(#"""
        <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"
          xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
          <Cube><Cube time="2026-08-08">
            <Cube currency="USD" rate="1.2000"/>
            <Cube currency="CNY" rate="8.4000"/>
            <Cube currency="JPY" rate="180.0000"/>
          </Cube></Cube>
        </gesmes:Envelope>
        """#.utf8)
        let snapshot = try CurrencyRateClient.parse(xml)

        XCTAssertEqual(snapshot.unitsPerUSD["USD"], 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.unitsPerUSD["EUR"]), 1 / 1.2, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(snapshot.unitsPerUSD["CNY"]), 7, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(snapshot.unitsPerUSD["JPY"]), 150, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.effectiveDate, "2026-08-08")
    }

    func testCurrencyDisplaySanitizesInvalidOrUnsupportedRates() {
        let settings = CurrencyDisplaySettings(
            currency: .cny,
            unitsPerUSD: ["CNY": -.infinity, "FAKE": 99]
        ).sanitized

        XCTAssertEqual(settings.currency, .usd)
        XCTAssertEqual(settings.unitsPerUSD, ["USD": 1])
    }

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

    func testMCPToolsExposeReadOnlyContextAndBillableGenerationContracts() throws {
        let snapshot = AgentReadOnlySnapshot(
            serviceRunning: true,
            baseURL: "http://127.0.0.1:11435/v1",
            availableModels: ["usable"],
            enabledProviders: 1,
            enabledRoutes: 1,
            month: "2026-08",
            requests: 3,
            successfulRequests: 2,
            estimatedCostUSD: 0.1,
            taskContext: "读取当前任务并检查可用模型"
        )
        let listRequest = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let listResponse = LocalAgentProtocols.mcp(requestBody: listRequest, snapshot: snapshot)
        let listRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: listResponse.body) as? [String: Any]
        )
        let listResult = try XCTUnwrap(listRoot["result"] as? [String: Any])
        let tools = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        let toolsByName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
            (tool["name"] as? String).map { ($0, tool) }
        })
        XCTAssertNotNil(toolsByName["get_task_context"])
        XCTAssertNotNil(toolsByName["generate_text"])
        XCTAssertNotNil(toolsByName["generate_image"])
        XCTAssertNotNil(toolsByName["generate_video"])
        XCTAssertNotNil(toolsByName["generate_speech"])
        XCTAssertNotNil(toolsByName["get_video_task"])
        XCTAssertNotNil(toolsByName["create_embeddings"])
        XCTAssertNotNil(toolsByName["rerank_documents"])

        let videoTool = try XCTUnwrap(toolsByName["generate_video"])
        let videoSchema = try XCTUnwrap(videoTool["inputSchema"] as? [String: Any])
        let required = try XCTUnwrap(videoSchema["required"] as? [String])
        XCTAssertTrue(required.contains("model"))
        XCTAssertTrue(required.contains("prompt"))
        XCTAssertTrue(required.contains("confirm_billable"))
        let videoAnnotations = try XCTUnwrap(videoTool["annotations"] as? [String: Any])
        XCTAssertEqual(videoAnnotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(videoAnnotations["idempotentHint"] as? Bool, false)

        let callRequest = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_available_models","arguments":{}}}"#.utf8)
        let callResponse = LocalAgentProtocols.mcp(requestBody: callRequest, snapshot: snapshot)
        let callText = String(decoding: callResponse.body, as: UTF8.self)
        XCTAssertTrue(callText.contains("usable"))
        XCTAssertFalse(callText.contains("quarantined"))

        let taskRequest = Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_task_context","arguments":{}}}"#.utf8)
        let taskResponse = LocalAgentProtocols.mcp(requestBody: taskRequest, snapshot: snapshot)
        XCTAssertTrue(String(decoding: taskResponse.body, as: UTF8.self).contains("读取当前任务并检查可用模型"))

        let generationRequest = Data(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"generate_video","arguments":{"model":"video-model","prompt":"海面日出","duration_seconds":4,"confirm_billable":true}}}"#.utf8)
        let invocation = try XCTUnwrap(
            LocalAgentProtocols.mcpActionInvocation(requestBody: generationRequest)
        )
        XCTAssertEqual(invocation.tool, .generateVideo)
        let invocationArguments = try XCTUnwrap(
            JSONSerialization.jsonObject(with: invocation.argumentsJSON) as? [String: Any]
        )
        XCTAssertEqual(invocationArguments["model"] as? String, "video-model")
        XCTAssertEqual(invocationArguments["prompt"] as? String, "海面日出")
        XCTAssertEqual(invocationArguments["duration_seconds"] as? Int, 4)
        XCTAssertEqual(invocationArguments["confirm_billable"] as? Bool, true)

        let initializeRequest = Data(#"{"jsonrpc":"2.0","id":3,"method":"initialize"}"#.utf8)
        let initializeText = String(
            decoding: LocalAgentProtocols.mcp(
                requestBody: initializeRequest,
                snapshot: snapshot
            ).body,
            as: UTF8.self
        )
        XCTAssertTrue(initializeText.contains(#""version":"1.9.0""#))
        XCTAssertTrue(String(
            decoding: LocalAgentProtocols.a2aAgentCard(baseURL: "http://127.0.0.1"),
            as: UTF8.self
        ).contains(#""version":"1.9.0""#))
        XCTAssertTrue(String(
            decoding: LocalAgentProtocols.acpManifest(baseURL: "http://127.0.0.1"),
            as: UTF8.self
        ).contains(#""version":"1.9.0""#))
    }

    func testMCPGenerationArgumentsMapToProtectedGatewayRequests() throws {
        let videoInvocation = MCPActionInvocation(
            tool: .generateVideo,
            argumentsJSON: Data(#"{"model":"video-model","prompt":"海面日出","duration_seconds":4,"size":"720p","confirm_billable":true}"#.utf8)
        )
        let videoRequest = try LocalAgentProtocols.gatewayRequest(for: videoInvocation)
        XCTAssertEqual(videoRequest.method, "POST")
        XCTAssertEqual(videoRequest.path, "/v1/videos/generations")
        let videoBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: videoRequest.body) as? [String: Any]
        )
        XCTAssertEqual(videoBody["model"] as? String, "video-model")
        XCTAssertEqual(videoBody["prompt"] as? String, "海面日出")
        XCTAssertEqual(videoBody["duration"] as? Int, 4)
        XCTAssertNil(videoBody["confirm_billable"])

        let deniedInvocation = MCPActionInvocation(
            tool: .generateImage,
            argumentsJSON: Data(#"{"model":"image-model","prompt":"蓝点","confirm_billable":false}"#.utf8)
        )
        XCTAssertThrowsError(try LocalAgentProtocols.gatewayRequest(for: deniedInvocation)) { error in
            XCTAssertEqual(error as? MCPActionValidationError, .billableConfirmationRequired)
        }

        let speechInvocation = MCPActionInvocation(
            tool: .generateSpeech,
            argumentsJSON: Data(#"{"model":"tts-model","input":"你好","voice":"Cherry","confirm_billable":true}"#.utf8)
        )
        let speechRequest = try LocalAgentProtocols.gatewayRequest(for: speechInvocation)
        XCTAssertEqual(speechRequest.path, "/v1/audio/speech")
        let speechBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: speechRequest.body) as? [String: Any]
        )
        XCTAssertEqual(speechBody["voice"] as? String, "Cherry")

        let unsafeTaskInvocation = MCPActionInvocation(
            tool: .getVideoTask,
            argumentsJSON: Data(#"{"model":"video-model","task_id":"task/unsafe"}"#.utf8)
        )
        XCTAssertThrowsError(try LocalAgentProtocols.gatewayRequest(for: unsafeTaskInvocation))

        let taskInvocation = MCPActionInvocation(
            tool: .getVideoTask,
            argumentsJSON: Data(#"{"model":"video-model","task_id":"task-safe_123"}"#.utf8)
        )
        let taskRequest = try LocalAgentProtocols.gatewayRequest(for: taskInvocation)
        XCTAssertEqual(taskRequest.method, "GET")
        XCTAssertEqual(taskRequest.path, "/v1/videos/task-safe_123")
        XCTAssertEqual(taskRequest.queryItems["model"], "video-model")
    }
}
