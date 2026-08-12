import XCTest
@testable import ModelHubCore

final class ProviderClientTests: XCTestCase {
    func testBailianBusinessWorkspaceUsesPayAsYouGoEndpointAndCredential() throws {
        let preset = try XCTUnwrap(
            ProviderConnectionPresets.preset(for: .qwenBusiness)
        )
        let provider = preset.applying(
            to: ProviderConfig(
                name: "阿里云百炼企业版（业务空间/按量付费）",
                kind: .qwenBusiness,
                baseURL: ""
            ),
            mode: .replaceURLs
        )

        let request = try ProviderClient().chatRequest(
            rawBody: Data(#"{"messages":[{"role":"user","content":"ping"}]}"#.utf8),
            targetModel: "qwen-plus",
            provider: provider,
            apiKey: "sk-ws-business-workspace-token"
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        )
    }

    func testBailianTokenPlanCredentialMismatchIsRejectedForInferenceRequests() throws {
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
            try ProviderClient().chatRequest(
                rawBody: Data(#"{"messages":[{"role":"user","content":"ping"}]}"#.utf8),
                targetModel: "qwen3.5-plus",
                provider: provider,
                apiKey: "sk-ws-pay-as-you-go-token"
            )
        ) { error in
            guard case .credentialMismatch(let message) = error as? ProviderClientError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("sk-sp-"))
        }
    }

