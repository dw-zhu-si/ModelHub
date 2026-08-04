import XCTest
@testable import ModelHubCore

final class ProviderClientTests: XCTestCase {
    func testOpenAIEndpointAvoidsDuplicateV1() throws {
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .openAICompatible,
            baseURL: "https://example.com/v1"
        )
        let endpoint = try ProviderClient().endpoint(for: provider, model: "model")
        XCTAssertEqual(endpoint.absoluteString, "https://example.com/v1/chat/completions")
    }

    func testResponsesRequestPreservesToolsAndMultimodalInput() throws {
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .openAICompatible,
            baseURL: "https://example.com/v1"
        )
        let body = Data(#"{"model":"route","input":[{"role":"user","content":[{"type":"input_text","text":"hi"},{"type":"input_image","image_url":"data:image/png;base64,AA=="}]}],"tools":[{"type":"function","name":"weather","parameters":{"type":"object"}}]}"#.utf8)
        let request = try ProviderClient().responsesRequest(
            rawBody: body,
            targetModel: "gpt-compatible",
            provider: provider,
            apiKey: "key"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/responses")
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
            kind: .openAICompatible,
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
            baseURL: "https://api.anthropic.com"
        )
        let body = Data(#"{"model":"route","messages":[{"role":"system","content":"safe"},{"role":"user","content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]},{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"15 C"}],"tools":[{"type":"function","function":{"name":"weather","description":"Weather","parameters":{"type":"object"}}}],"stream":true}"#.utf8)

        let request = try ProviderClient().chatRequest(
            rawBody: body,
            targetModel: "claude-test",
            provider: provider,
            apiKey: "secret"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
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
            baseURL: "https://generativelanguage.googleapis.com"
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
        let normalizedAnthropic = try OpenAIProtocolBridge.normalizeAnthropic(anthropic)
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
        let normalizedGemini = try OpenAIProtocolBridge.normalizeGemini(gemini, model: "gemini")
        let geminiObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalizedGemini.body) as? [String: Any]
        )
        let geminiChoices = try XCTUnwrap(geminiObject["choices"] as? [[String: Any]])
        let geminiMessage = try XCTUnwrap(geminiChoices[0]["message"] as? [String: Any])
        XCTAssertNotNil(geminiMessage["tool_calls"])
    }

    func testAnthropicSSETransformsIncrementallyToOpenAIChunks() async throws {
        let first = Data("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3}}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hel".utf8)
        let second = Data("lo\"}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8)
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(first)
            continuation.yield(second)
            continuation.finish()
        }
        let transformed = OpenAIProtocolBridge.anthropicStream(
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

    func testGeminiSSETransformsIncrementallyToOpenAIChunks() async throws {
        let first = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hel".utf8)
        let second = Data("lo\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":2,\"totalTokenCount\":5}}\n\n".utf8)
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(first)
            continuation.yield(second)
            continuation.finish()
        }
        let transformed = OpenAIProtocolBridge.geminiStream(
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

    func testAzureEndpointContainsDeploymentAndVersion() throws {
        let provider = ProviderConfig(
            name: "Azure",
            kind: .azureOpenAI,
            baseURL: "https://resource.openai.azure.com",
            apiVersion: "2025-01-01-preview"
        )
        let endpoint = try ProviderClient().endpoint(for: provider, model: "deployment-a")
        XCTAssertTrue(endpoint.absoluteString.contains("/deployments/deployment-a/chat/completions"))
        XCTAssertTrue(endpoint.absoluteString.contains("api-version=2025-01-01-preview"))
    }

    func testAPIMartVideoUsesNativeGenerationEndpoint() throws {
        let provider = ProviderConfig(
            name: "APIMart Seedance",
            kind: .openAICompatible,
            baseURL: "https://api.apimart.ai"
        )

        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"model":"route-alias","prompt":"cat"}"#.utf8),
            targetModel: "doubao-seedance-2.0",
            provider: provider,
            apiKey: "test-key",
            operation: .videoGeneration
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.apimart.ai/v1/videos/generations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "doubao-seedance-2.0")
        XCTAssertEqual(json["prompt"] as? String, "cat")
    }

    func testAgnesVideoUsesCreateAndTaskEndpoints() throws {
        let provider = ProviderConfig(
            name: "Agnes AI",
            kind: .openAICompatible,
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

        XCTAssertEqual(create.absoluteString, "https://apihub.agnes-ai.com/v1/videos")
        XCTAssertEqual(task.absoluteString, "https://apihub.agnes-ai.com/v1/videos/task%20123")
    }

    func testBailianSpeechEndpointsFollowModelFamily() throws {
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
            "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer"
        )
        XCTAssertEqual(
            qwen3.absoluteString,
            "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        )
    }

    func testGenericNativeEndpointsAvoidDuplicateV1() throws {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .openAICompatible,
            baseURL: "https://yunwu.ai/v1"
        )
        let client = ProviderClient()

        XCTAssertEqual(
            try client.nativeEndpoint(for: provider, model: "gpt-image-1", operation: .imageGeneration).absoluteString,
            "https://yunwu.ai/v1/images/generations"
        )
        XCTAssertEqual(
            try client.nativeEndpoint(for: provider, model: "text-embedding-3-small", operation: .embeddings).absoluteString,
            "https://yunwu.ai/v1/embeddings"
        )
        XCTAssertEqual(
            try client.nativeEndpoint(for: provider, model: "qwen3-rerank", operation: .reranking).absoluteString,
            "https://yunwu.ai/v1/rerank"
        )
        XCTAssertEqual(
            try client.nativeEndpoint(for: provider, model: "tts-1", operation: .speech).absoluteString,
            "https://yunwu.ai/v1/audio/speech"
        )
    }

    func testMultipartTranscriptionRewritesRouteAliasModelField() throws {
        let provider = ProviderConfig(
            name: "云雾 API",
            kind: .openAICompatible,
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

    func testBailianSpeechNormalizesOpenAIStyleInput() throws {
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
            kind: .openAICompatible,
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
            kind: .openAICompatible,
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
            kind: .openAICompatible,
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
