import Foundation
import XCTest
@testable import ModelHubCore

final class ModelHealthTests: XCTestCase {
    func testModelCategoriesExposeReasoningTextImageMusicAndVideoLabels() {
        XCTAssertEqual(
            ModelCategory.allCases.map(\.displayName),
            ["逻辑推理", "文字", "图片", "音乐", "视频"]
        )
        XCTAssertEqual(
            ModelCategory.infer(model: "deepseek-r1", capabilities: [.reasoning]),
            [.reasoning]
        )
        XCTAssertEqual(
            ModelCategory.infer(model: "gpt-4.1", capabilities: [.chat]),
            [.text]
        )
        XCTAssertEqual(
            ModelCategory.infer(model: "gpt-image-1", capabilities: [.imageGeneration]),
            [.image]
        )
        XCTAssertEqual(
            ModelCategory.infer(model: "suno_music_open", capabilities: []),
            [.music]
        )
        XCTAssertEqual(
            ModelCategory.infer(model: "doubao-seedance-2.0", capabilities: [.videoGeneration]),
            [.video]
        )
    }

    func testProviderKindsIncludeCommonOpenAICompatibleVendors() {
        XCTAssertEqual(ProviderKind.openRouter.defaultBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(ProviderKind.togetherAI.defaultBaseURL, "https://api.together.xyz/v1")
        XCTAssertEqual(ProviderKind.fireworksAI.defaultBaseURL, "https://api.fireworks.ai/inference/v1")
        XCTAssertEqual(ProviderKind.siliconFlow.defaultBaseURL, "https://api.siliconflow.cn/v1")
        XCTAssertEqual(ProviderKind.volcengine.defaultBaseURL, "https://ark.cn-beijing.volces.com/api/v3")
        XCTAssertEqual(ProviderKind.baiduQianfan.defaultBaseURL, "https://qianfan.baidubce.com/v2")
        XCTAssertTrue(ProviderKind.openRouter.usesOpenAIProtocol)
        XCTAssertTrue(ProviderKind.volcengine.needsAPIKey)
    }

    func testNativeManualProbeMapsVideoToGenerationOperationAndBody() throws {
        XCTAssertEqual(
            ModelProbePolicy.nativeOperation(for: .videoGeneration),
            .videoGeneration
        )
        let body = try XCTUnwrap(
            ModelProbePolicy.nativeProbeBody(
                for: .videoGeneration,
                model: "doubao-seedance-2.0"
            )
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["prompt"] as? String, "ModelHub connection test")
        XCTAssertEqual(json["duration"] as? Int, 4)
    }

    func testNativeManualProbeCanBypassQuarantineOnlyWhenExplicitlyAllowed() {
        XCTAssertTrue(
            ModelProbePolicy.shouldSkipNativeProbe(
                status: .unavailable,
                nativeProtocol: .videoGeneration,
                allowNativeProbe: false
            )
        )
        XCTAssertFalse(
            ModelProbePolicy.shouldSkipNativeProbe(
                status: .unavailable,
                nativeProtocol: .videoGeneration,
                allowNativeProbe: true
            )
        )
    }

    func testAvailableCatalogIncludesOnlyAvailableDirectModelsAndUsableRoutes() {
        let provider = ProviderConfig(
            name: "示例",
            kind: .openAI,
            baseURL: "https://example.com",
            models: ["ready", "unknown", "blocked"]
        )
        let usableRoute = RouteConfig(
            alias: "smart",
            targets: [RouteTarget(providerID: provider.id, model: "ready")]
        )
        let blockedRoute = RouteConfig(
            alias: "offline",
            targets: [RouteTarget(providerID: provider.id, model: "blocked")]
        )
        let entries = AvailableModelCatalog.entries(
            routes: [usableRoute, blockedRoute],
            providers: [provider],
            healthRecords: [
                ModelHealthRecord(providerID: provider.id, model: "ready", status: .available),
                ModelHealthRecord(providerID: provider.id, model: "blocked", status: .unavailable)
            ]
        )

        XCTAssertEqual(entries.map(\.id), ["smart", "示例/ready"])
        XCTAssertEqual(entries.map(\.isRoute), [true, false])
    }

    func testAvailableCatalogExcludesTargetsFromDisabledProviders() {
        let provider = ProviderConfig(
            name: "停用供应商",
            kind: .openAI,
            baseURL: "https://example.com",
            enabled: false,
            models: ["ready"]
        )
        let route = RouteConfig(
            alias: "smart",
            targets: [RouteTarget(providerID: provider.id, model: "ready")]
        )

        let entries = AvailableModelCatalog.entries(
            routes: [route],
            providers: [provider],
            healthRecords: [
                ModelHealthRecord(providerID: provider.id, model: "ready", status: .available)
            ]
        )

        XCTAssertTrue(entries.isEmpty)
    }

    func testLegacyConfigurationDecodesWithEmptyModelHealth() throws {
        let json = """
        {
          "providers": [],
          "routes": [],
          "server": {
            "port": 11435,
            "requireAuthentication": true,
            "startAutomatically": true
          }
        }
        """

        let configuration = try JSONDecoder().decode(
            AppConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(configuration.modelHealth.isEmpty)
    }

    func testLegacyCustomPortIsNormalizedToFixedGatewayPort() throws {
        let json = """
        {
          "providers": [],
          "routes": [],
          "server": {
            "port": 54321,
            "requireAuthentication": true,
            "startAutomatically": true
          }
        }
        """

        let configuration = try JSONDecoder().decode(
            AppConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(configuration.server.port, ServerSettings.fixedPort)
        XCTAssertEqual(configuration.server.port, 11_435)
    }

    func testHealthIndexTreatsMissingRecordsAsUnavailable() {
        let providerID = UUID()
        let records = [
            ModelHealthRecord(providerID: providerID, model: "offline", status: .unavailable),
            ModelHealthRecord(providerID: providerID, model: "online", status: .available)
        ]
        let index = ModelHealthIndex(records: records)

        let ordered = index.order(
            models: ["offline", "unknown", "online"],
            providerID: providerID
        )

        XCTAssertEqual(index.status(providerID: providerID, model: "unknown"), .unavailable)
        XCTAssertEqual(ordered, ["online", "offline", "unknown"])
    }

    func testLatestDuplicateHealthRecordWins() {
        let providerID = UUID()
        let older = ModelHealthRecord(
            providerID: providerID,
            model: "model",
            status: .unavailable,
            checkedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = ModelHealthRecord(
            providerID: providerID,
            model: "model",
            status: .available,
            checkedAt: Date(timeIntervalSince1970: 20)
        )

        let index = ModelHealthIndex(records: [older, newer])

        XCTAssertEqual(index.status(providerID: providerID, model: "model"), .available)
    }

    func testSuccessfulHTTPStatusIsAvailable() {
        XCTAssertEqual(ModelAvailability(statusCode: 204), .available)
    }

    func testFailureHTTPStatusIsUnavailable() {
        XCTAssertEqual(ModelAvailability(statusCode: 429), .unavailable)
        XCTAssertEqual(ModelAvailability(statusCode: 500), .unavailable)
    }

    func testOnlyVerifiedAvailableModelsAreRoutable() {
        XCTAssertTrue(ModelAvailability.available.isRoutable)
        XCTAssertFalse(ModelAvailability.unknown.isRoutable)
        XCTAssertFalse(ModelAvailability.unavailable.isRoutable)
        XCTAssertFalse(ModelAvailability.configurationRequired.isRoutable)
        XCTAssertFalse(ModelAvailability.unsupported.isRoutable)
    }

    func testAuthenticationFailureRequiresCredentialInsteadOfMarkingModelUnavailable() {
        XCTAssertEqual(ModelAvailability(statusCode: 401), .configurationRequired)
        XCTAssertEqual(ModelAvailability(statusCode: 403), .configurationRequired)
    }

    func testMissingCredentialIsNotReportedAsModelUnavailable() {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .openAICompatible,
            baseURL: "https://yunwu.ai/v1",
            models: ["gpt-4o"]
        )

        XCTAssertEqual(
            ModelProbePolicy.disposition(
                provider: provider,
                model: "gpt-4o",
                hasAPIKey: false
            ),
            .configurationRequired
        )
    }

    func testNativeMediaModelsUseReadyNativeProtocolDisposition() {
        let seedance = ProviderConfig(
            name: "APIMart Seedance",
            kind: .openAICompatible,
            baseURL: "https://api.apimart.ai",
            models: ["doubao-seedance-2.0"]
        )
        let bailianTTS = ProviderConfig(
            name: "阿里云百炼 TTS",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            models: ["qwen3-tts-flash"]
        )
        let agnesImage = ProviderConfig(
            name: "Agnes AI",
            kind: .openAICompatible,
            baseURL: "https://apihub.agnes-ai.com/v1",
            models: ["agnes-image-2.1-flash"]
        )

        XCTAssertEqual(
            ModelProbePolicy.disposition(
                provider: seedance,
                model: "doubao-seedance-2.0",
                hasAPIKey: true
            ),
            .readyForNativeProtocol(.videoGeneration)
        )
        XCTAssertEqual(
            ModelProbePolicy.disposition(
                provider: bailianTTS,
                model: "qwen3-tts-flash",
                hasAPIKey: true
            ),
            .readyForNativeProtocol(.speech)
        )
        XCTAssertEqual(
            ModelProbePolicy.disposition(
                provider: agnesImage,
                model: "agnes-image-2.1-flash",
                hasAPIKey: true
            ),
            .readyForNativeProtocol(.imageGeneration)
        )
    }

    func testEmbeddingAndRerankingProtocolsAreClassifiedSeparately() {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .openAICompatible,
            baseURL: "https://yunwu.ai/v1"
        )

        XCTAssertEqual(
            ModelProbePolicy.nativeProtocol(provider: provider, model: "text-embedding-3-small"),
            .embeddings
        )
        XCTAssertEqual(
            ModelProbePolicy.nativeProtocol(provider: provider, model: "qwen3-rerank"),
            .reranking
        )
        XCTAssertEqual(
            ModelProbePolicy.nativeProtocol(provider: provider, model: "whisper-1"),
            .transcription
        )
    }

    func testVendorActionModelsUseProviderNativePassthrough() {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .openAICompatible,
            baseURL: "https://yunwu.ai/v1"
        )

        for model in [
            "mj_imagine",
            "suno_music_open",
            "kling-video-o1",
            "pixverse-v4.5",
            "happyhorse-video",
            "vidu2.0-i2v"
        ] {
            XCTAssertEqual(
                ModelProbePolicy.nativeProtocol(provider: provider, model: model),
                .providerNative,
                model
            )
        }
    }

    func testChatModelWithCredentialIsReadyForProbe() {
        let provider = ProviderConfig(
            name: "Agnes AI",
            kind: .openAICompatible,
            baseURL: "https://apihub.agnes-ai.com/v1",
            models: ["agnes-2.0-flash"]
        )

        XCTAssertEqual(
            ModelProbePolicy.disposition(
                provider: provider,
                model: "agnes-2.0-flash",
                hasAPIKey: true
            ),
            .readyForChatProbe
        )
    }

    func testLegacyFalseUnavailableNativeRecordsRemainSafelyQuarantinedOnUpgrade() {
        let provider = ProviderConfig(
            name: "阿里云百炼 TTS",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            models: ["qwen3-tts-flash"]
        )
        let chatProvider = ProviderConfig(
            name: "云雾 API",
            kind: .openAICompatible,
            baseURL: "https://yunwu.ai/v1",
            models: ["qwen-plus"]
        )
        let records = [
            ModelHealthRecord(
                providerID: provider.id,
                model: "qwen3-tts-flash",
                status: .unavailable,
                latencyMilliseconds: 80,
                statusCode: 400,
                detail: "HTTP 400 · 80 ms"
            ),
            ModelHealthRecord(
                providerID: chatProvider.id,
                model: "qwen-plus",
                status: .unavailable,
                detail: "未配置 API Key"
            )
        ]

        let normalized = ModelHealthMigration.normalize(
            records: records,
            providers: [provider, chatProvider]
        )

        XCTAssertEqual(normalized[0].status, .unavailable)
        XCTAssertNil(normalized[0].statusCode)
        XCTAssertTrue(normalized[0].detail.contains("已隔离"))
        XCTAssertEqual(normalized[1].status, .configurationRequired)
    }

    func testMigrationEliminatesUnknownAndSeedsMissingConfiguredModels() {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .openAICompatible,
            baseURL: "https://example.com/v1",
            models: ["chat-old", "chat-new", "image-new"]
        )
        let unknown = ModelHealthRecord(
            providerID: provider.id,
            model: "chat-old",
            status: .unknown,
            detail: "旧版未测试状态"
        )

        let normalized = ModelHealthMigration.normalize(
            records: [unknown],
            providers: [provider]
        )
        let index = ModelHealthIndex(records: normalized)

        XCTAssertEqual(normalized.count, 3)
        XCTAssertFalse(normalized.contains { $0.status == .unknown })
        XCTAssertEqual(index.status(providerID: provider.id, model: "chat-old"), .unavailable)
        XCTAssertEqual(index.status(providerID: provider.id, model: "chat-new"), .unavailable)
        XCTAssertEqual(index.status(providerID: provider.id, model: "image-new"), .unavailable)
        XCTAssertTrue(normalized.allSatisfy { $0.detail.contains("已隔离") })
    }

