import XCTest
@testable import ModelHubCore

final class ProviderModelCatalogTests: XCTestCase {
    override func tearDown() {
        CatalogURLProtocolStub.responseBody = Data()
        CatalogURLProtocolStub.statusCode = 200
        CatalogURLProtocolStub.failuresBeforeSuccess = 0
        CatalogURLProtocolStub.failureCode = .unknown
        CatalogURLProtocolStub.attemptCount = 0
        super.tearDown()
    }

    func testParsesCommonCatalogShapesAndDeduplicatesStably() throws {
        let openAIShape = Data(#"{"data":[{"id":"model-a"},{"id":"Model-A"},{"id":"model-b"}]}"#.utf8)
        XCTAssertEqual(
            try ProviderModelCatalogParser.parse(openAIShape),
            ["model-a", "model-b"]
        )

        let geminiShape = Data(#"{"models":[{"name":"models/gemini-2.5-pro"},{"name":"models/gemini-2.5-flash"}]}"#.utf8)
        XCTAssertEqual(
            try ProviderModelCatalogParser.parse(geminiShape),
            ["models/gemini-2.5-pro", "models/gemini-2.5-flash"]
        )

        let nestedShape = Data(#"{"result":{"items":["qwen-max",{"model_id":"qwen-plus"}]}}"#.utf8)
        XCTAssertEqual(
            try ProviderModelCatalogParser.parse(nestedShape),
            ["qwen-max", "qwen-plus"]
        )

        let bailianShape = Data(
            #"{"output":{"models":[{"model_name":"qwen3-8b"},{"model_name":"qwen3-32b"}]}}"#.utf8
        )
        XCTAssertEqual(
            try ProviderModelCatalogParser.parse(bailianShape),
            ["qwen3-8b", "qwen3-32b"]
        )
    }

    func testRejectsInvalidEmptyAndOversizedCatalogs() throws {
        XCTAssertThrowsError(try ProviderModelCatalogParser.parse(Data("not-json".utf8)))
        XCTAssertThrowsError(try ProviderModelCatalogParser.parse(Data(#"{"data":[]}"#.utf8)))
        XCTAssertThrowsError(try ProviderModelCatalogParser.parse(
            Data(repeating: 0, count: ProviderModelCatalogParser.maximumResponseBytes + 1)
        ))
    }

    func testCatalogRequestUsesExactConfiguredURLAndProviderHeader() throws {
        let provider = ProviderConfig(
            name: "Gemini",
            kind: .gemini,
            baseURL: "https://example.com/chat",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .modelCatalog):
                    "https://catalog.example.com/custom/list?page=1"
            ]
        )
        let request = try ProviderClient().modelCatalogRequest(
            provider: provider,
            apiKey: "secret"
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://catalog.example.com/custom/list?page=1"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCatalogRequestRequiresExplicitEndpointAndRejectsCredentialURLs() throws {
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/exact-catalog"
        )
        XCTAssertThrowsError(try ProviderClient().modelCatalogRequest(
            provider: provider,
            apiKey: "secret"
        )) { error in
            XCTAssertEqual(error as? ProviderModelCatalogError, .missingEndpoint)
        }

        var unsafe = provider
        unsafe.endpointURLs[ProviderEndpointRecord.key(for: .modelCatalog)] =
            "https://example.com/models?api_key=secret"
        XCTAssertThrowsError(try ProviderClient().modelCatalogRequest(
            provider: unsafe,
            apiKey: "secret"
        )) { error in
            XCTAssertEqual(error as? ProviderModelCatalogError, .credentialInURL)
        }

        var insecure = provider
        insecure.endpointURLs[ProviderEndpointRecord.key(for: .modelCatalog)] =
            "http://catalog.example.com/models"
        XCTAssertThrowsError(try ProviderClient().modelCatalogRequest(
            provider: insecure,
            apiKey: "secret"
        )) { error in
            XCTAssertEqual(error as? ProviderModelCatalogError, .insecureEndpoint)
        }

        var loopback = provider
        loopback.kind = .ollama
        loopback.endpointURLs[ProviderEndpointRecord.key(for: .modelCatalog)] =
            "http://127.0.0.1:11434/api/tags"
        XCTAssertNoThrow(try ProviderClient().modelCatalogRequest(
            provider: loopback,
            apiKey: nil
        ))
    }

    func testBailianAccountCatalogIsExplicitCallableAndRestrictedToVerifiedHost() {
        let provider = ProviderConfig(
            name: "阿里云百炼",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertEqual(
            ProviderModelCatalogSuggestions.exactURL(for: provider)?.absoluteString,
            "https://dashscope.aliyuncs.com/api/v1/models"
        )
        XCTAssertEqual(
            ProviderModelCatalogSuggestions.suggestion(for: provider)?.importBehavior,
            .directlyCallable
        )
        XCTAssertTrue(
            ProviderModelCatalogMergePolicy.shouldAutomaticallyMerge(
                provider: provider,
                endpoint: ProviderModelCatalogSuggestions.exactURL(for: provider)!
            )
        )

        var customRegion = provider
        customRegion.baseURL = "https://workspace.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
        XCTAssertNil(ProviderModelCatalogSuggestions.exactURL(for: customRegion))
    }

    func testBailianTokenPlansUseVerifiedCompatibleModelCatalogEndpoint() {
        let expected = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/models"
        for kind in [ProviderKind.qwenPersonal, .qwenEnterprise] {
            let provider = ProviderConfig(
                name: kind.displayName,
                kind: kind,
                baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
            )
            XCTAssertEqual(
                ProviderModelCatalogSuggestions.exactURL(for: provider)?.absoluteString,
                expected
            )
        }
    }

    func testBailianBusinessWorkspaceUsesPayAsYouGoAccountCatalog() {
        let provider = ProviderConfig(
            name: ProviderKind.qwenBusiness.displayName,
            kind: .qwenBusiness,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertEqual(
            ProviderModelCatalogSuggestions.exactURL(for: provider)?.absoluteString,
            "https://dashscope.aliyuncs.com/api/v1/models"
        )
    }

    func testNewlyVerifiedBuiltInCatalogsUseExactProviderOwnedURLs() {
        let expected: [(ProviderKind, String, String)] = [
            (.moonshot, "https://api.moonshot.cn/v1", "https://api.moonshot.cn/v1/models"),
            (.zhipu, "https://open.bigmodel.cn/api/paas/v4", "https://open.bigmodel.cn/api/paas/v4/models"),
            (.volcengine, "https://ark.cn-beijing.volces.com/api/v3", "https://ark.cn-beijing.volces.com/api/v3/models"),
        ]
        for (kind, baseURL, catalogURL) in expected {
            let provider = ProviderConfig(
                name: kind.displayName,
                kind: kind,
                baseURL: baseURL
            )
            XCTAssertEqual(
                ProviderModelCatalogSuggestions.exactURL(for: provider)?.absoluteString,
                catalogURL,
                kind.rawValue
            )
        }
    }

    func testAccountCallableCatalogsStillMergeAutomatically() throws {
        let provider = ProviderConfig(
            name: "DeepSeek",
            kind: .deepSeek,
            baseURL: "https://api.deepseek.com"
        )
        let endpoint = try XCTUnwrap(ProviderModelCatalogSuggestions.exactURL(for: provider))
        XCTAssertEqual(
            ProviderModelCatalogSuggestions.suggestion(for: provider)?.importBehavior,
            .directlyCallable
        )
        XCTAssertTrue(
            ProviderModelCatalogMergePolicy.shouldAutomaticallyMerge(
                provider: provider,
                endpoint: endpoint
            )
        )
    }

    func testHotUpdateAllowsExplicitAndVerifiedReferenceCatalogsBecauseNewModelsAreQuarantined() throws {
        let key = ProviderEndpointRecord.key(for: .modelCatalog)
        let customEndpoint = try XCTUnwrap(URL(string: "https://catalog.example.com/models"))
        let custom = ProviderConfig(
            name: "Custom",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1",
            endpointURLs: [key: customEndpoint.absoluteString]
        )
        XCTAssertTrue(
            ProviderModelCatalogMergePolicy.shouldHotUpdate(
                provider: custom,
                endpoint: customEndpoint
            )
        )

        var bailian = ProviderConfig(
            name: "阿里云百炼",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        let bailianEndpoint = try XCTUnwrap(
            ProviderModelCatalogSuggestions.exactURL(for: bailian)
        )
        bailian.endpointURLs[key] = bailianEndpoint.absoluteString
        XCTAssertTrue(
            ProviderModelCatalogMergePolicy.shouldHotUpdate(
                provider: bailian,
                endpoint: bailianEndpoint
            )
        )
    }

    func testVerifiedSuggestionRegistryCoversSupportedKindsWithoutGuessingCustomHosts() {
        let supported: [(ProviderKind, String, String)] = [
            (.anthropic, "https://api.anthropic.com", "https://api.anthropic.com/v1/models?limit=1000"),
            (.gemini, "https://generativelanguage.googleapis.com", "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"),
            (.deepSeek, "https://api.deepseek.com", "https://api.deepseek.com/models"),
            (.xAI, "https://api.x.ai", "https://api.x.ai/v1/models"),
            (.groq, "https://api.groq.com/openai/v1", "https://api.groq.com/openai/v1/models"),
            (.mistral, "https://api.mistral.ai", "https://api.mistral.ai/v1/models"),
            (.openRouter, "https://openrouter.ai/api/v1", "https://openrouter.ai/api/v1/models"),
            (.togetherAI, "https://api.together.xyz/v1", "https://api.together.xyz/v1/models"),
            (.fireworksAI, "https://api.fireworks.ai/inference/v1", "https://api.fireworks.ai/inference/v1/models"),
            (.perplexity, "https://api.perplexity.ai/v1", "https://api.perplexity.ai/v1/models"),
            (.cohere, "https://api.cohere.ai/compatibility/v1", "https://api.cohere.ai/v1/models"),
            (.siliconFlow, "https://api.siliconflow.cn/v1", "https://api.siliconflow.cn/v1/models"),
            (.baiduQianfan, "https://qianfan.baidubce.com/v2", "https://qianfan.baidubce.com/v2/models"),
            (.minimax, "https://api.minimax.io/v1", "https://api.minimax.io/v1/models"),
            (.minimaxChina, "https://api.minimaxi.com/v1", "https://api.minimaxi.com/v1/models"),
            (.qwenBusiness, "https://dashscope.aliyuncs.com/compatible-mode/v1", "https://dashscope.aliyuncs.com/api/v1/models")
        ]
        for (kind, baseURL, exactURL) in supported {
            let provider = ProviderConfig(name: kind.displayName, kind: kind, baseURL: baseURL)
            XCTAssertEqual(
                ProviderModelCatalogSuggestions.exactURL(for: provider)?.absoluteString,
                exactURL,
                kind.rawValue
            )
            var custom = provider
            custom.baseURL = "https://proxy.example.com/custom"
            XCTAssertNil(ProviderModelCatalogSuggestions.exactURL(for: custom), kind.rawValue)
        }

        let ollama = ProviderConfig(
            name: "Ollama",
            kind: .ollama,
            baseURL: "http://localhost:12434/custom"
        )
        XCTAssertEqual(
            ProviderModelCatalogSuggestions.exactURL(for: ollama)?.absoluteString,
            "http://localhost:12434/api/tags"
        )
    }

    func testVerifiedHostRegistrySupportsLegacyGenericProviderKinds() {
        let supported = [
            ("https://api.apimart.ai/v1/videos/generations", "https://api.apimart.ai/v1/models"),
            ("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "https://dashscope.aliyuncs.com/api/v1/models"),
            ("https://apihub.agnes-ai.com/v1/chat/completions", "https://apihub.agnes-ai.com/v1/models"),
            ("https://apihub.agnes-ai.cn/v1/chat/completions", "https://apihub.agnes-ai.cn/v1/models"),
            ("https://yunwu.ai/v1/chat/completions", "https://yunwu.ai/v1/models"),
            ("https://api.euno-ai.com/v1/chat/completions", "https://api.euno-ai.com/v1/models"),
            ("https://godai.cloud/v1/chat/completions", "https://godai.cloud/v1/models")
        ]
        for (baseURL, expected) in supported {
            let provider = ProviderConfig(
                name: "Legacy Compatible",
                kind: .unifiedCompatible,
                baseURL: baseURL
            )
            XCTAssertEqual(
                ProviderModelCatalogSuggestions.exactURL(for: provider)?.absoluteString,
                expected
            )
        }
        XCTAssertNil(ProviderModelCatalogSuggestions.exactURL(for: ProviderConfig(
            name: "Custom",
            kind: .unifiedCompatible,
            baseURL: "https://proxy.example.com/v1/chat/completions"
        )))
    }

    func testCatalogMigrationPersistsOnlyVerifiedExactURLWithoutChangingBaseURL() throws {
        let original = ProviderConfig(
            name: "Legacy Agnes",
            kind: .unifiedCompatible,
            baseURL: "https://apihub.agnes-ai.cn/v1/chat/completions"
        )
        let migrated = try XCTUnwrap(
            ProviderModelCatalogMigration.migratedProvider(original)
        )
        XCTAssertEqual(migrated.baseURL, original.baseURL)
        XCTAssertEqual(
            migrated.endpointURLs[ProviderEndpointRecord.key(for: .modelCatalog)],
            "https://apihub.agnes-ai.cn/v1/models"
        )

        let custom = ProviderConfig(
            name: "Custom",
            kind: .unifiedCompatible,
            baseURL: "https://proxy.example.com/v1/chat/completions"
        )
        XCTAssertNil(ProviderModelCatalogMigration.migratedProvider(custom))
    }

    func testOnlyVerifiedMachineReadableCatalogSuggestionsAdvertisePriceSync() {
        let priced: [(ProviderKind, String)] = [
            (.xAI, "https://api.x.ai"),
            (.openRouter, "https://openrouter.ai/api/v1"),
            (.togetherAI, "https://api.together.xyz/v1"),
        ]
        for (kind, baseURL) in priced {
            let provider = ProviderConfig(name: kind.displayName, kind: kind, baseURL: baseURL)
            XCTAssertEqual(
                ProviderModelCatalogSuggestions.suggestion(for: provider)?.canReturnTokenPrices,
                true,
                kind.rawValue
            )
        }

        let unpriced = ProviderConfig(
            name: "DeepSeek",
            kind: .deepSeek,
            baseURL: "https://api.deepseek.com"
        )
        XCTAssertEqual(
            ProviderModelCatalogSuggestions.suggestion(for: unpriced)?.canReturnTokenPrices,
            false
        )
    }

    func testPricingPolicySkipsKnownUnpricedCatalogsButAllowsPricedAndCustomSources() throws {
        let catalogKey = ProviderEndpointRecord.key(for: .modelCatalog)
        for kind in ProviderKind.allCases where kind != .unifiedCompatible {
            let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: kind))
            let rawEndpoint = try XCTUnwrap(preset.endpointURLs[catalogKey])
            let endpoint = try XCTUnwrap(URL(string: rawEndpoint))
            let provider = preset.applying(
                to: ProviderConfig(name: kind.displayName, kind: kind, baseURL: ""),
                mode: .replaceURLs
            )
            let expectsMachinePrices: Bool = [.xAI, .openRouter, .togetherAI].contains(kind)
            XCTAssertEqual(
                ProviderModelCatalogPricingPolicy.shouldFetch(
                    provider: provider,
                    endpoint: endpoint
                ),
                expectsMachinePrices,
                kind.rawValue
            )
        }

        let custom = ProviderConfig(
            name: "Custom",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1",
            endpointURLs: [catalogKey: "https://pricing.example.com/models"]
        )
        XCTAssertTrue(
            ProviderModelCatalogPricingPolicy.shouldFetch(
                provider: custom,
                endpoint: try XCTUnwrap(URL(string: "https://pricing.example.com/models"))
            )
        )
    }

    func testPricingPolicyExplainsWhyBuiltInCatalogCannotSupplyPrices() throws {
        let catalogKey = ProviderEndpointRecord.key(for: .modelCatalog)
        for kind in [ProviderKind.minimax, .apimart, .yunwu, .qwenEnterprise] {
            let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: kind))
            let provider = preset.applying(
                to: ProviderConfig(name: kind.displayName, kind: kind, baseURL: ""),
                mode: .replaceURLs
            )
            let endpoint = try XCTUnwrap(URL(string: provider.endpointURLs[catalogKey]!))
            let availability = ProviderModelCatalogPricingPolicy.availability(
                provider: provider,
                endpoint: endpoint
            )
            guard case .unavailable(let reason) = availability else {
                return XCTFail("Expected unavailable pricing for \(kind.rawValue)")
            }
            XCTAssertFalse(reason.isEmpty)
        }

        let openRouterPreset = try XCTUnwrap(
            ProviderConnectionPresets.preset(for: .openRouter)
        )
        let openRouter = openRouterPreset.applying(
            to: ProviderConfig(name: "OpenRouter", kind: .openRouter, baseURL: ""),
            mode: .replaceURLs
        )
        let endpoint = try XCTUnwrap(URL(string: openRouter.endpointURLs[catalogKey]!))
        XCTAssertEqual(
            ProviderModelCatalogPricingPolicy.availability(
                provider: openRouter,
                endpoint: endpoint
            ),
            .available
        )
    }

    func testParsesOnlyDocumentedMachineReadableTokenPrices() throws {
        let openRouter = Data(
            #"{"data":[{"id":"model-a","pricing":{"prompt":"0.00000125","completion":"0.000005"}}]}"#.utf8
        )
        let openRouterResult = try ProviderModelCatalogParser.parseDetailed(
            openRouter,
            providerKind: .openRouter,
            source: "https://openrouter.ai/api/v1/models"
        )
        XCTAssertEqual(openRouterResult.prices["model-a"]?.inputPerMillionTokensUSD, 1.25)
        XCTAssertEqual(openRouterResult.prices["model-a"]?.outputPerMillionTokensUSD, 5)

        let xAI = Data(
            #"{"data":[{"id":"grok-a","prompt_text_token_price":12500,"completion_text_token_price":100000}]}"#.utf8
        )
        let xAIResult = try ProviderModelCatalogParser.parseDetailed(
            xAI,
            providerKind: .xAI,
            source: "https://api.x.ai/v1/models"
        )
        XCTAssertEqual(xAIResult.prices["grok-a"]?.inputPerMillionTokensUSD, 1.25)
        XCTAssertEqual(xAIResult.prices["grok-a"]?.outputPerMillionTokensUSD, 10)

        let ambiguous = Data(
            #"{"data":[{"id":"unknown","pricing":{"input":999,"output":999}}]}"#.utf8
        )
        let ambiguousResult = try ProviderModelCatalogParser.parseDetailed(
            ambiguous,
            providerKind: .unifiedCompatible,
            source: "https://example.com/models"
        )
        XCTAssertTrue(ambiguousResult.prices.isEmpty)
    }

    func testPricingUpdaterPropagatesToProviderAndRouteWithoutClearingOtherProfileData() {
        let providerID = UUID()
        var provider = ProviderConfig(
            id: providerID,
            name: "OpenRouter",
            kind: .openRouter,
            baseURL: "https://openrouter.ai/api/v1",
            models: ["model-a"],
            modelProfiles: [
                " MODEL-A ": TargetProfile(
                    contextWindow: 128_000,
                    outputCostPerMillionTokens: 99,
                    capabilities: [.chat]
                )
            ]
        )
        var routes = [RouteConfig(
            alias: "smart",
            targets: [RouteTarget(providerID: providerID, model: "model-a")]
        )]
        let updatedAt = Date(timeIntervalSince1970: 123)
        let count = ProviderModelPricingUpdater.apply(
            prices: [
                "MODEL-A": ProviderModelPrice(
                    inputPerMillionTokensUSD: 1.5,
                    perRequestUSD: 0.02,
                    source: "official-catalog"
                )
            ],
            to: &provider,
            routes: &routes,
            updatedAt: updatedAt
        )
        XCTAssertEqual(count, 1)
        XCTAssertEqual(provider.modelProfiles?["model-a"]?.contextWindow, 128_000)
        XCTAssertEqual(provider.modelProfiles?["model-a"]?.capabilities, [.chat])
        XCTAssertEqual(provider.modelProfiles?["model-a"]?.inputCostPerMillionTokens, 1.5)
        XCTAssertEqual(provider.modelProfiles?["model-a"]?.outputCostPerMillionTokens, 99)
        XCTAssertEqual(provider.modelProfiles?["model-a"]?.requestCostUSD, 0.02)
        XCTAssertEqual(provider.modelProfiles?.count, 1)
        XCTAssertEqual(routes[0].targets[0].profile?.inputCostPerMillionTokens, 1.5)
        XCTAssertEqual(routes[0].targets[0].profile?.pricingUpdatedAt, updatedAt)
    }

    func testParsesExplicitOfficialPerRequestPriceWithoutGuessingUnits() throws {
        let data = Data(#"{"data":[{"id":"image-model","price_per_request_usd":0.04}]}"#.utf8)

        let parsed = try ProviderModelCatalogParser.parseDetailed(
            data,
            providerKind: .unifiedCompatible,
            source: "https://provider.example/models"
        )

        XCTAssertEqual(parsed.prices["image-model"]?.perRequestUSD, 0.04)
        XCTAssertNil(parsed.prices["image-model"]?.inputPerMillionTokensUSD)
    }

    func testImporterMergesWithoutLosingExistingOrder() {
        XCTAssertEqual(
            ProviderModelCatalogImporter.merging(
                existing: ["existing", "Model-A"],
                imported: ["model-a", "model-b", " model-c "]
            ),
            ["existing", "Model-A", "model-b", "model-c"]
        )
    }

    func testHotUpdaterPreservesExistingHealthAndQuarantinesNewModels() {
        var provider = ProviderConfig(
            name: "Existing Provider",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["model-a", "model-b"]
        )
        let unrelatedProviderID = UUID()
        let available = ModelHealthRecord(
            providerID: provider.id,
            model: "model-a",
            status: .available,
            statusCode: 200,
            detail: "verified"
        )
        let unavailable = ModelHealthRecord(
            providerID: provider.id,
            model: "model-b",
            status: .unavailable,
            statusCode: 404,
            detail: "HTTP 404"
        )
        let unrelated = ModelHealthRecord(
            providerID: unrelatedProviderID,
            model: "other-model",
            status: .available
        )
        var health = [available, unavailable, unrelated]

        let summary = ProviderModelCatalogHotUpdater.apply(
            importedModels: ["MODEL-B", "model-c"],
            to: &provider,
            healthRecords: &health
        )

        XCTAssertEqual(provider.models, ["model-a", "model-b", "model-c"])
        XCTAssertEqual(summary.catalogModelCount, 2)
        XCTAssertEqual(summary.addedModelCount, 1)
        XCTAssertEqual(summary.retainedModelCount, 2)
        XCTAssertTrue(health.contains(available))
        XCTAssertTrue(health.contains(unavailable))
        XCTAssertTrue(health.contains(unrelated))
        let newRecord = health.first {
            $0.providerID == provider.id && $0.model == "model-c"
        }
        XCTAssertEqual(newRecord?.status, .unavailable)
        XCTAssertEqual(newRecord?.detail, "尚未完成在线验证，已隔离")
    }

    func testFetchExecutesHTTPAndParsesCatalog() async throws {
        CatalogURLProtocolStub.responseBody = Data(
            #"{"data":[{"id":"live-a"},{"id":"live-b"}]}"#.utf8
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocolStub.self]
        let client = ProviderClient(session: URLSession(configuration: configuration))
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/chat",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .modelCatalog):
                    "https://catalog.example.com/exact"
            ]
        )
        let result = try await client.fetchModelCatalog(provider: provider, apiKey: "secret")
        XCTAssertEqual(result.models, ["live-a", "live-b"])
        XCTAssertEqual(result.endpoint.absoluteString, "https://catalog.example.com/exact")
        XCTAssertEqual(result.responseBytes, CatalogURLProtocolStub.responseBody.count)
    }

    func testCatalogRequestRejectsMismatchedBailianCredentialBeforeNetwork() throws {
        let preset = try XCTUnwrap(
            ProviderConnectionPresets.preset(for: .qwenEnterprise)
        )
        let provider = preset.applying(
            to: ProviderConfig(
                name: "阿里云百炼 Token Plan 团队版",
                kind: .qwenEnterprise,
                baseURL: ""
            ),
            mode: .replaceURLs
        )

        XCTAssertThrowsError(
            try ProviderClient().modelCatalogRequest(
                provider: provider,
                apiKey: "sk-ws-pay-as-you-go-token"
            )
        ) { error in
            guard case .credentialMismatch(let message) = error as? ProviderModelCatalogError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("sk-sp-"))
        }
    }

    func testCatalogFetchRetriesOneTransientSecureConnectionFailure() async throws {
        CatalogURLProtocolStub.responseBody = Data(
            #"{"data":[{"id":"live-after-retry"}]}"#.utf8
        )
        CatalogURLProtocolStub.failuresBeforeSuccess = 1
        CatalogURLProtocolStub.failureCode = .secureConnectionFailed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocolStub.self]
        let client = ProviderClient(session: URLSession(configuration: configuration))
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .modelCatalog):
                    "https://catalog.example.com/models"
            ]
        )

        let result = try await client.fetchModelCatalog(
            provider: provider,
            apiKey: "test-key",
            retryDelayNanoseconds: 0
        )

        XCTAssertEqual(result.models, ["live-after-retry"])
        XCTAssertEqual(CatalogURLProtocolStub.attemptCount, 2)
    }

    func testCatalogFetchMapsPersistentTLSFailureWithoutBypassingValidation() async throws {
        CatalogURLProtocolStub.failuresBeforeSuccess = .max
        CatalogURLProtocolStub.failureCode = .serverCertificateUntrusted
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocolStub.self]
        let client = ProviderClient(session: URLSession(configuration: configuration))
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .modelCatalog):
                    "https://catalog.example.com/models"
            ]
        )

        do {
            _ = try await client.fetchModelCatalog(
                provider: provider,
                apiKey: "test-key",
                retryDelayNanoseconds: 0
            )
            XCTFail("Expected TLS failure")
        } catch {
            XCTAssertEqual(
                error as? ProviderModelCatalogError,
                .secureConnectionFailed
            )
            XCTAssertEqual(CatalogURLProtocolStub.attemptCount, 1)
        }
    }

    func testCatalogFetchReestablishesSessionOnceAfterTUNTrustFailure() async throws {
        CatalogURLProtocolStub.responseBody = Data(
            #"{"data":[{"id":"live-after-tun-refresh"}]}"#.utf8
        )
        CatalogURLProtocolStub.failuresBeforeSuccess = 1
        CatalogURLProtocolStub.failureCode = .serverCertificateUntrusted

        let makeSession: @Sendable () -> URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CatalogURLProtocolStub.self]
            return URLSession(configuration: configuration)
        }

        let client = ProviderClient(
            session: makeSession(),
            catalogRecoverySessionFactory: { makeSession() }
        )
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .modelCatalog):
                    "https://catalog.example.com/models"
            ]
        )

        let result = try await client.fetchModelCatalog(
            provider: provider,
            apiKey: "test-key",
            retryDelayNanoseconds: 0
        )

        XCTAssertEqual(result.models, ["live-after-tun-refresh"])
        XCTAssertEqual(CatalogURLProtocolStub.attemptCount, 2)
    }

    func testCatalogSessionRecoveryStillRejectsPersistentUntrustedCertificate() async throws {
        CatalogURLProtocolStub.failuresBeforeSuccess = .max
        CatalogURLProtocolStub.failureCode = .serverCertificateUntrusted

        let makeSession: @Sendable () -> URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CatalogURLProtocolStub.self]
            return URLSession(configuration: configuration)
        }
        let client = ProviderClient(
            session: makeSession(),
            catalogRecoverySessionFactory: { makeSession() }
        )
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .modelCatalog):
                    "https://catalog.example.com/models"
            ]
        )

        do {
            _ = try await client.fetchModelCatalog(
                provider: provider,
                apiKey: "test-key",
                retryDelayNanoseconds: 0
            )
            XCTFail("Expected persistent TLS failure")
        } catch {
            XCTAssertEqual(
                error as? ProviderModelCatalogError,
                .secureConnectionFailed
            )
            XCTAssertEqual(CatalogURLProtocolStub.attemptCount, 2)
        }
    }

    func testCatalog401ProvidesProviderSpecificCredentialGuidance() async throws {
        CatalogURLProtocolStub.statusCode = 401
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocolStub.self]
        let client = ProviderClient(session: URLSession(configuration: configuration))
        let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: .minimax))
        let provider = preset.applying(
            to: ProviderConfig(name: "MiniMax", kind: .minimax, baseURL: ""),
            mode: .replaceURLs
        )

        do {
            _ = try await client.fetchModelCatalog(provider: provider, apiKey: "sk-test")
            XCTFail("Expected rejection")
        } catch {
            guard case .rejected(let statusCode, let providerKind) =
                error as? ProviderModelCatalogError
            else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(providerKind, .minimax)
            XCTAssertTrue(error.localizedDescription.contains("MiniMax"))
        }
    }

    func testMiniMaxChinaCatalog401SuggestsCorrectRegion() async throws {
        CatalogURLProtocolStub.statusCode = 401
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocolStub.self]
        let client = ProviderClient(session: URLSession(configuration: configuration))
        let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: .minimaxChina))
        let provider = preset.applying(
            to: ProviderConfig(name: "MiniMax 中国站", kind: .minimaxChina, baseURL: ""),
            mode: .replaceURLs
        )

        do {
            _ = try await client.fetchModelCatalog(provider: provider, apiKey: "test-key")
            XCTFail("Expected rejection")
        } catch {
            guard case .rejected(let statusCode, let providerKind) =
                error as? ProviderModelCatalogError
            else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(providerKind, .minimaxChina)
            XCTAssertTrue(error.localizedDescription.contains("api.minimaxi.com"))
            XCTAssertTrue(error.localizedDescription.contains("中国站"))
        }
    }
}

private final class CatalogURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var failuresBeforeSuccess = 0
    nonisolated(unsafe) static var failureCode = URLError.Code.unknown
    nonisolated(unsafe) static var attemptCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.attemptCount += 1
        if Self.attemptCount <= Self.failuresBeforeSuccess {
            client?.urlProtocol(self, didFailWithError: URLError(Self.failureCode))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: Self.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
