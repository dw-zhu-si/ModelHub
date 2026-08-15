import Foundation
import XCTest
@testable import ModelHubCore

final class ModelHealthTests: XCTestCase {
    func testMiniMaxExactNativeModelIDsMapToDedicatedProtocols() {
        let provider = ProviderConfig(
            name: "MiniMax 中国站",
            kind: .minimaxChina,
            baseURL: "https://api.minimaxi.com/v1"
        )

        XCTAssertEqual(ModelProbePolicy.nativeProtocol(provider: provider, model: "MiniMax-Hailuo-2.3"), .videoGeneration)
        XCTAssertEqual(ModelProbePolicy.nativeProtocol(provider: provider, model: "music-3.0"), .musicGeneration)
        XCTAssertEqual(
            ModelProbePolicy.nativeProtocol(provider: provider, model: "MiniMax Music 3.0"),
            .musicGeneration
        )
        XCTAssertEqual(ModelProbePolicy.nativeProtocol(provider: provider, model: "image-01-live"), .imageGeneration)
        XCTAssertEqual(ModelProbePolicy.nativeProtocol(provider: provider, model: "speech-2.8-hd"), .speech)
        XCTAssertEqual(
            ModelProbePolicy.nativeProtocol(provider: provider, model: "minimax-hailuo-2.3"),
            .providerNative
        )
        XCTAssertEqual(
            ModelProbePolicy.disposition(
                provider: provider,
                model: "minimax-hailuo-2.3",
                hasAPIKey: true
            ),
            .readyForNativeProtocol(.providerNative)
        )
        XCTAssertTrue(provider.kind.isOfficialProvider(for: "MiniMax-Hailuo-2.3"))
        XCTAssertTrue(provider.kind.isOfficialProvider(for: "music-3.0"))
    }