    func testVerifiedNativeHealthRecordSurvivesMigration() {
        let provider = ProviderConfig(
            name: "Agnes AI",
            kind: .openAICompatible,
            baseURL: "https://apihub.agnes-ai.com/v1",
            models: ["agnes-image-2.1-flash"]
        )
        let record = ModelHealthRecord(
            providerID: provider.id,
            model: "agnes-image-2.1-flash",
            status: .available,
            latencyMilliseconds: 912,
            statusCode: 200,
            detail: "原生图像生成 · HTTP 200 · 912 ms"
        )

        let normalized = ModelHealthMigration.normalize(
            records: [record],
            providers: [provider]
        )

        XCTAssertEqual(normalized, [record])
    }

    func testManuallyRestoredNativeModelStaysAvailableAfterRestartMigration() {
        let provider = ProviderConfig(
            name: "Agnes AI",
            kind: .openAICompatible,
            baseURL: "https://apihub.agnes-ai.com/v1",
            models: ["agnes-image-2.1-flash"]
        )
        let record = ModelHealthRecord(
            providerID: provider.id,
            model: "agnes-image-2.1-flash",
            status: .available,
            detail: "人工解除隔离并标记为可用"
        )

        let normalized = ModelHealthMigration.normalize(
            records: [record],
            providers: [provider]
        )

        XCTAssertEqual(normalized, [record])
    }
}
