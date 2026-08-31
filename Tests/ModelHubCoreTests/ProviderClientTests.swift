import XCTest
@testable import ModelHubCore

final class ProviderClientTests: XCTestCase {
    func testProxySessionPoolCoversAllManagedNodesWithoutCancellingInflightTasks() {
        XCTAssertEqual(
            ProviderProxySessionPoolPolicy.maximumSessionCount,
            ModelProxySettings.maximumActiveNodes + 1
        )
        XCTAssertFalse(ProviderProxySessionPoolPolicy.cancelsInflightTasksOnEviction)
    }

    func testDirectSessionExplicitlyDisablesSystemProxyInheritance() {
        let dictionary = ProviderNetworkSession.directConfiguration().connectionProxyDictionary

        XCTAssertEqual(dictionary?["HTTPEnable"] as? Int, 0)
        XCTAssertEqual(dictionary?["HTTPSEnable"] as? Int, 0)
        XCTAssertEqual(dictionary?["SOCKSEnable"] as? Int, 0)
    }

    func testHTTPProxySessionAppliesToHTTPAndHTTPSDestinations() {
        let endpoint = ProviderProxyEndpoint(kind: .http, host: "127.0.0.1", port: 7897)
        let dictionary = ProviderNetworkSession.proxyConfiguration(endpoint).connectionProxyDictionary

        XCTAssertEqual(dictionary?["HTTPEnable"] as? Int, 1)
        XCTAssertEqual(dictionary?["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary?["HTTPPort"] as? Int, 7897)
        XCTAssertEqual(dictionary?["HTTPSEnable"] as? Int, 1)
        XCTAssertEqual(dictionary?["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary?["HTTPSPort"] as? Int, 7897)
        XCTAssertEqual(dictionary?["SOCKSEnable"] as? Int, 0)
    }

    func testSOCKSProxySessionDoesNotEnableHTTPProxyKeys() {
        let endpoint = ProviderProxyEndpoint(kind: .socks5, host: "localhost", port: 7890)
        let dictionary = ProviderNetworkSession.proxyConfiguration(endpoint).connectionProxyDictionary

        XCTAssertEqual(dictionary?["HTTPEnable"] as? Int, 0)
        XCTAssertEqual(dictionary?["HTTPSEnable"] as? Int, 0)
        XCTAssertEqual(dictionary?["SOCKSEnable"] as? Int, 1)
        XCTAssertEqual(dictionary?["SOCKSProxy"] as? String, "localhost")
        XCTAssertEqual(dictionary?["SOCKSPort"] as? Int, 7890)
    }

    func testMiniMaxVideoRequestUsesExactModelAndDedicatedParameters() throws {
        let provider = try miniMaxProvider(kind: .minimaxChina)
        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"prompt":"ocean","duration":5,"resolution":"480p","size":"16:9","generate_audio":false,"watermark":true}"#.utf8),
            targetModel: "MiniMax-Hailuo-2.3",
            provider: provider,
            apiKey: "test-key",
            operation: .videoGeneration
        )

        let body = try jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "MiniMax-Hailuo-2.3")
        XCTAssertEqual(body["duration"] as? Int, 6)
        XCTAssertEqual(body["resolution"] as? String, "768P")
        XCTAssertEqual(body["aigc_watermark"] as? Bool, true)
        XCTAssertNil(body["size"])
        XCTAssertNil(body["generate_audio"])
        XCTAssertNil(body["watermark"])
    }

    func testMiniMaxMusicRequestMapsGenericFieldsToOfficialSchema() throws {
        let provider = try miniMaxProvider(kind: .minimax)
        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"prompt":"calm piano","duration":5,"instrumental":true,"response_format":"url","sample_rate":44100}"#.utf8),
            targetModel: "music-3.0",
            provider: provider,
            apiKey: "test-key",
            operation: .musicGeneration
        )