    func testBailianPersonalAndEnterpriseUseExactTokenPlanChatEndpoint() throws {
        let body = Data(#"{"model":"ignored","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        for kind in [ProviderKind.qwenPersonal, .qwenEnterprise] {
            let endpoint = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
            let provider = ProviderConfig(
                name: kind.displayName,
                kind: kind,
                baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
                models: ["qwen-plus"],
                endpointURLs: [ProviderEndpointRecord.key(for: .chat): endpoint]
            )
            let request = try ProviderClient().chatRequest(
                rawBody: body,
                targetModel: "qwen-plus",
                provider: provider,
                apiKey: "sk-sp-edition-specific-secret"
            )
            XCTAssertEqual(request.url?.absoluteString, endpoint)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer sk-sp-edition-specific-secret"
            )
        }
    }

    func testCompatibleEndpointUsesConfiguredBaseURLWithoutCompletion() throws {
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1"
        )
        let endpoint = try ProviderClient().endpoint(for: provider, model: "model")
        XCTAssertEqual(endpoint.absoluteString, "https://example.com/v1")
    }

    func testVersionedVendorEndpointsUseConfiguredBaseURLWithoutCompletion() throws {
        let volcengine = ProviderConfig(
            name: "火山引擎 / 豆包",
            kind: .volcengine,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3"
        )
        let qianfan = ProviderConfig(
            name: "百度千帆",
            kind: .baiduQianfan,
            baseURL: "https://qianfan.baidubce.com/v2"
        )

        XCTAssertEqual(
            try ProviderClient().endpoint(for: volcengine, model: "doubao-seed-1-6").absoluteString,
            "https://ark.cn-beijing.volces.com/api/v3"
        )
        XCTAssertEqual(
            try ProviderClient().endpoint(for: qianfan, model: "ernie-4.5-turbo").absoluteString,
            "https://qianfan.baidubce.com/v2"
        )
    }

    func testResponsesRequestPreservesToolsAndMultimodalInput() throws {
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1"
        )
        let body = Data(#"{"model":"route","input":[{"role":"user","content":[{"type":"input_text","text":"hi"},{"type":"input_image","image_url":"data:image/png;base64,AA=="}]}],"tools":[{"type":"function","name":"weather","parameters":{"type":"object"}}]}"#.utf8)
        let request = try ProviderClient().responsesRequest(
            rawBody: body,
            targetModel: "gpt-compatible",
            provider: provider,
            apiKey: "key"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "gpt-compatible")
        XCTAssertNotNil(object["input"])
        XCTAssertNotNil(object["tools"])
    }

    func testChatRequestPreservesToolsAndMultimodalMessages() throws {
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1"
        )
        let body = Data(#"{"model":"route","messages":[{"role":"user","content":[{"type":"text","text":"hi"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]}],"tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object"}}}],"stream":true}"#.utf8)
        let request = try ProviderClient().chatRequest(
            rawBody: body,
            targetModel: "vision-tools",
            provider: provider,
            apiKey: "key"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "vision-tools")
        XCTAssertNotNil(object["messages"])
        XCTAssertNotNil(object["tools"])
        XCTAssertEqual(object["stream"] as? Bool, true)
    }

    func testAnthropicChatRequestConvertsToolsImagesAndToolResults() throws {
        let provider = ProviderConfig(
            name: "Claude",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com/custom/messages"
        )
        let body = Data(#"{"model":"route","messages":[{"role":"system","content":"safe"},{"role":"user","content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]},{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"15 C"}],"tools":[{"type":"function","function":{"name":"weather","description":"Weather","parameters":{"type":"object"}}}],"stream":true}"#.utf8)

        let request = try ProviderClient().chatRequest(
            rawBody: body,
            targetModel: "claude-test",
            provider: provider,
            apiKey: "secret"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/custom/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "claude-test")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertNotNil(object["tools"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let userBlocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(userBlocks[1]["type"] as? String, "image")
        let assistantBlocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.last?["type"] as? String, "tool_use")
        let resultBlocks = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(resultBlocks[0]["type"] as? String, "tool_result")
    }

    func testGeminiChatRequestConvertsToolsMultimodalAndUsesHeaderKey() throws {
        let provider = ProviderConfig(
            name: "Gemini",
            kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:streamGenerateContent"
        )
        let body = Data(#"{"model":"route","messages":[{"role":"user","content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]},{"role":"assistant","tool_calls":[{"id":"call_1","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"{\"temperature\":15}"}],"tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object"}}}],"stream":true}"#.utf8)

        let request = try ProviderClient().chatRequest(
            rawBody: body,
            targetModel: "gemini-test",
            provider: provider,
            apiKey: "secret"
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:streamGenerateContent?alt=sse"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret")
        XCTAssertFalse(request.url?.absoluteString.contains("secret") == true)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertNotNil(object["tools"])
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let firstParts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertNotNil(firstParts[1]["inline_data"])
        let assistantParts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
        XCTAssertNotNil(assistantParts[0]["functionCall"])
        let resultParts = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
        XCTAssertNotNil(resultParts[0]["functionResponse"])
    }

    func testNativeResponseNormalizationPreservesToolCalls() throws {
        let anthropic = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"id":"msg_1","model":"claude","stop_reason":"tool_use","content":[{"type":"text","text":"Checking"},{"type":"tool_use","id":"toolu_1","name":"weather","input":{"city":"Paris"}}],"usage":{"input_tokens":10,"output_tokens":4}}"#.utf8)
        )
        let normalizedAnthropic = try UnifiedProtocolBridge.normalizeAnthropic(anthropic)
        let anthropicObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalizedAnthropic.body) as? [String: Any]
        )
        let anthropicChoices = try XCTUnwrap(anthropicObject["choices"] as? [[String: Any]])
        XCTAssertEqual(anthropicChoices[0]["finish_reason"] as? String, "tool_calls")
        let anthropicMessage = try XCTUnwrap(anthropicChoices[0]["message"] as? [String: Any])
        XCTAssertNotNil(anthropicMessage["tool_calls"])

        let gemini = ProviderResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Checking"},{"functionCall":{"name":"weather","args":{"city":"Paris"}}}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":4,"totalTokenCount":14}}"#.utf8)
        )
        let normalizedGemini = try UnifiedProtocolBridge.normalizeGemini(gemini, model: "gemini")
        let geminiObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalizedGemini.body) as? [String: Any]
        )
        let geminiChoices = try XCTUnwrap(geminiObject["choices"] as? [[String: Any]])
        let geminiMessage = try XCTUnwrap(geminiChoices[0]["message"] as? [String: Any])
        XCTAssertNotNil(geminiMessage["tool_calls"])
    }

    func testAnthropicSSETransformsIncrementallyToUnifiedChunks() async throws {
        let first = Data("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3}}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hel".utf8)
        let second = Data("lo\"}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8)
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(first)
            continuation.yield(second)
            continuation.finish()
        }
        let transformed = UnifiedProtocolBridge.anthropicStream(
            ProviderStreamResponse(statusCode: 200, headers: [:], body: source),
            model: "claude-test"
        )
        var output = Data()
        for try await chunk in transformed.body { output.append(chunk) }
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.contains("chat.completion.chunk"))
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
    }

    func testGeminiSSETransformsIncrementallyToUnifiedChunks() async throws {
        let first = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hel".utf8)
        let second = Data("lo\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":2,\"totalTokenCount\":5}}\n\n".utf8)
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(first)
            continuation.yield(second)
            continuation.finish()
        }
        let transformed = UnifiedProtocolBridge.geminiStream(
            ProviderStreamResponse(statusCode: 200, headers: [:], body: source),
            model: "gemini-test"
        )
        var output = Data()
        for try await chunk in transformed.body { output.append(chunk) }
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.contains("chat.completion.chunk"))
        XCTAssertTrue(text.contains("\"total_tokens\":5"))
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
    }

    func testAPIMartVideoDoesNotCompleteRootBaseURL() throws {
        let provider = ProviderConfig(
            name: "APIMart Seedance",
            kind: .unifiedCompatible,
            baseURL: "https://api.apimart.ai"
        )

        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"model":"route-alias","prompt":"cat"}"#.utf8),
            targetModel: "doubao-seedance-2.0",
            provider: provider,
            apiKey: "test-key",
            operation: .videoGeneration
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.apimart.ai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "doubao-seedance-2.0")
        XCTAssertEqual(json["prompt"] as? String, "cat")
    }

    func testAPIMartFullVideoEndpointIsNotAppendedAgain() throws {
        let provider = ProviderConfig(
            name: "seedance",
            kind: .unifiedCompatible,
            baseURL: "https://api.apimart.ai/v1/videos/generations"
        )

        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"prompt":"cat"}"#.utf8),
            targetModel: "doubao-seedance-2.0-fast",
            provider: provider,
            apiKey: "test-key",
            operation: .videoGeneration
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.apimart.ai/v1/videos/generations"
        )
    }

    func testMusicGenerationAndTaskUseOnlyExplicitConfiguredEndpoints() throws {
        let model = "musicgen-large"
        let provider = ProviderConfig(
            name: "Music Provider",
            kind: .unifiedCompatible,
            baseURL: "https://music.example.com/root",
            models: [model],
            endpointURLs: [
                ProviderEndpointRecord.key(for: .musicGeneration, model: model):
                    "https://music.example.com/v2/generations",
                ProviderEndpointRecord.key(for: .musicTask, model: model):
                    "https://music.example.com/v2/tasks/{task_id}"
            ]
        )
        let client = ProviderClient()
        let create = try client.nativeRequest(
            rawBody: Data(#"{"model":"route","prompt":"piano","style":"ambient"}"#.utf8),
            targetModel: model,
            provider: provider,
            apiKey: "test-key",
            operation: .musicGeneration
        )
        let task = try client.nativeRequest(
            rawBody: Data(),
            targetModel: model,
            provider: provider,
            apiKey: "test-key",
            operation: .musicTask,
            taskID: "music task/123"
        )

        XCTAssertEqual(create.url?.absoluteString, "https://music.example.com/v2/generations")
        XCTAssertEqual(create.httpMethod, "POST")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(create.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, model)
        XCTAssertEqual(body["style"] as? String, "ambient")
        XCTAssertEqual(task.url?.absoluteString, "https://music.example.com/v2/tasks/music%20task%2F123")
        XCTAssertEqual(task.httpMethod, "GET")
        XCTAssertNil(task.httpBody)
    }

    func testMusicTaskNeverFallsBackToGenerationBaseURL() {
        let provider = ProviderConfig(
            name: "Music Provider",
            kind: .unifiedCompatible,
            baseURL: "https://music.example.com/v2/generations",
            models: ["musicgen-large"]
        )

        XCTAssertThrowsError(
            try ProviderClient().nativeEndpoint(
                for: provider,
                model: "musicgen-large",
                operation: .musicTask,
                taskID: "task_123"
            )
        ) { error in
            guard case ProviderClientError.invalidRequest = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
        }
    }

    func testMusicEndpointsRejectEmbeddedCredentialsAndSecretQueriesAtRuntime() {
        for endpoint in [
            "https://user:secret@music.example.com/generate",
            "https://music.example.com/generate?access_token=secret"
        ] {
            let provider = ProviderConfig(
                name: "Music Provider",
                kind: .unifiedCompatible,
                baseURL: endpoint,
                models: ["musicgen-large"],
                endpointURLs: [
                    ProviderEndpointRecord.key(
                        for: .musicGeneration,
                        model: "musicgen-large"
                    ): endpoint
                ]
            )
            XCTAssertThrowsError(
                try ProviderClient().nativeEndpoint(
                    for: provider,
                    model: "musicgen-large",
                    operation: .musicGeneration
                )
            ) { error in
                guard case ProviderClientError.invalidBaseURL = error else {
                    return XCTFail("Expected invalidBaseURL, got \(error)")
                }
            }
        }
    }

    func testAPIMartVideoTaskDoesNotReplaceConfiguredEndpoint() throws {
        let provider = ProviderConfig(
            name: "seedance",
            kind: .unifiedCompatible,
            baseURL: "https://api.apimart.ai/v1/videos/generations"
        )

        let endpoint = try ProviderClient().nativeEndpoint(
            for: provider,
            model: "doubao-seedance-2.0-fast",
            operation: .videoTask,
            taskID: "task 123"
        )

        XCTAssertEqual(
            endpoint.absoluteString,
            "https://api.apimart.ai/v1/videos/generations"
        )
    }

    func testAPIMartPresetBuildsOfficialVideoCreateAndTaskRequests() throws {
        let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: .apimart))
        let provider = preset.applying(
            to: ProviderConfig(
                name: "APIMart",
                kind: .apimart,
                baseURL: "",
                models: ["doubao-seedance-2.0-fast"]
            ),
            mode: .replaceURLs
        )
        let client = ProviderClient()

        let create = try client.nativeRequest(
            rawBody: Data(#"{"prompt":"ModelHub connection test","duration":5,"resolution":"480p","size":"16:9","generate_audio":false}"#.utf8),
            targetModel: "doubao-seedance-2.0-fast",
            provider: provider,
            apiKey: "test-key",
            operation: .videoGeneration
        )
        XCTAssertEqual(
            create.url?.absoluteString,
            "https://api.apimart.ai/v1/videos/generations"
        )
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(create.httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "doubao-seedance-2.0-fast")

        let task = try client.nativeRequest(
            rawBody: Data(),
            targetModel: "doubao-seedance-2.0-fast",
            provider: provider,
            apiKey: "test-key",
            operation: .videoTask,
            taskID: "task 123"
        )
        XCTAssertEqual(
            task.url?.absoluteString,
            "https://api.apimart.ai/v1/tasks/task%20123"
        )
        XCTAssertEqual(task.httpMethod, "GET")
        XCTAssertNil(task.httpBody)
    }

    func testGenericSeedanceVideoDoesNotCompleteRootBaseURL() throws {
        let provider = ProviderConfig(
            name: "seedance",
            kind: .unifiedCompatible,
            baseURL: "https://gn.euno-ai.com"
        )

        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"prompt":"ModelHub connection test","duration":4}"#.utf8),
            targetModel: "doubao-seedance-2.0",
            provider: provider,
            apiKey: "test-key",
            operation: .videoGeneration
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://gn.euno-ai.com"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testAgnesVideoUsesConfiguredBaseURLForCreateAndTask() throws {
        let provider = ProviderConfig(
            name: "Agnes AI",
            kind: .unifiedCompatible,
            baseURL: "https://apihub.agnes-ai.com/v1"
        )
        let client = ProviderClient()

        let create = try client.nativeEndpoint(
            for: provider,
            model: "agnes-video-v2.0",
            operation: .videoGeneration
        )
        let task = try client.nativeEndpoint(
            for: provider,
            model: "agnes-video-v2.0",
            operation: .videoTask,
            taskID: "task 123"
        )

        XCTAssertEqual(create.absoluteString, "https://apihub.agnes-ai.com/v1")
        XCTAssertEqual(task.absoluteString, "https://apihub.agnes-ai.com/v1")
    }

    func testBailianSpeechDoesNotCompleteBaseURLForModelFamily() throws {
        let provider = ProviderConfig(
            name: "阿里云百炼 TTS",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode"
        )
        let client = ProviderClient()

        let cosyVoice = try client.nativeEndpoint(
            for: provider,
            model: "cosyvoice-v3-flash",
            operation: .speech
        )
        let qwen3 = try client.nativeEndpoint(
            for: provider,
            model: "qwen3-tts-flash",
            operation: .speech
        )

        XCTAssertEqual(
            cosyVoice.absoluteString,
            "https://dashscope.aliyuncs.com/compatible-mode"
        )
        XCTAssertEqual(
            qwen3.absoluteString,
            "https://dashscope.aliyuncs.com/compatible-mode"
        )
    }

    func testRecordedModelEndpointOverridesBaseURLWithoutRuntimeCompletion() throws {
        let model = "qwen3-tts-flash"
        let endpoint = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        let provider = ProviderConfig(
            name: "阿里云百炼 TTS",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            models: [model],
            endpointURLs: [
                ProviderEndpointRecord.key(for: .speech, model: model): endpoint
            ]
        )

        XCTAssertEqual(
            try ProviderClient().nativeEndpoint(
                for: provider,
                model: model,
                operation: .speech
            ).absoluteString,
            endpoint
        )
    }

    func testRecordedVideoTaskTemplateOnlyExpandsTaskID() throws {
        let model = "doubao-seedance-2.0-fast"
        let provider = ProviderConfig(
            name: "seedance",
            kind: .unifiedCompatible,
            baseURL: "https://api.apimart.ai/v1/videos/generations",
            models: [model],
            endpointURLs: [
                ProviderEndpointRecord.key(for: .videoTask, model: model):
                    "https://api.apimart.ai/v1/tasks/{task_id}"
            ]
        )

        XCTAssertEqual(
            try ProviderClient().nativeEndpoint(
                for: provider,
                model: model,
                operation: .videoTask,
                taskID: "task 123"
            ).absoluteString,
            "https://api.apimart.ai/v1/tasks/task%20123"
        )
    }

    func testGenericNativeEndpointsUseConfiguredBaseURLWithoutCompletion() throws {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .unifiedCompatible,
            baseURL: "https://yunwu.ai/v1"
        )
        let client = ProviderClient()

        XCTAssertEqual(
            try client.nativeEndpoint(for: provider, model: "gpt-image-1", operation: .imageGeneration).absoluteString,
            "https://yunwu.ai/v1"
        )
        XCTAssertEqual(
            try client.nativeEndpoint(for: provider, model: "text-embedding-3-small", operation: .embeddings).absoluteString,
            "https://yunwu.ai/v1"
        )
        XCTAssertEqual(
            try client.nativeEndpoint(for: provider, model: "qwen3-rerank", operation: .reranking).absoluteString,
            "https://yunwu.ai/v1"
        )
        XCTAssertEqual(
            try client.nativeEndpoint(for: provider, model: "tts-1", operation: .speech).absoluteString,
            "https://yunwu.ai/v1"
        )
    }

    func testMultipartTranscriptionRewritesRouteAliasModelField() throws {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .unifiedCompatible,
            baseURL: "https://yunwu.ai/v1"
        )
        let boundary = "ModelHubBoundary"
        let body = Data(
            """
            --\(boundary)\r
            Content-Disposition: form-data; name="model"\r
            \r
            route-alias\r
            --\(boundary)--\r

            """.utf8
        )

        let request = try ProviderClient().nativeRequest(
            rawBody: body,
            targetModel: "whisper-1",
            provider: provider,
            apiKey: "test-key",
            operation: .transcription,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        let rewritten = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)

        XCTAssertTrue(rewritten.contains("\r\nwhisper-1\r\n"))
        XCTAssertFalse(rewritten.contains("\r\nroute-alias\r\n"))
    }

    func testProviderErrorDiagnosticsExtractsSafeFieldsAndRedactsSecrets() {
        let response = ProviderResponse(
            statusCode: 400,
            headers: ["x-request-id": "req-123"],
            body: Data(
                #"{"error":{"code":"InvalidParameter","message":"bad Bearer secret-token and api_key=abcdefghijklmnopqrstuvwxyz"}}"#.utf8
            )
        )
        let summary = ProviderErrorDiagnostics.summary(for: response)

        XCTAssertTrue(summary.contains("HTTP 400"))
        XCTAssertTrue(summary.contains("InvalidParameter"))
        XCTAssertTrue(summary.contains("req-123"))
        XCTAssertTrue(summary.contains("已脱敏"))
        XCTAssertFalse(summary.contains("secret-token"))
        XCTAssertFalse(summary.contains("api_key=abcdefghijklmnopqrstuvwxyz"))
        XCTAssertLessThanOrEqual(summary.count, ProviderErrorDiagnostics.maximumSummaryCharacters)
    }

    func testBailianWanxUsesOfficialNativeEndpointAndShape() throws {
        let provider = ProviderConfig(
            name: "阿里云百炼",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"prompt":"ModelHub connection test","n":1}"#.utf8),
            targetModel: "wanx-v1",
            provider: provider,
            apiKey: "test-key",
            operation: .imageGeneration
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-Async"), "enable")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "wanx-v1")
        XCTAssertEqual((json["input"] as? [String: Any])?["prompt"] as? String, "ModelHub connection test")
    }

    func testBailianSpeechNormalizesCompatibleStyleInput() throws {
        let provider = ProviderConfig(
            name: "阿里云百炼 TTS",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode"
        )
        let request = try ProviderClient().nativeRequest(
            rawBody: Data(
                #"{"model":"alias","input":"你好","voice":"Cherry","response_format":"wav"}"#.utf8
            ),
            targetModel: "qwen3-tts-flash",
            provider: provider,
            apiKey: "test-key",
            operation: .speech
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let input = try XCTUnwrap(json["input"] as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "qwen3-tts-flash")
        XCTAssertEqual(input["text"] as? String, "你好")
        XCTAssertEqual(input["voice"] as? String, "Cherry")
        XCTAssertNil(json["voice"])
        XCTAssertNil(json["response_format"])
    }

    func testNativePassthroughKeepsProviderHostAndOriginalProtocol() throws {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .unifiedCompatible,
            baseURL: "https://yunwu.ai/v1"
        )

        let request = try ProviderClient().nativePassthroughRequest(
            rawBody: Data(#"{"prompt":"cat"}"#.utf8),
            method: "POST",
            upstreamPath: "/mj/submit/imagine",
            queryItems: ["notify": "false"],
            provider: provider,
            apiKey: "provider-key",
            headers: [
                "Authorization": "Bearer local-gateway-token",
                "Content-Type": "application/json",
                "X-Provider-Option": "keep"
            ]
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://yunwu.ai/mj/submit/imagine?notify=false"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data(#"{"prompt":"cat"}"#.utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer provider-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Provider-Option"), "keep")
    }

    func testNativePassthroughPreservesQueryOrderDuplicatesAndValuelessFlags() throws {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .unifiedCompatible,
            baseURL: "https://yunwu.ai/v1"
        )

        let request = try ProviderClient().nativePassthroughRequest(
            rawBody: Data(),
            method: "GET",
            upstreamPath: "/tasks",
            orderedQueryItems: [
                NativeQueryItem(name: "tag", value: "one"),
                NativeQueryItem(name: "flag", value: nil),
                NativeQueryItem(name: "tag", value: "two"),
                NativeQueryItem(name: "plus", value: "a+b")
            ],
            provider: provider,
            apiKey: "provider-key"
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://yunwu.ai/tasks?tag=one&flag&tag=two&plus=a+b"
        )
    }

    func testNativePassthroughRejectsAbsoluteAndTraversalPaths() {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .unifiedCompatible,
            baseURL: "https://yunwu.ai/v1"
        )
        let client = ProviderClient()

        XCTAssertThrowsError(
            try client.nativePassthroughRequest(
                rawBody: Data(),
                method: "GET",
                upstreamPath: "https://example.com/steal",
                provider: provider,
                apiKey: "provider-key"
            )
        )
        XCTAssertThrowsError(
            try client.nativePassthroughRequest(
                rawBody: Data(),
                method: "GET",
                upstreamPath: "/v1/../admin",
                provider: provider,
                apiKey: "provider-key"
            )
        )
    }
}
