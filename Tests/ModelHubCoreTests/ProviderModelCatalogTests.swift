import XCTest
@testable import ModelHubCore

final class ProviderModelCatalogTests: XCTestCase {
    override func tearDown() {
        CatalogURLProtocolStub.responseBody = Data()
        CatalogURLProtocolStub.responseBodies = []
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

    func testDetailedCatalogPrefersExactModelIDAndExtractsCapabilityConstraints() throws {
        let body = Data(#"""
        {
          "models": [{
            "name": "Qwen Image 3.0 Pro",
            "model_id": "qwen-image-3.0-pro",
            "modality": {"input": ["text", "image"], "output": ["image"]},
            "supported_parameters": {
              "size": {"type": "string", "enum": ["1K", "2K"]},
              "n": {"type": "integer", "minimum": 1, "maximum": 6}
            }
          }]
        }
        """#.utf8)

        let parsed = try ProviderModelCatalogParser.parseDetailed(
            body,
            providerKind: .qwen,
            source: "https://platform.qianwenai.com/models"
        )

        XCTAssertEqual(parsed.models, ["qwen-image-3.0-pro"])
        let details = try XCTUnwrap(parsed.capabilityDetails["qwen-image-3.0-pro"])
        XCTAssertEqual(details.inputModalities, [.text, .image])
        XCTAssertEqual(details.outputModalities, [.image])
        XCTAssertEqual(
            details.image?.widthPixels,
            .range(minimum: 512, maximum: 2048, step: nil)
        )
        XCTAssertEqual(details.image?.maximumOutputs, 6)
        XCTAssertEqual(details.parameters.first(where: { $0.name == "n" })?.maximum, 6)
    }

    func testCatalogPaginationBuildsSameOriginNextPageAndStopsAtTotalPages() throws {
        let current = try XCTUnwrap(URL(
            string: "https://dashscope.aliyuncs.com/api/v1/deployments/models?page_no=1&page_size=100"
        ))
        let body = Data(#"{"page_no":1,"page_size":100,"total_pages":3,"models":[{"model_id":"qwen-a"}]}"#.utf8)

        XCTAssertEqual(
            try ProviderModelCatalogPagination.nextURL(responseBody: body, currentURL: current)?
                .absoluteString,
            "https://dashscope.aliyuncs.com/api/v1/deployments/models?page_no=2&page_size=100"
        )

        let lastBody = Data(#"{"page_no":3,"page_size":100,"total_pages":3,"models":[{"model_id":"qwen-c"}]}"#.utf8)
        XCTAssertNil(try ProviderModelCatalogPagination.nextURL(
            responseBody: lastBody,
            currentURL: current
        ))
    }

    func testCatalogFetchFollowsBoundedPaginationAndMergesEveryPage() async throws {
        CatalogURLProtocolStub.responseBodies = [
            Data(#"{"page":1,"total_pages":2,"models":[{"id":"model-a"}]}"#.utf8),
            Data(#"{"page":2,"total_pages":2,"models":[{"id":"model-b"}]}"#.utf8)
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocolStub.self]
        let client = ProviderClient(session: URLSession(configuration: configuration))
        let provider = ProviderConfig(
            name: "Paged",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .modelCatalog):
                    "https://catalog.example.com/models?page=1&limit=1"
            ]
        )

        let result = try await client.fetchModelCatalog(provider: provider, apiKey: "test-key")

        XCTAssertEqual(result.models, ["model-a", "model-b"])
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(CatalogURLProtocolStub.attemptCount, 2)
    }

    func testCapabilityMetadataSurvivesConfigurationRoundTrip() throws {
        let details = ModelCapabilityDetails(
            inputModalities: [.text],
            outputModalities: [.video],
            video: .init(
                resolutions: ["720P", "1080P"],
                durationsSeconds: .range(minimum: 2, maximum: 15, step: 1)
            ),
            source: "official"
        )
        let profile = TargetProfile(
            capabilities: [.videoGeneration],
            capabilityDetails: details
        )

        let decoded = try JSONDecoder().decode(
            TargetProfile.self,
            from: JSONEncoder().encode(profile)
        )

        XCTAssertEqual(decoded, profile)
    }

    func testCapabilityUpdaterPersistsCatalogMetadataWithoutOverwritingPrices() throws {
        var provider = ProviderConfig(
            name: "千问AI平台",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            models: ["wan2.7-t2v"]
        )
        provider.modelProfiles = [
            "wan2.7-t2v": TargetProfile(inputCostPerMillionTokens: 1.5)
        ]
        let details = ModelCapabilityDetails(
            inputModalities: [.text],
            outputModalities: [.video],
            video: .init(
                resolutions: ["720P", "1080P"],
                aspectRatios: ["16:9", "9:16"],
                durationsSeconds: .range(minimum: 2, maximum: 15, step: 1)
            ),
            source: "official-catalog"
        )

        let updated = ProviderModelCapabilityUpdater.apply(
            details: ["wan2.7-t2v": details],
            to: &provider
        )

        XCTAssertEqual(updated, 1)
        XCTAssertEqual(provider.modelProfiles?["wan2.7-t2v"]?.inputCostPerMillionTokens, 1.5)
        XCTAssertEqual(provider.modelProfiles?["wan2.7-t2v"]?.capabilityDetails, details)
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

    func testGlobalPricingRefreshSummaryDoesNotReportZeroUpdatesAsSuccess() {
        let summary = ProviderModelPriceRefreshSummary(
            totalProviders: 8,
            catalogsChecked: 0,
            catalogsFetched: 0,
            catalogsWithoutPrices: 0,
            modelsUpdated: 0,
            unavailablePriceSources: 7,
            missingCredentials: 1,
            failures: 0
        )

        XCTAssertFalse(summary.didUpdatePrices)
        XCTAssertEqual(
            summary.message(trigger: "手动"),
            "手动：未写入任何价格。8 个已启用供应商中：7 个模型目录不提供带明确币种和单位的机器可读价格，1 个缺少可用凭证，0 个目录已响应但没有明确价格，0 个请求失败。未修改现有费用；可在供应商编辑页导入其官方价格 CSV。"
        )
    }

    func testGlobalPricingRefreshSummaryReportsCatalogsWithoutMachineReadablePrices() {
        let summary = ProviderModelPriceRefreshSummary(
            totalProviders: 3,
            catalogsChecked: 2,
            catalogsFetched: 2,
            catalogsWithoutPrices: 1,
            modelsUpdated: 12,
            unavailablePriceSources: 1,
            missingCredentials: 0,
            failures: 0
        )

        XCTAssertTrue(summary.didUpdatePrices)
        XCTAssertEqual(
            summary.message(trigger: "自动"),
            "自动：检查 2 个价格目录，成功读取 2 个，更新 12 个模型价格；1 个目录未返回明确价格，1 个供应商无机器可读价格源，0 个缺少凭证，0 个失败。"
        )
    }

    func testGlobalPricingRefreshSummarySeparatesReferenceFallbackFromSettlementPrice() {
        let summary = ProviderModelPriceRefreshSummary(
            totalProviders: 8,
            catalogsChecked: 1,
            catalogsFetched: 1,
            catalogsWithoutPrices: 1,
            modelsUpdated: 0,
            unavailablePriceSources: 7,
            missingCredentials: 0,
            failures: 0,
            referenceModelsApplied: 128,
            modelsStillUnpriced: 348
        )

        XCTAssertTrue(summary.didUpdatePrices)
        XCTAssertTrue(summary.message(trigger: "手动").contains("内置上游公开参考价"))
        XCTAssertTrue(summary.message(trigger: "手动").contains("不代表当前渠道结算价"))
        XCTAssertTrue(summary.message(trigger: "手动").contains("CSV 和手动价始终优先"))
    }

    func testGlobalPricingRefreshSummaryReportsExistingReferenceCoverage() {
        let summary = ProviderModelPriceRefreshSummary(
            totalProviders: 2,
            catalogsChecked: 0,
            catalogsFetched: 0,
            catalogsWithoutPrices: 0,
            modelsUpdated: 0,
            unavailablePriceSources: 2,
            missingCredentials: 0,
            failures: 0,
            referenceModelsAvailable: 9,
            modelsStillUnpriced: 3
        )

        let message = summary.message(trigger: "手动")
        XCTAssertTrue(message.contains("当前 9 个模型已有"))
        XCTAssertTrue(message.contains("仍有 3 个模型无可靠参考价"))
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
            ["existing", "model-a", "model-b", "model-c"]
        )
    }

    func testCatalogSourceDoesNotPersistQueryParameters() async throws {
        CatalogURLProtocolStub.responseBody = Data(
            #"{"models":[{"id":"model-a","input_price":1,"output_modalities":["text"]}]}"#.utf8
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocolStub.self]
        let client = ProviderClient(session: URLSession(configuration: configuration))
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .modelCatalog):
                    "https://catalog.example.com/models?page=1"
            ]
        )

        let result = try await client.fetchModelCatalog(provider: provider, apiKey: "test-key")

        XCTAssertEqual(
            result.capabilityDetails["model-a"]?.source,
            "https://catalog.example.com/models"
        )
        XCTAssertNotNil(result.capabilityDetails["model-a"]?.updatedAt)
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

        XCTAssertEqual(provider.models, ["model-a", "MODEL-B", "model-c"])
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
    nonisolated(unsafe) static var responseBodies: [Data] = []
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
        let index = min(Self.attemptCount - 1, max(0, Self.responseBodies.count - 1))
        let body = Self.responseBodies.isEmpty ? Self.responseBody : Self.responseBodies[index]
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