        let body = try jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "music-3.0")
        XCTAssertEqual(body["is_instrumental"] as? Bool, true)
        XCTAssertEqual(body["output_format"] as? String, "url")
        XCTAssertEqual((body["audio_setting"] as? [String: Any])?["sample_rate"] as? Int, 44_100)
        XCTAssertNil(body["instrumental"])
        XCTAssertNil(body["duration"])
        XCTAssertNil(body["response_format"])
        XCTAssertNil(body["sample_rate"])
    }

    func testMiniMaxRepairsOnlyKnownLegacyModelHubMusicAlias() throws {
        let provider = try miniMaxProvider(kind: .minimaxChina)
        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"prompt":"calm piano","instrumental":true}"#.utf8),
            targetModel: "MiniMax Music 3.0",
            provider: provider,
            apiKey: "test-key",
            operation: .musicGeneration
        )

        XCTAssertEqual(try jsonBody(request)["model"] as? String, "music-3.0")
    }

    func testMiniMaxRepairsLegacyMusic26ModelHubAlias() throws {
        let provider = try miniMaxProvider(kind: .minimaxChina)
        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"prompt":"calm piano","instrumental":true}"#.utf8),
            targetModel: "MiniMax Music-2.6",
            provider: provider,
            apiKey: "test-key",
            operation: .musicGeneration
        )

        XCTAssertEqual(try jsonBody(request)["model"] as? String, "music-2.6")
    }

    func testMiniMaxSpeechRequestMapsUnifiedSpeechFields() throws {
        let provider = try miniMaxProvider(kind: .minimaxChina)
        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"input":"你好","voice":"male-qn-qingse","response_format":"mp3","sample_rate":32000}"#.utf8),
            targetModel: "speech-2.8-hd",
            provider: provider,
            apiKey: "test-key",
            operation: .speech
        )

        let body = try jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "speech-2.8-hd")
        XCTAssertEqual(body["text"] as? String, "你好")
        XCTAssertEqual((body["voice_setting"] as? [String: Any])?["voice_id"] as? String, "male-qn-qingse")
        XCTAssertEqual((body["audio_setting"] as? [String: Any])?["format"] as? String, "mp3")
        XCTAssertEqual((body["audio_setting"] as? [String: Any])?["sample_rate"] as? Int, 32_000)
        XCTAssertNil(body["input"])
        XCTAssertNil(body["voice"])
        XCTAssertNil(body["response_format"])
    }

    func testMiniMaxImageRequestMapsOpenAICompatibleSize() throws {
        let provider = try miniMaxProvider(kind: .minimaxChina)
        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"prompt":"mountain","size":"1024x1024","quality":"high","watermark":false}"#.utf8),
            targetModel: "image-01",
            provider: provider,
            apiKey: "test-key",
            operation: .imageGeneration
        )

        let body = try jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "image-01")
        XCTAssertEqual(body["width"] as? Int, 1_024)
        XCTAssertEqual(body["height"] as? Int, 1_024)
        XCTAssertEqual(body["aigc_watermark"] as? Bool, false)
        XCTAssertNil(body["size"])
        XCTAssertNil(body["quality"])
    }

    func testMiniMaxNativeRequestRejectsInexactOrWrongCapabilityModelIDs() throws {
        let provider = try miniMaxProvider(kind: .minimaxChina)
        for (model, operation) in [
            ("minimax-hailuo-2.3", NativeAPIOperation.videoGeneration),
            ("music-3.0", NativeAPIOperation.videoGeneration),
            ("image-01", NativeAPIOperation.musicGeneration)
        ] {
            XCTAssertThrowsError(
                try ProviderClient().nativeRequest(
                    rawBody: Data(#"{"prompt":"test"}"#.utf8),
                    targetModel: model,
                    provider: provider,
                    apiKey: "test-key",
                    operation: operation
                )
            ) { error in
                guard case ProviderClientError.invalidRequest(let detail) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(detail.contains("精确模型 ID"))
            }
        }
    }

    func testMiniMaxTaskQueryRejectsInexactModelIDBeforeNetworkUse() throws {
        let provider = try miniMaxProvider(kind: .minimaxChina)
        XCTAssertThrowsError(
            try ProviderClient().nativeRequest(
                rawBody: Data(),
                targetModel: "minimax-hailuo-2.3",
                provider: provider,
                apiKey: "test-key",
                operation: .videoTask,
                taskID: "task_1"
            )
        ) { error in
            guard case ProviderClientError.invalidRequest(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("精确模型 ID"))
        }
    }

    func testMiniMaxNativeOperationsRejectMultipartBeforeNetworkUse() throws {
        let provider = try miniMaxProvider(kind: .minimaxChina)
        XCTAssertThrowsError(
            try ProviderClient().nativeRequest(
                rawBody: Data("body".utf8),
                targetModel: "image-01",
                provider: provider,
                apiKey: "test-key",
                operation: .imageGeneration,
                contentType: "multipart/form-data; boundary=test"
            )
        ) { error in
            guard case ProviderClientError.invalidRequest(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("application/json"))
        }
    }

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

    func testGeminiDeveloperOAuthUsesBearerInsteadOfAPIKeyHeader() throws {
        let provider = ProviderConfig(
            name: "Gemini Developer API",
            kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        )
        let request = try ProviderClient().chatRequest(
            rawBody: Data(#"{"model":"alias","messages":[{"role":"user","content":"hi"}]}"#.utf8),
            targetModel: "gemini-2.5-flash",
            provider: provider,
            authorization: .bearerAccessToken(
                "oauth-access-token",
                billingProjectID: "modelhub-oauth-project"
            )
        )

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer oauth-access-token"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-goog-user-project"),
            "modelhub-oauth-project"
        )
    }

    func testGeminiDeveloperOAuthRejectsInvalidBillingProjectHeader() {
        let provider = ProviderConfig(
            name: "Gemini Developer API",
            kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        )
        XCTAssertThrowsError(try ProviderClient().chatRequest(
            rawBody: Data(#"{"model":"alias","messages":[{"role":"user","content":"hi"}]}"#.utf8),
            targetModel: "gemini-2.5-flash",
            provider: provider,
            authorization: .bearerAccessToken(
                "oauth-access-token",
                billingProjectID: "bad\r\nheader"
            )
        )) { error in
            guard case .invalidRequest = error as? ProviderClientError else {
                return XCTFail("expected invalid request, got \(error)")
            }
        }
    }

    func testGeminiDeveloperOAuthRejectsNonOfficialOrInsecureAPIOrigins() {
        let rejectedBaseURLs = [
            "http://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
            "https://example.com/v1beta/models/{model}:generateContent",
            "https://generativelanguage.googleapis.com.evil.example/v1beta/models/{model}:generateContent",
            "https://generativelanguage.googleapis.com:8443/v1beta/models/{model}:generateContent"
        ]

        for baseURL in rejectedBaseURLs {
            let provider = ProviderConfig(
                name: "Gemini Developer API",
                kind: .gemini,
                baseURL: baseURL
            )

            XCTAssertThrowsError(try ProviderClient().chatRequest(
                rawBody: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8),
                targetModel: "gemini-2.5-flash",
                provider: provider,
                authorization: .bearerAccessToken(
                    "oauth-access-token",
                    billingProjectID: "modelhub-oauth-project"
                )
            ), "OAuth bearer must not be attached to \(baseURL)") { error in
                guard case .invalidRequest = error as? ProviderClientError else {
                    return XCTFail("expected invalid request, got \(error)")
                }
            }
        }
    }

    func testGeminiDeveloperOAuthRedirectPolicyAllowsOnlySameOfficialOrigin() throws {
        let original = try XCTUnwrap(URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent"
        ))

        XCTAssertTrue(GeminiDeveloperOAuthTransportPolicy.allowsRedirect(
            from: original,
            to: try XCTUnwrap(URL(
                string: "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent?alt=json"
            ))
        ))
        XCTAssertFalse(GeminiDeveloperOAuthTransportPolicy.allowsRedirect(
            from: original,
            to: try XCTUnwrap(URL(string: "https://example.com/steal"))
        ))
        XCTAssertFalse(GeminiDeveloperOAuthTransportPolicy.allowsRedirect(
            from: original,
            to: try XCTUnwrap(URL(
                string: "http://generativelanguage.googleapis.com/steal"
            ))
        ))
    }

    func testNonStreamingProviderResponseStopsAtConfiguredTransportByteLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedProviderResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ProviderClient(session: session, maximumNonStreamingResponseBytes: 16)
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1/chat/completions"
        )

        do {
            _ = try await client.send(
                rawBody: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8),
                targetModel: "test-model",
                provider: provider,
                apiKey: "test-key"
            )
            XCTFail("oversized response must fail before returning a fully buffered body")
        } catch {
            guard case .responseTooLarge(let limit) = error as? ProviderClientError else {
                return XCTFail("expected responseTooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 16)
        }

        XCTAssertLessThanOrEqual(
            BoundedProviderResponseURLProtocol.deliveredBytes,
            24,
            "transport should be cancelled near the limit, not after buffering the complete body"
        )
    }

    func testSecureConnectionFailureIsRetriedOnceOnTheSameTransport() async throws {
        TLSRecoveryURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TLSRecoveryURLProtocol.self]
        let client = ProviderClient(session: URLSession(configuration: configuration))
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1/chat/completions"
        )

        let response = try await client.send(
            rawBody: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8),
            targetModel: "test-model",
            provider: provider,
            apiKey: "test-key"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(TLSRecoveryURLProtocol.attempts, 2)
    }

    func testCertificateTrustFailureIsTerminalAndNeverRetried() async throws {
        TerminalTLSURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TerminalTLSURLProtocol.self]
        let client = ProviderClient(session: URLSession(configuration: configuration))
        let provider = ProviderConfig(
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1/chat/completions"
        )

        do {
            _ = try await client.send(
                rawBody: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8),
                targetModel: "test-model",
                provider: provider,
                apiKey: "test-key"
            )
            XCTFail("certificate trust failure must remain terminal")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .serverCertificateUntrusted)
        }
        XCTAssertEqual(TerminalTLSURLProtocol.attempts, 1)
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

    func testQianwenImageUsesMultimodalGenerationEndpointAndPayload() throws {
        let provider = ProviderConfig(
            name: "千问AI平台（按量付费）",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        let request = try ProviderClient().nativeRequest(
            rawBody: Data(#"{"prompt":"一只猫","size":"2K"}"#.utf8),
            targetModel: "qwen-image-3.0-pro",
            provider: provider,
            apiKey: "test-key",
            operation: .imageGeneration
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        )
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        XCTAssertNotNil(input["messages"] as? [[String: Any]])
        XCTAssertEqual((json["parameters"] as? [String: Any])?["size"] as? String, "2K")
    }

    func testQianwenImageMapsGatewayReferenceIntoMultimodalContent() throws {
        let provider = ProviderConfig(
            name: "千问AI平台（按量付费）",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        let reference = "data:image/jpeg;base64,AQID"
        let rawBody = try JSONSerialization.data(withJSONObject: [
            "prompt": "按照参考图生成",
            "image_url": reference,
            "size": "1024*1024"
        ])

        let request = try ProviderClient().nativeRequest(
            rawBody: rawBody,
            targetModel: "qwen-image-3.0-pro",
            provider: provider,
            apiKey: "test-key",
            operation: .imageGeneration
        )

        let json = try jsonBody(request)
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content.first?["image"] as? String, reference)
        XCTAssertEqual(content.last?["text"] as? String, "按照参考图生成")
        XCTAssertNil(json["image_url"])
    }

    func testQianwenImagePreservesNativeMultimodalInput() throws {
        let provider = ProviderConfig(
            name: "千问AI平台（按量付费）",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        let reference = "data:image/png;base64,AQID"
        let rawBody = try JSONSerialization.data(withJSONObject: [
            "prompt": "兼容提示词",
            "input": [
                "messages": [[
                    "role": "user",
                    "content": [
                        ["image": reference],
                        ["text": "原生多模态提示词"]
                    ]
                ]]
            ]
        ])

        let request = try ProviderClient().nativeRequest(
            rawBody: rawBody,
            targetModel: "qwen-image-3.0-pro",
            provider: provider,
            apiKey: "test-key",
            operation: .imageGeneration
        )

        let json = try jsonBody(request)
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["image"] as? String, reference)
        XCTAssertEqual(content.last?["text"] as? String, "原生多模态提示词")
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

    func testQianwenNativeProbeUsesOfficialEmbeddingAndRerankingEndpoints() throws {
        let provider = ProviderConfig(
            name: "千问AI平台（按量付费）",
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .chat):
                    "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
            ]
        )
        let client = ProviderClient()

        XCTAssertEqual(
            try client.nativeEndpoint(
                for: provider,
                model: "text-embedding-v4",
                operation: .embeddings
            ).absoluteString,
            "https://dashscope.aliyuncs.com/compatible-mode/v1/embeddings"
        )
        XCTAssertEqual(
            try client.nativeEndpoint(
                for: provider,
                model: "qwen3-rerank",
                operation: .reranking
            ).absoluteString,
            "https://dashscope.aliyuncs.com/compatible-api/v1/reranks"
        )
        XCTAssertEqual(
            try client.nativeEndpoint(
                for: provider,
                model: "qwen3-vl-embedding-2b",
                operation: .embeddings
            ).absoluteString,
            "https://dashscope.aliyuncs.com/api/v1/services/embeddings/multimodal-embedding/multimodal-embedding"
        )
    }
}

