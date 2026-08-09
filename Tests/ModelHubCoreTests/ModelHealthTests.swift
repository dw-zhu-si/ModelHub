import Foundation
import XCTest
@testable import ModelHubCore

final class ModelHealthTests: XCTestCase {
    func testLegacyBaseURLMigrationRecordsCompleteEndpointsOnce() {
        let chat = ProviderConfig(
            name: "兼容网关",
            kind: .unifiedCompatible,
            baseURL: "https://gateway.example.com/v1",
            models: ["chat-model"]
        )
        let video = ProviderConfig(
            name: "seedance",
            kind: .unifiedCompatible,
            baseURL: "https://api.apimart.ai",
            models: ["doubao-seedance-2.0-fast"]
        )
        let complete = ProviderConfig(
            name: "完整端点",
            kind: .unifiedCompatible,
            baseURL: "https://gateway.example.com/custom/inference",
            models: ["chat-model"]
        )
        let speech = ProviderConfig(
            name: "阿里云百炼 TTS",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            models: ["qwen-audio-3.0-tts-plus"]
        )

        XCTAssertEqual(
            ProviderBaseURLMigration.completedLegacyURL(for: chat),
            "https://gateway.example.com/v1/chat/completions"
        )
        XCTAssertEqual(
            ProviderBaseURLMigration.completedLegacyURL(for: video),
            "https://api.apimart.ai/v1/videos/generations"
        )
        let migratedVideo = ProviderBaseURLMigration.migratedProvider(video)
        XCTAssertEqual(
            migratedVideo?.endpointURLs[
                ProviderEndpointRecord.key(for: .videoTask, model: "doubao-seedance-2.0-fast")
            ],
            "https://api.apimart.ai/v1/tasks/{task_id}"
        )
        XCTAssertEqual(
            ProviderBaseURLMigration.completedLegacyURL(for: speech),
            "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer"
        )
        let mixedSpeech = ProviderConfig(
            name: "阿里云百炼 TTS",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            models: ["qwen-audio-3.0-tts-plus", "qwen3-tts-flash"]
        )
        let migratedSpeech = ProviderBaseURLMigration.migratedProvider(mixedSpeech)
        XCTAssertEqual(
            migratedSpeech?.endpointURLs[
                ProviderEndpointRecord.key(for: .speech, model: "qwen-audio-3.0-tts-plus")
            ],
            "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer"
        )
        XCTAssertEqual(
            migratedSpeech?.endpointURLs[
                ProviderEndpointRecord.key(for: .speech, model: "qwen3-tts-flash")
            ],
            "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        )
        XCTAssertNil(ProviderBaseURLMigration.completedLegacyURL(for: complete))
    }

    func testRemovedDirectProvidersAreDisabledAndLegacyCompatibleProvidersMigrate() throws {
        let removed = try JSONDecoder().decode(
            ProviderConfig.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","kind":"openAI","baseURL":"https://legacy.invalid","enabled":true,"models":["legacy-model"],"apiVersion":""}"#.utf8)
        )
        XCTAssertEqual(removed.kind, .unifiedCompatible)
        XCTAssertEqual(removed.name, "已停用旧供应商")
        XCTAssertFalse(removed.enabled)
        XCTAssertEqual(removed.baseURL, "https://")
        XCTAssertTrue(removed.models.isEmpty)

        let compatible = try JSONDecoder().decode(
            ProviderConfig.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000002","name":"兼容网关","kind":"openAICompatible","baseURL":"https://gateway.example.com","enabled":true,"models":["text-model"],"apiVersion":""}"#.utf8)
        )
        XCTAssertEqual(compatible.kind, .unifiedCompatible)
        XCTAssertTrue(compatible.enabled)
        XCTAssertEqual(compatible.baseURL, "https://gateway.example.com")
        XCTAssertEqual(compatible.models, ["text-model"])
    }

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

    func testProviderKindsIncludeCommonUnifiedCompatibleVendors() {
        XCTAssertEqual(ProviderKind.openRouter.defaultBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(ProviderKind.togetherAI.defaultBaseURL, "https://api.together.xyz/v1")
        XCTAssertEqual(ProviderKind.fireworksAI.defaultBaseURL, "https://api.fireworks.ai/inference/v1")
        XCTAssertEqual(ProviderKind.siliconFlow.defaultBaseURL, "https://api.siliconflow.cn/v1")
        XCTAssertEqual(ProviderKind.volcengine.defaultBaseURL, "https://ark.cn-beijing.volces.com/api/v3")
        XCTAssertEqual(ProviderKind.baiduQianfan.defaultBaseURL, "https://qianfan.baidubce.com/v2")
        XCTAssertTrue(ProviderKind.openRouter.usesUnifiedProtocol)
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
        XCTAssertEqual(json["duration"] as? Int, 5)
        XCTAssertEqual(json["resolution"] as? String, "480p")
        XCTAssertEqual(json["size"] as? String, "16:9")
        XCTAssertEqual(json["generate_audio"] as? Bool, false)
    }

    func testVideoProbeRequiresARealTaskIdentifier() throws {
        let accepted = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"code":200,"data":[{"status":"submitted","task_id":"task_123"}]}"#.utf8)
        )
        let falsePositive = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"code":200,"message":"accepted"}"#.utf8)
        )
        let businessFailure = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"code":400,"data":[{"task_id":"not_accepted"}]}"#.utf8)
        )

        XCTAssertEqual(ModelProbePolicy.videoTaskID(in: accepted), "task_123")
        XCTAssertNil(ModelProbePolicy.videoTaskID(in: falsePositive))
        XCTAssertNil(ModelProbePolicy.videoTaskID(in: businessFailure))
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
            kind: .unifiedCompatible,
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
            kind: .unifiedCompatible,
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
            kind: .unifiedCompatible,
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
            kind: .unifiedCompatible,
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
            kind: .unifiedCompatible,
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
            kind: .unifiedCompatible,
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
            kind: .unifiedCompatible,
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

    func testBailianDeploymentAndWorkflowModelsNeverFallBackToChatProbe() {
        let provider = ProviderConfig(
            name: "阿里云百炼",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )

        for model in [
            "wanx-v1-0521", "emo", "emo-detect", "emo-v1", "emo-detect-v1",
            "animate-anyone", "animate-anyone-detect", "animate-anyone-gen2"
        ] {
            XCTAssertEqual(
                ModelProbePolicy.nativeProtocol(provider: provider, model: model),
                .providerNative,
                model
            )
            XCTAssertTrue(
                ModelProbePolicy.nativeProbeUnavailableReason(
                    provider: provider,
                    model: model,
                    nativeProtocol: .providerNative
                ).contains("不会作为聊天模型请求")
            )
        }
    }

    func testTranscriptionProbeBuildsSmallMultipartWAV() throws {
        let payload = try XCTUnwrap(
            ModelProbePolicy.nativeProbePayload(for: .transcription, model: "whisper-1")
        )
        XCTAssertTrue(payload.contentType.hasPrefix("multipart/form-data; boundary="))
        let text = String(decoding: payload.body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"modelhub-probe.wav\""))
        XCTAssertTrue(text.contains("name=\"model\""))
        XCTAssertTrue(text.contains("whisper-1"))
        XCTAssertLessThan(payload.body.count, 20_000)
    }

    func testChatModelWithCredentialIsReadyForProbe() {
        let provider = ProviderConfig(
            name: "Agnes AI",
            kind: .unifiedCompatible,
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
            kind: .unifiedCompatible,
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
            kind: .unifiedCompatible,
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

    func testMigrationPrunesRecordsForRemovedProvidersAndModels() {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["current"]
        )
        let removedProviderID = UUID()
        let normalized = ModelHealthMigration.normalize(
            records: [
                ModelHealthRecord(providerID: provider.id, model: "current", status: .available),
                ModelHealthRecord(providerID: provider.id, model: "removed", status: .unavailable),
                ModelHealthRecord(providerID: removedProviderID, model: "orphan", status: .unavailable)
            ],
            providers: [provider]
        )

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized.first?.model, "current")
        XCTAssertEqual(normalized.first?.status, .available)
    }

    func testRetryPolicyRespectsRetryAfterAndCapsAttempts() {
        XCTAssertEqual(
            ModelProbeRetryPolicy.decision(
                statusCode: 429,
                headers: ["Retry-After": "3"],
                attempt: 1
            ),
            .retry(after: 3)
        )
        XCTAssertEqual(
            ModelProbeRetryPolicy.decision(statusCode: 503, headers: [:], attempt: 1),
            .retry(after: 1)
        )
        XCTAssertEqual(
            ModelProbeRetryPolicy.decision(statusCode: 429, headers: [:], attempt: 2),
            .stop
        )
        XCTAssertEqual(
            ModelProbeRetryPolicy.decision(statusCode: 400, headers: [:], attempt: 1),
            .stop
        )
    }

    func testAdaptiveBatchPolicyThrottlesAfterRateLimitAndRecovers() {
        XCTAssertEqual(
            ModelTestBatchPolicy.nextSize(current: 3, statusCodes: [200, 429, 200]),
            1
        )
        XCTAssertEqual(
            ModelTestBatchPolicy.nextSize(current: 1, statusCodes: [200, 200, 200]),
            2
        )
        XCTAssertEqual(
            ModelTestBatchPolicy.nextSize(current: 2, statusCodes: [500]),
            2
        )
    }

    func testVerifiedNativeHealthRecordSurvivesMigration() {
        let provider = ProviderConfig(
            name: "Agnes AI",
            kind: .unifiedCompatible,
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
            kind: .unifiedCompatible,
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

    func testQuarantineCauseExplainsCommonHTTPFailures() {
        let providerID = UUID()
        let cases: [(Int, ModelQuarantineCause)] = [
            (400, .invalidRequest),
            (401, .invalidCredential),
            (403, .insufficientPermission),
            (404, .endpointOrModelNotFound),
            (408, .requestTimedOut),
            (429, .rateLimitedOrOutOfQuota),
            (500, .upstreamFailure),
            (504, .requestTimedOut),
        ]

        for (statusCode, expectedCause) in cases {
            let record = ModelHealthRecord(
                providerID: providerID,
                model: "test-\(statusCode)",
                status: ModelAvailability(statusCode: statusCode),
                statusCode: statusCode,
                detail: "HTTP \(statusCode)"
            )
            XCTAssertEqual(record.quarantineCause, expectedCause)
        }
    }

    func testQuarantineCauseUsesStatusAndSafeDetailFallbacks() {
        let providerID = UUID()
        XCTAssertEqual(
            ModelHealthRecord(
                providerID: providerID,
                model: "missing-key",
                status: .configurationRequired,
                detail: "需要配置 API Key（未发起请求）"
            ).quarantineCause,
            .missingCredential
        )
        XCTAssertEqual(
            ModelHealthRecord(
                providerID: providerID,
                model: "native",
                status: .unavailable,
                detail: "视频生成尚未通过真实协议验证，已隔离（未自动发起可能计费的请求）"
            ).quarantineCause,
            .nativeVerificationRequired
        )
        XCTAssertEqual(
            ModelHealthRecord(
                providerID: providerID,
                model: "network",
                status: .unavailable,
                detail: "网络错误（-1009）"
            ).quarantineCause,
            .networkFailure
        )
        XCTAssertNil(
            ModelHealthRecord(
                providerID: providerID,
                model: "ready",
                status: .available,
                statusCode: 200
            ).quarantineCause
        )
    }
}