    func testMiniMaxBusinessStatusOverridesHTTP200() {
        let provider = ProviderConfig(
            name: "MiniMax 中国站",
            kind: .minimaxChina,
            baseURL: "https://api.minimaxi.com/v1"
        )
        let authenticationFailure = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"base_resp":{"status_code":1004,"status_msg":"invalid api key"}}"#.utf8)
        )
        let rateLimited = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"base_resp":{"status_code":1002,"status_msg":"rate limit"}}"#.utf8)
        )

        let auth = ModelProbePolicy.nativeResponseAssessment(
            authenticationFailure,
            provider: provider,
            operation: .imageGeneration
        )
        XCTAssertFalse(auth.isAccepted)
        XCTAssertEqual(auth.availability, .configurationRequired)
        XCTAssertEqual(auth.gatewayStatusCode, 401)

        let limited = ModelProbePolicy.nativeResponseAssessment(
            rateLimited,
            provider: provider,
            operation: .musicGeneration
        )
        XCTAssertFalse(limited.isAccepted)
        XCTAssertEqual(limited.availability, .unavailable)
        XCTAssertEqual(limited.gatewayStatusCode, 429)
    }

    func testMiniMaxChatBusinessStatusIsNotMistakenForTransportSuccess() {
        let provider = ProviderConfig(
            name: "MiniMax 中国站",
            kind: .minimaxChina,
            baseURL: "https://api.minimaxi.com/v1"
        )
        let response = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"choices":[],"base_resp":{"status_code":2049}}"#.utf8)
        )

        let assessment = ModelProbePolicy.providerResponseAssessment(
            response,
            provider: provider
        )
        XCTAssertFalse(assessment.isAccepted)
        XCTAssertEqual(assessment.availability, .configurationRequired)
        XCTAssertEqual(assessment.gatewayStatusCode, 401)
    }

    func testDocumentedQianwenImage404IsConfigurationIssueNotUnsupportedModel() {
        let provider = ProviderConfig(
            name: "千问AI平台（按量付费）",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        let response = ProviderResponse(
            statusCode: 404,
            headers: [:],
            body: Data()
        )

        let assessment = ModelProbePolicy.nativeResponseAssessment(
            response,
            provider: provider,
            operation: .imageGeneration,
            model: "qwen-image-3.0-pro"
        )
        let record = ModelHealthRecord(
            providerID: provider.id,
            model: "qwen-image-3.0-pro",
            status: assessment.availability,
            statusCode: assessment.gatewayStatusCode,
            detail: assessment.detail
        )

        XCTAssertFalse(assessment.isAccepted)
        XCTAssertEqual(assessment.availability, .configurationRequired)
        XCTAssertEqual(assessment.gatewayStatusCode, 404)
        XCTAssertTrue(assessment.detail.contains("官方能力目录确认支持"))
        XCTAssertEqual(record.quarantineCause, .modelAccessNotConfigured)
    }

    func testMiniMaxSpeechProbeUsesOfficialBuiltInVoice() throws {
        let payload = try XCTUnwrap(
            ModelProbePolicy.nativeProbePayload(
                for: .speech,
                model: "speech-2.8-hd"
            )
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload.body) as? [String: Any]
        )
        XCTAssertEqual(body["voice"] as? String, "male-qn-qingse")
    }

    func testMiniMaxGenerationBusinessStatesAreDistinguished() {
        let provider = ProviderConfig(
            name: "MiniMax 国际站",
            kind: .minimax,
            baseURL: "https://api.minimax.io/v1"
        )
        let videoPending = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"task_id":"task_1","status":"Queueing","base_resp":{"status_code":0}}"#.utf8)
        )
        let videoFailed = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"task_id":"task_1","status":"Fail","base_resp":{"status_code":0}}"#.utf8)
        )
        let musicComplete = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"data":{"status":2,"audio":"https://example.com/audio.mp3"},"base_resp":{"status_code":0}}"#.utf8)
        )

        let pending = ModelProbePolicy.nativeResponseAssessment(
            videoPending,
            provider: provider,
            operation: .videoTask
        )
        XCTAssertTrue(pending.isAccepted)
        XCTAssertTrue(pending.isPending)
        XCTAssertEqual(pending.availability, .available)

        let failed = ModelProbePolicy.nativeResponseAssessment(
            videoFailed,
            provider: provider,
            operation: .videoTask
        )
        XCTAssertFalse(failed.isAccepted)
        XCTAssertEqual(failed.availability, .unavailable)
        XCTAssertEqual(failed.gatewayStatusCode, 502)

        let complete = ModelProbePolicy.nativeResponseAssessment(
            musicComplete,
            provider: provider,
            operation: .musicGeneration
        )
        XCTAssertTrue(complete.isAccepted)
        XCTAssertFalse(complete.isPending)
        XCTAssertEqual(complete.availability, .available)
    }

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
        XCTAssertEqual(ProviderKind.minimax.defaultBaseURL, "https://api.minimax.io/v1")
        XCTAssertEqual(ProviderKind.unifiedCompatible.defaultBaseURL, "")
        XCTAssertTrue(ProviderKind.openRouter.usesUnifiedProtocol)
        XCTAssertTrue(ProviderKind.volcengine.needsAPIKey)
    }

    func testBailianEditionsAreDistinctAndValidateOfficialEndpointFamilies() throws {
        XCTAssertEqual(ProviderKind.qwen.displayName, "千问AI平台（按量付费）")
        XCTAssertEqual(ProviderKind.qwenPersonal.displayName, "千问AI平台 Token Plan 个人版")
        XCTAssertEqual(ProviderKind.qwenBusiness.displayName, "千问AI平台（业务空间/按量付费）")
        XCTAssertEqual(ProviderKind.qwenEnterprise.displayName, "千问AI平台 Token Plan 团队版")
        XCTAssertEqual(
            ProviderKind.qwenPersonal.recommendedBaseURL,
            "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertEqual(
            ProviderKind.qwenEnterprise.recommendedBaseURL,
            ProviderKind.qwenPersonal.recommendedBaseURL
        )
        XCTAssertEqual(
            ProviderKind.qwenEnterprise.recommendedChatEndpoint,
            "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
        )
        XCTAssertEqual(
            ProviderKind.qwenBusiness.recommendedBaseURL,
            "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertNotNil(
            BailianEndpointPolicy.validationMessage(
                for: ProviderConfig(
                    name: "个人版",
                    kind: .qwenPersonal,
                    baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                    models: ["qwen-plus"]
                )
            )
        )
        XCTAssertNotNil(
            BailianEndpointPolicy.validationMessage(
                for: ProviderConfig(
                    name: "旧百炼",
                    kind: .qwen,
                    baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
                    models: ["qwen-plus"]
                )
            )
        )

        let personal = ProviderConfig(
            name: "个人版",
            kind: .qwenPersonal,
            baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
            models: ["qwen-plus"]
        )
        XCTAssertNil(BailianEndpointPolicy.validationMessage(for: personal))
        XCTAssertEqual(
            ProviderBaseURLMigration.completedLegacyURL(for: personal),
            "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
        )

        let encoded = try JSONEncoder().encode(personal)
        XCTAssertEqual(try JSONDecoder().decode(ProviderConfig.self, from: encoded).kind, .qwenPersonal)

        let regionalPayAsYouGo = ProviderConfig(
            name: "新加坡业务空间",
            kind: .qwen,
            baseURL: "https://workspace.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
            models: ["qwen-plus"]
        )
        XCTAssertNil(BailianEndpointPolicy.validationMessage(for: regionalPayAsYouGo))

        let businessPayAsYouGo = ProviderConfig(
            name: "企业业务空间",
            kind: .qwenBusiness,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            models: ["qwen-plus"]
        )
        XCTAssertNil(BailianEndpointPolicy.validationMessage(for: businessPayAsYouGo))
    }

    func testQianwenProviderMigrationRenamesLegacyProvidersWithoutChangingBillingFamily() {
        let payAsYouGo = ProviderConfig(
            name: "阿里云百炼个人按量版",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        let business = ProviderConfig(
            name: "阿里云百炼企业版(团队版)",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )

        let migratedPayAsYouGo = QianwenProviderMigration.migratedProvider(payAsYouGo)
        let migratedBusiness = QianwenProviderMigration.migratedProvider(business)

        XCTAssertEqual(migratedPayAsYouGo?.kind, .qwen)
        XCTAssertEqual(migratedPayAsYouGo?.name, "千问AI平台（按量付费）")
        XCTAssertEqual(migratedBusiness?.kind, .qwenBusiness)
        XCTAssertEqual(migratedBusiness?.name, "千问AI平台（业务空间/按量付费）")
    }

    func testQuarantineCauseUsesUpstreamBusinessCodeBeforeProxyHTTPStatus() {
        let providerID = UUID()
        XCTAssertEqual(
            ModelHealthRecord(
                providerID: providerID,
                model: "removed-model",
                status: .unavailable,
                statusCode: 429,
                detail: "HTTP 429 · code=model_not_found · message=model removed"
            ).quarantineCause,
            .endpointOrModelNotFound
        )
        XCTAssertEqual(
            ModelHealthRecord(
                providerID: providerID,
                model: "restricted-model",
                status: .unavailable,
                statusCode: 429,
                detail: "HTTP 429 · code=access_denied · message=permission denied"
            ).quarantineCause,
            .insufficientPermission
        )
        XCTAssertEqual(
            ModelHealthRecord(
                providerID: providerID,
                model: "busy-model",
                status: .unavailable,
                statusCode: 429,
                detail: "HTTP 429 · code=get_channel_failed · message=no channel"
            ).quarantineCause,
            .upstreamFailure
        )
    }

    func testBailianTokenPlanRejectsMismatchedExplicitChatEndpoint() {
        let provider = ProviderConfig(
            name: "企业版",
            kind: .qwenEnterprise,
            baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
            models: ["qwen-plus"],
            endpointURLs: [
                ProviderEndpointRecord.key(for: .chat, model: "qwen-plus"):
                    "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
            ]
        )
        XCTAssertNotNil(BailianEndpointPolicy.validationMessage(for: provider))
    }

    func testBailianCredentialFamiliesFailClosedBeforeNetworkUse() {
        XCTAssertNil(
            ProviderCredentialPolicy.validationMessage(
                for: .qwenEnterprise,
                apiKey: "sk-sp-team-token"
            )
        )
        XCTAssertNotNil(
            ProviderCredentialPolicy.validationMessage(
                for: .qwenEnterprise,
                apiKey: "sk-ws-pay-as-you-go-token"
            )
        )
        XCTAssertNotNil(
            ProviderCredentialPolicy.validationMessage(
                for: .qwenPersonal,
                apiKey: "sk-pay-as-you-go-token"
            )
        )
        XCTAssertNotNil(
            ProviderCredentialPolicy.validationMessage(
                for: .qwen,
                apiKey: "sk-sp-token-plan-token"
            )
        )
        XCTAssertNil(
            ProviderCredentialPolicy.validationMessage(
                for: .qwen,
                apiKey: "sk-ws-pay-as-you-go-token"
            )
        )
        XCTAssertNil(
            ProviderCredentialPolicy.validationMessage(
                for: .qwenBusiness,
                apiKey: "sk-ws-business-workspace-token"
            )
        )
        XCTAssertNotNil(
            ProviderCredentialPolicy.validationMessage(
                for: .qwenBusiness,
                apiKey: "sk-sp-token-plan-token"
            )
        )
        XCTAssertTrue(
            ProviderCredentialPolicy.canReuseCredential(
                from: .qwenEnterprise,
                to: .qwenBusiness,
                apiKey: "sk-ws-business-workspace-token"
            )
        )
        XCTAssertFalse(
            ProviderCredentialPolicy.canReuseCredential(
                from: .qwenEnterprise,
                to: .qwenBusiness,
                apiKey: "sk-sp-token-plan-token"
            )
        )
        XCTAssertFalse(
            ProviderCredentialPolicy.canReuseCredential(
                from: .qwenPersonal,
                to: .qwenEnterprise,
                apiKey: "sk-sp-token-plan-token"
            )
        )
    }

    func testMiniMaxRegionsAreDistinct() {
        XCTAssertEqual(ProviderKind.minimaxChina.displayName, "MiniMax 中国站")
        XCTAssertEqual(ProviderKind.minimax.displayName, "MiniMax 国际站")
        XCTAssertEqual(ProviderKind.minimaxChina.defaultBaseURL, "https://api.minimaxi.com/v1")
        XCTAssertEqual(ProviderKind.minimax.defaultBaseURL, "https://api.minimax.io/v1")
        XCTAssertTrue(ProviderKind.minimaxChina.isOfficialProvider(for: "MiniMax-M2.7"))
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

    func testMusicGenerationHasDedicatedCapabilityProtocolAndMinimalProbe() throws {
        let provider = ProviderConfig(
            name: "Music Provider",
            kind: .unifiedCompatible,
            baseURL: "https://music.example.com/v1/music/generations",
            models: ["musicgen-large"]
        )

        XCTAssertEqual(
            ModelProbePolicy.nativeProtocol(provider: provider, model: "musicgen-large"),
            .musicGeneration
        )
        XCTAssertEqual(
            ModelProbePolicy.nativeOperation(for: .musicGeneration),
            .musicGeneration
        )
        XCTAssertTrue(
            ModelCategory.infer(
                model: "custom-audio-model",
                capabilities: [.musicGeneration]
            ).contains(.music)
        )

        let payload = try XCTUnwrap(
            ModelProbePolicy.nativeProbePayload(
                for: .musicGeneration,
                model: "musicgen-large"
            )
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload.body) as? [String: Any]
        )
        XCTAssertEqual(json["prompt"] as? String, "ModelHub connection test")
        XCTAssertEqual(json["duration"] as? Int, 5)
        XCTAssertEqual(json["instrumental"] as? Bool, true)
    }

    func testVendorMusicActionUsesUnifiedProtocolOnlyWithExplicitMusicEndpoint() {
        var provider = ProviderConfig(
            name: "云雾 API",
            kind: .unifiedCompatible,
            baseURL: "https://yunwu.ai/v1",
            models: ["suno_music_open"]
        )
        XCTAssertEqual(
            ModelProbePolicy.nativeProtocol(provider: provider, model: "suno_music_open"),
            .providerNative
        )

        provider.endpointURLs[
            ProviderEndpointRecord.key(for: .musicGeneration, model: "suno_music_open")
        ] = "https://yunwu.ai/v1/music/generations"
        XCTAssertEqual(
            ModelProbePolicy.nativeProtocol(provider: provider, model: "suno_music_open"),
            .musicGeneration
        )
    }

    func testNativeGatewayRoutesMusicCreationAndTaskWithoutConfusingVideoPaths() {
        XCTAssertEqual(
            NativeGatewayRoute.match(method: "POST", path: "/v1/music/generations"),
            NativeGatewayMatch(operation: .musicGeneration)
        )
        XCTAssertEqual(
            NativeGatewayRoute.match(method: "GET", path: "/v1/music/task_123"),
            NativeGatewayMatch(operation: .musicTask, taskID: "task_123")
        )
        XCTAssertEqual(
            NativeGatewayRoute.match(method: "GET", path: "/v1/tasks/task_456"),
            NativeGatewayMatch(operation: .videoTask, taskID: "task_456")
        )
        XCTAssertNil(NativeGatewayRoute.match(method: "GET", path: "/v1/music/generations"))
        XCTAssertNil(NativeGatewayRoute.match(method: "POST", path: "/v1/music/task_123"))
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

    func testQianwenHappyhorseVariantsAreVideoModelsInsteadOfChatModels() {
        let provider = ProviderConfig(
            name: "千问AI平台（业务空间/按量付费）",
            kind: .qwenBusiness,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )

        for model in [
            "happyhorse-1.1-t2v",
            "happyhorse-1.1-i2v",
            "happyhorse-1.1-r2v"
        ] {
            XCTAssertEqual(
                ModelProbePolicy.nativeProtocol(provider: provider, model: model),
                .videoGeneration
            )
        }
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

    func testMigrationReclassifiesAccessDeniedBusinessCodeAsConfigurationRequired() throws {
        let provider = ProviderConfig(
            name: "千问AI平台（按量付费）",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            models: ["qwen3.5-9b"]
        )
        let original = ModelHealthRecord(
            providerID: provider.id,
            model: "qwen3.5-9b",
            status: .unavailable,
            statusCode: 400,
            detail: "HTTP 400 · code=access_denied · message=Access denied"
        )

        let normalized = ModelHealthMigration.normalize(
            records: [original],
            providers: [provider]
        )

        XCTAssertEqual(try XCTUnwrap(normalized.first).status, .configurationRequired)
    }

    func testMigrationPreservesSpecificHTTP403ConfigurationReason() throws {
        let provider = ProviderConfig(
            name: "受限供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["restricted-model"]
        )
        let original = ModelHealthRecord(
            providerID: provider.id,
            model: "restricted-model",
            status: .configurationRequired,
            latencyMilliseconds: 321,
            statusCode: 403,
            detail: "HTTP 403 · code=access_denied · message=permission denied"
        )

        let normalized = ModelHealthMigration.normalize(
            records: [original],
            providers: [provider]
        )

        XCTAssertEqual(try XCTUnwrap(normalized.first), original)
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

    func testRetryPolicyRetriesTransientTLSHandshakeFailureWithoutRetryingUntrustedCertificate() {
        XCTAssertTrue(
            ModelProbeRetryPolicy.shouldRetryNetworkError(
                URLError(.secureConnectionFailed),
                attempt: 1
            )
        )
        XCTAssertFalse(
            ModelProbeRetryPolicy.shouldRetryNetworkError(
                URLError(.secureConnectionFailed),
                attempt: ModelProbeRetryPolicy.maximumAttempts
            )
        )
        XCTAssertFalse(
            ModelProbeRetryPolicy.shouldRetryNetworkError(
                URLError(.serverCertificateUntrusted),
                attempt: 1
            )
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

    func testTransientHealthRecoveryDemotesExplicitTransportFailureToUnknown() throws {
        let providerID = UUID()
        let recoveredAt = Date(timeIntervalSince1970: 1_770_000_000)
        let record = ModelHealthRecord(
            providerID: providerID,
            model: "stable-model",
            status: .unavailable,
            checkedAt: recoveredAt.addingTimeInterval(-60),
            latencyMilliseconds: 3_000,
            detail: "网络错误（-1200）"
        )

        let result = ModelHealthRecoveryPolicy.recovering(
            records: [record],
            providerID: providerID,
            at: recoveredAt
        )
        let recovered = try XCTUnwrap(result.records.first)

        XCTAssertEqual(result.recoveredCount, 1)
        XCTAssertEqual(recovered.status, .unknown)
        XCTAssertEqual(recovered.checkedAt, recoveredAt)
        XCTAssertNil(recovered.latencyMilliseconds)
        XCTAssertNil(recovered.statusCode)
        XCTAssertTrue(recovered.detail.contains("-1200"))
        XCTAssertTrue(recovered.status.isQuarantined)
    }

    func testTransientHealthRecoveryRejectsBusinessAndAmbiguousNetworkFailures() {
        let providerID = UUID()
        let records = [
            ModelHealthRecord(
                providerID: providerID,
                model: "permission-denied",
                status: .unavailable,
                statusCode: 403,
                detail: "HTTP 403"
            ),
            ModelHealthRecord(
                providerID: providerID,
                model: "ambiguous-network",
                status: .unavailable,
                detail: "网络连接失败"
            ),
            ModelHealthRecord(
                providerID: providerID,
                model: "still-available",
                status: .available,
                detail: "网络错误（-1200）"
            )
        ]

        let result = ModelHealthRecoveryPolicy.recovering(records: records)

        XCTAssertEqual(result.recoveredCount, 0)
        XCTAssertEqual(result.records, records)
    }

    func testTransientHealthRecoveryScopesProviderAndPreservesRecordOrder() {
        let firstProvider = UUID()
        let secondProvider = UUID()
        let records = [
            ModelHealthRecord(
                providerID: firstProvider,
                model: "first",
                status: .unavailable,
                detail: "网络错误（-1005）"
            ),
            ModelHealthRecord(
                providerID: secondProvider,
                model: "second",
                status: .unavailable,
                detail: "网络错误（-1200）"
            )
        ]

        let result = ModelHealthRecoveryPolicy.recovering(
            records: records,
            providerID: firstProvider
        )

        XCTAssertEqual(result.recoveredCount, 1)
        XCTAssertEqual(result.records.map(\.model), ["first", "second"])
        XCTAssertEqual(result.records[0].status, .unknown)
        XCTAssertEqual(result.records[1], records[1])
    }

    func testTransientHealthRecoveryRecognizesStandardNSURLErrorDescription() {
        let record = ModelHealthRecord(
            providerID: UUID(),
            model: "tls-model",
            status: .unavailable,
            detail: "Error Domain=NSURLErrorDomain Code=-1200"
        )

        XCTAssertEqual(ModelHealthRecoveryPolicy.recoverableErrorCode(in: record), -1200)
    }

    func testRecoveredPendingVerificationSurvivesRestartMigration() throws {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["chat-model", "image-model"]
        )
        let recoveredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let recovered = ModelHealthRecoveryPolicy.recovering(
            records: [
                ModelHealthRecord(
                    providerID: provider.id,
                    model: "chat-model",
                    status: .unavailable,
                    detail: "网络错误（-1200）"
                ),
                ModelHealthRecord(
                    providerID: provider.id,
                    model: "image-model",
                    status: .unavailable,
                    detail: "网络错误（-1005）"
                )
            ],
            providerID: provider.id,
            at: recoveredAt
        )

        let normalized = ModelHealthMigration.normalize(
            records: recovered.records,
            providers: [provider]
        )

        XCTAssertEqual(normalized.map(\.status), [.unknown, .unknown])
        XCTAssertTrue(normalized.allSatisfy(
            ModelHealthRecoveryPolicy.isRecoveredPendingVerification
        ))
    }

    func testDeferredNativePendingVerificationSurvivesRestartMigration() throws {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["image-model"]
        )
        let pending = ModelHealthRecord(
            providerID: provider.id,
            model: "image-model",
            status: .unknown,
            detail: "图像生成尚未通过真实协议验证，已隔离（未自动发起可能计费的请求）"
        )

        let normalized = ModelHealthMigration.normalize(
            records: [pending],
            providers: [provider]
        )

        XCTAssertEqual(normalized, [pending])
        XCTAssertTrue(
            ModelHealthRecoveryPolicy.isDeferredNativePendingVerification(pending)
        )
    }

    func testRecordedRecoveryRepairsEarlyBuildRestartWithoutBroadeningScope() {
        let providerID = UUID()
        let otherProviderID = UUID()
        let recoveredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let degradedRecords = [
            ModelHealthRecord(
                providerID: providerID,
                model: "recovered-a",
                status: .unavailable,
                checkedAt: recoveredAt,
                detail: "尚未完成在线验证，已隔离"
            ),
            ModelHealthRecord(
                providerID: providerID,
                model: "not-in-count",
                status: .unavailable,
                checkedAt: recoveredAt,
                detail: "尚未完成在线验证，已隔离"
            ),
            ModelHealthRecord(
                providerID: otherProviderID,
                model: "wrong-provider",
                status: .unavailable,
                checkedAt: recoveredAt,
                detail: "尚未完成在线验证，已隔离"
            )
        ]
        let activity = ModelHealthActivity(
            kind: .transientRecovery,
            startedAt: recoveredAt,
            completedAt: recoveredAt,
            providerID: providerID,
            total: 1,
            completed: 1,
            recoveredToUnknown: 1
        )

        let restored = ModelHealthRecoveryPolicy.restoringRecordedRecoveries(
            records: degradedRecords,
            activities: [activity]
        )

        XCTAssertEqual(restored.map(\.status), [.unknown, .unavailable, .unavailable])
        XCTAssertTrue(ModelHealthRecoveryPolicy.isRecoveredPendingVerification(restored[0]))
    }

    func testModelHealthActivityHistoryIsBoundedNewestFirstAndLegacyConfigDefaultsEmpty() throws {
        let providerID = UUID()
        let history = (0..<ModelHealthActivityStore.maximumCount).map { index in
            ModelHealthActivity(
                id: UUID(),
                kind: .probe,
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                completedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                providerID: providerID,
                total: 1,
                completed: 1,
                available: 1
            )
        }
        let newest = ModelHealthActivity(
            id: UUID(),
            kind: .transientRecovery,
            startedAt: Date(timeIntervalSince1970: 10_000),
            completedAt: Date(timeIntervalSince1970: 10_001),
            providerID: providerID,
            total: 3,
            completed: 3,
            recoveredToUnknown: 3
        )

        let bounded = ModelHealthActivityStore.appending(newest, to: history)
        let legacy = Data(#"{"providers":[],"routes":[],"server":{"port":11435}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: legacy)

        XCTAssertEqual(bounded.count, ModelHealthActivityStore.maximumCount)
        XCTAssertEqual(bounded.first?.id, newest.id)
        XCTAssertFalse(bounded.contains { $0.id == history[0].id })
        XCTAssertTrue(decoded.modelHealthActivities.isEmpty)
    }

    func testModelHealthActivityNormalizationSanitizesDecodedUntrustedValues() throws {
        let providerIDs = (0..<40).map { _ in UUID().uuidString }
        let raw: [String: Any] = [
            "id": UUID().uuidString,
            "kind": "probe",
            "startedAt": 100.0,
            "completedAt": 50.0,
            "total": -1,
            "completed": -2,
            "available": -3,
            "unavailable": -4,
            "skipped": -5,
            "preservedAvailable": -6,
            "transientFailures": -7,
            "retryAttempts": -8,
            "circuitOpenedProviderIDs": providerIDs,
            "circuitSkipped": -9,
            "recoveredToUnknown": -10,
            "cancelled": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let decoded = try JSONDecoder().decode(ModelHealthActivity.self, from: data)

        let sanitized = try XCTUnwrap(ModelHealthActivityStore.normalized([decoded]).first)

        XCTAssertEqual(sanitized.completedAt, sanitized.startedAt)
        XCTAssertEqual(sanitized.total, 0)
        XCTAssertEqual(sanitized.completed, 0)
        XCTAssertEqual(sanitized.available, 0)
        XCTAssertEqual(sanitized.unavailable, 0)
        XCTAssertEqual(sanitized.skipped, 0)
        XCTAssertEqual(sanitized.preservedAvailable, 0)
        XCTAssertEqual(sanitized.transientFailures, 0)
        XCTAssertEqual(sanitized.retryAttempts, 0)
        XCTAssertEqual(sanitized.circuitOpenedProviderIDs.count, 32)
        XCTAssertEqual(sanitized.circuitSkipped, 0)
        XCTAssertEqual(sanitized.recoveredToUnknown, 0)
    }

    func testQianwenNonStreamingProbeDisablesHybridThinkingWithoutChangingThinkingOnlyModels() throws {
        let provider = ProviderConfig(
            name: "千问AI平台（按量付费）",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )

        let hybridBody = try XCTUnwrap(
            ModelProbePolicy.chatProbeBody(provider: provider, model: "qwen3-32b")
        )
        let hybridJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: hybridBody) as? [String: Any]
        )
        XCTAssertEqual(hybridJSON["enable_thinking"] as? Bool, false)

        let thinkingOnlyBody = try XCTUnwrap(
            ModelProbePolicy.chatProbeBody(
                provider: provider,
                model: "qwen3-next-80b-a3b-thinking"
            )
        )
        let thinkingOnlyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: thinkingOnlyBody) as? [String: Any]
        )
        XCTAssertNil(thinkingOnlyJSON["enable_thinking"])
    }

    func testGPT54ProProbeUsesProviderMinimumOutputTokenCount() throws {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .unifiedCompatible,
            baseURL: "https://example.invalid/v1"
        )

        let proBody = try XCTUnwrap(
            ModelProbePolicy.chatProbeBody(provider: provider, model: "gpt-5.4-pro")
        )
        let datedProBody = try XCTUnwrap(
            ModelProbePolicy.chatProbeBody(
                provider: provider,
                model: "gpt-5.4-pro-2026-03-05"
            )
        )
        let regularBody = try XCTUnwrap(
            ModelProbePolicy.chatProbeBody(provider: provider, model: "gpt-5.4")
        )
        let proJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: proBody) as? [String: Any]
        )
        let datedProJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: datedProBody) as? [String: Any]
        )
        let regularJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: regularBody) as? [String: Any]
        )

        XCTAssertEqual(proJSON["max_tokens"] as? Int, 16)
        XCTAssertEqual(datedProJSON["max_tokens"] as? Int, 16)
        XCTAssertEqual(regularJSON["max_tokens"] as? Int, 1)
    }

    func testHTTP429WrappedParameterErrorIsNotRetriedOrReportedAsQuota() {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .unifiedCompatible,
            baseURL: "https://example.invalid/v1"
        )
        let response = ProviderResponse(
            statusCode: 429,
            headers: [:],
            body: Data(
                #"{"code":"integer_below_min_value","message":"Expected a value >= 16"}"#.utf8
            )
        )

        let assessment = ModelProbePolicy.providerResponseAssessment(
            response,
            provider: provider
        )
        let record = ModelHealthRecord(
            providerID: provider.id,
            model: "gpt-5.4-pro",
            status: assessment.availability,
            statusCode: assessment.gatewayStatusCode,
            detail: assessment.detail
        )

        XCTAssertEqual(assessment.availability, .unavailable)
        XCTAssertEqual(assessment.gatewayStatusCode, 400)
        XCTAssertEqual(record.quarantineCause, .invalidRequest)
        XCTAssertEqual(
            ModelProbeRetryPolicy.decision(
                statusCode: assessment.gatewayStatusCode,
                headers: response.headers,
                attempt: 1
            ),
            .stop
        )
    }

    func testBusinessAccessDeniedAtHTTP400RequiresConfigurationAction() {
        let response = ProviderResponse(
            statusCode: 400,
            headers: [:],
            body: Data(#"{"code":"access_denied","message":"Access denied"}"#.utf8)
        )
        let provider = ProviderConfig(
            name: "千问AI平台（按量付费）",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )

        XCTAssertEqual(
            ModelProbePolicy.providerResponseAssessment(response, provider: provider).availability,
            .configurationRequired
        )
    }

    func testQianwenVisionEmbeddingProbeUsesMultimodalPayload() throws {
        let payload = try XCTUnwrap(
            ModelProbePolicy.nativeProbePayload(
                for: .embeddings,
                model: "qwen3-vl-embedding-2b"
            )
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload.body) as? [String: Any]
        )
        let input = try XCTUnwrap(body["input"] as? [String: Any])
        let contents = try XCTUnwrap(input["contents"] as? [[String: Any]])

        XCTAssertEqual(contents.first?["text"] as? String, "ModelHub connection test")
    }
}