private final class BoundedProviderResponseURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _deliveredBytes = 0
    private let stateLock = NSLock()
    private var stopped = false

    static var deliveredBytes: Int {
        lock.withLock { _deliveredBytes }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._deliveredBytes = 0 }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.002)
                guard !self.stateLock.withLock({ self.stopped }) else { return }
                let chunk = Data(repeating: 0x61, count: 8)
                Self.lock.withLock { Self._deliveredBytes += chunk.count }
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            guard !self.stateLock.withLock({ self.stopped }) else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }
}

private final class TLSRecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _attempts = 0

    static var attempts: Int { lock.withLock { _attempts } }
    static func reset() { lock.withLock { _attempts = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let attempt = Self.lock.withLock {
            Self._attempts += 1
            return Self._attempts
        }
        if attempt == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"ok"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TerminalTLSURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _attempts = 0

    static var attempts: Int { lock.withLock { _attempts } }
    static func reset() { lock.withLock { _attempts = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._attempts += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
    }

    override func stopLoading() {}
}

private extension ProviderClientTests {
    func miniMaxProvider(kind: ProviderKind) throws -> ProviderConfig {
        let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: kind))
        return preset.applying(
            to: ProviderConfig(name: kind.displayName, kind: kind, baseURL: ""),
            mode: .replaceURLs
        )
    }

    func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
    }
}
