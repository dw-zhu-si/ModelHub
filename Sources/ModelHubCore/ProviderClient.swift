import Foundation

public enum ProviderNetworkSession {
    public static func directConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        // A gateway request already has an explicit request timeout and the
        // local server has a bounded handler lifecycle. Do not keep scarce
        // inbound connections parked while the network is unavailable.
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0
        ]
        return configuration
    }

    public static func proxyConfiguration(
        _ endpoint: ProviderProxyEndpoint
    ) -> URLSessionConfiguration {
        let configuration = directConfiguration()
        // A managed proxy is a local, already-running dependency. Waiting for
        // connectivity here can suspend a request indefinitely after Mihomo
        // exits, leaving model health probes stuck at 0/N. Fail promptly so
        // the caller can recover the runtime or stop without routing direct.
        configuration.waitsForConnectivity = false
        switch endpoint.kind {
        case .http:
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": endpoint.host,
                "HTTPPort": endpoint.port,
                "HTTPSEnable": 1,
                "HTTPSProxy": endpoint.host,
                "HTTPSPort": endpoint.port,
                "SOCKSEnable": 0
            ]
        case .socks5:
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "SOCKSEnable": 1,
                "SOCKSProxy": endpoint.host,
                "SOCKSPort": endpoint.port
            ]
        }
        return configuration
    }
}

enum ProviderProxySessionPoolPolicy {
    static let maximumSessionCount = ModelProxySettings.maximumActiveNodes + 1
    static let cancelsInflightTasksOnEviction = false
}

public struct ProviderProxySessionPoolMetrics: Equatable, Sendable {
    public let activeSessions: Int
    public let capacity: Int
    public let createdSessions: UInt64
    public let reusedSessions: UInt64
    public let evictions: UInt64
}

private actor ProviderProxySessionPool {
    static let shared = ProviderProxySessionPool()
    private var sessions: [ProviderProxyEndpoint: URLSession] = [:]
    private var insertionOrder: [ProviderProxyEndpoint] = []
    private let maximumSessionCount = ProviderProxySessionPoolPolicy.maximumSessionCount
    private var createdSessions: UInt64 = 0
    private var reusedSessions: UInt64 = 0
    private var evictions: UInt64 = 0

    func session(for endpoint: ProviderProxyEndpoint) -> URLSession {
        if let existing = sessions[endpoint] {
            reusedSessions &+= 1
            insertionOrder.removeAll { $0 == endpoint }
            insertionOrder.append(endpoint)
            return existing
        }
        if sessions.count >= maximumSessionCount,
           let oldest = insertionOrder.first
        {
            insertionOrder.removeFirst()
            sessions.removeValue(forKey: oldest)?.finishTasksAndInvalidate()
            evictions &+= 1
        }
        let created = URLSession(
            configuration: ProviderNetworkSession.proxyConfiguration(endpoint)
        )
        sessions[endpoint] = created
        insertionOrder.append(endpoint)
        createdSessions &+= 1
        return created
    }

    func metrics() -> ProviderProxySessionPoolMetrics {
        ProviderProxySessionPoolMetrics(
            activeSessions: sessions.count,
            capacity: maximumSessionCount,
            createdSessions: createdSessions,
            reusedSessions: reusedSessions,
            evictions: evictions
        )
    }

    func resetForTesting() {
        sessions.values.forEach { $0.finishTasksAndInvalidate() }
        sessions.removeAll()
        insertionOrder.removeAll()
        createdSessions = 0
        reusedSessions = 0
        evictions = 0
    }
}

public struct ProviderResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var contentType: String {
        headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            ?? "application/json"
    }
}

public struct ProviderStreamResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, Error>

    public init(
        statusCode: Int,
        headers: [String: String],
        body: AsyncThrowingStream<Data, Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var contentType: String {
        headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            ?? "text/event-stream"
    }
}

public struct NativeQueryItem: Sendable, Equatable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

public enum ProviderClientError: LocalizedError {
    case invalidBaseURL
    case missingAPIKey
    case credentialAccessUnavailable
    case credentialMismatch(String)
    case invalidRequest(String)
    case nonHTTPResponse

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "供应商 Base URL 无效"
        case .missingAPIKey: "供应商 API Key 未配置"
        case .credentialAccessUnavailable: "钥匙串暂时不可读，请解锁本机后重试"
        case .credentialMismatch(let message): message
        case .invalidRequest(let detail): "请求无法转换：\(detail)"
        case .nonHTTPResponse: "供应商返回了非 HTTP 响应"
        }
    }

    public var isInvalidClientRequest: Bool {
        switch self {
        case .invalidRequest, .credentialMismatch: true
        default: false
        }
    }

    public var isCredentialIssue: Bool {
        switch self {
        case .missingAPIKey, .credentialMismatch: true
        default: false
        }
    }

    public var isTransportFailure: Bool {
        if case .nonHTTPResponse = self { return true }
        return false
    }

    public var gatewayStatusCode: Int {
        if isInvalidClientRequest { return 400 }
        if case .credentialAccessUnavailable = self { return 503 }
        return 502
    }

    public var isCredentialAccessUnavailable: Bool {
        if case .credentialAccessUnavailable = self { return true }
        return false
    }
}

public struct ProviderClient: Sendable {
    let session: URLSession
    let catalogRecoverySessionFactory: (@Sendable () -> URLSession)?

    public init() {
        self.session = URLSession(configuration: ProviderNetworkSession.directConfiguration())
        self.catalogRecoverySessionFactory = {
            URLSession(configuration: ProviderNetworkSession.directConfiguration())
        }
    }

    public static func proxySessionMetrics() async -> ProviderProxySessionPoolMetrics {
        await ProviderProxySessionPool.shared.metrics()
    }

    static func proxySessionForTesting(_ endpoint: ProviderProxyEndpoint) async -> URLSession {
        await ProviderProxySessionPool.shared.session(for: endpoint)
    }

    static func resetProxySessionMetricsForTesting() async {
        await ProviderProxySessionPool.shared.resetForTesting()
    }

    public init(session: URLSession) {
        self.session = session
        if session === URLSession.shared {
            self.catalogRecoverySessionFactory = {
                URLSession(configuration: ProviderNetworkSession.directConfiguration())
            }
        } else {
            self.catalogRecoverySessionFactory = nil
        }
    }

    init(
        session: URLSession,
        catalogRecoverySessionFactory: @escaping @Sendable () -> URLSession
    ) {
        self.session = session
        self.catalogRecoverySessionFactory = catalogRecoverySessionFactory
    }

    public func send(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 180,
        proxy: ProviderProxyEndpoint? = nil
    ) async throws -> ProviderResponse {
        try validateCredential(provider: provider, apiKey: apiKey)

        switch provider.kind {
        case .anthropic:
            return try await sendAnthropic(
                rawBody: rawBody,
                targetModel: targetModel,
                provider: provider,
                apiKey: apiKey ?? "",
                timeoutInterval: timeoutInterval,
                proxy: proxy
            )
        case .gemini:
            return try await sendGemini(
                rawBody: rawBody,
                targetModel: targetModel,
                provider: provider,
                apiKey: apiKey ?? "",
                timeoutInterval: timeoutInterval,
                proxy: proxy
            )
        default:
            return try await sendUnifiedCompatible(
                rawBody: rawBody,
                targetModel: targetModel,
                provider: provider,
                apiKey: apiKey,
                timeoutInterval: timeoutInterval,
                proxy: proxy
            )
        }
    }

    public func endpoint(for provider: ProviderConfig, model: String) throws -> URL {
        try configuredURL(for: provider, kind: .chat, model: model)
    }

    public func responsesEndpoint(for provider: ProviderConfig) throws -> URL {
        guard provider.kind.usesUnifiedProtocol else {
            throw ProviderClientError.invalidRequest("该供应商暂不支持 Responses API 透传")
        }
        return try configuredURL(for: provider, kind: .responses)
    }

    public func responsesRequest(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 180
    ) throws -> URLRequest {
        try validateCredential(provider: provider, apiKey: apiKey)
        var json = try jsonObject(from: rawBody)
        json["model"] = targetModel
        var request = URLRequest(url: try responsesEndpoint(for: provider))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    public func chatRequest(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 180
    ) throws -> URLRequest {
        try validateCredential(provider: provider, apiKey: apiKey)
        switch provider.kind {
        case .anthropic:
            var request = URLRequest(url: try endpoint(for: provider, model: targetModel))
            request.httpMethod = "POST"
            request.httpBody = try UnifiedProtocolBridge.anthropicBody(
                from: rawBody,
                targetModel: targetModel
            )
            request.timeoutInterval = timeoutInterval
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(
                provider.apiVersion.isEmpty ? "2023-06-01" : provider.apiVersion,
                forHTTPHeaderField: "anthropic-version"
            )
            return request
        case .gemini:
            var components = URLComponents(
                url: try geminiEndpoint(
                    for: provider,
                    model: targetModel,
                    streaming: requestStreams(rawBody)
                ),
                resolvingAgainstBaseURL: false
            )
            if requestStreams(rawBody) {
                components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            }
            guard let url = components?.url else { throw ProviderClientError.invalidBaseURL }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try UnifiedProtocolBridge.geminiBody(from: rawBody)
            request.timeoutInterval = timeoutInterval
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            return request
        default:
            break
        }
        var json = try jsonObject(from: rawBody)
        json["model"] = targetModel
        var request = URLRequest(url: try endpoint(for: provider, model: targetModel))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    public func startChatStream(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        proxy: ProviderProxyEndpoint? = nil
    ) async throws -> ProviderStreamResponse {
        let response = try await executeStream(chatRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey
        ), proxy: proxy)
        guard (200..<300).contains(response.statusCode) else { return response }
        switch provider.kind {
        case .anthropic:
            return UnifiedProtocolBridge.anthropicStream(response, model: targetModel)
        case .gemini:
            return UnifiedProtocolBridge.geminiStream(response, model: targetModel)
        default:
            return response
        }
    }

    public func startResponsesStream(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        proxy: ProviderProxyEndpoint? = nil
    ) async throws -> ProviderStreamResponse {
        try await executeStream(responsesRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey
        ), proxy: proxy)
    }

    public func sendResponses(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 180,
        proxy: ProviderProxyEndpoint? = nil
    ) async throws -> ProviderResponse {
        try await execute(responsesRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        ), proxy: proxy)
    }

    public func nativeEndpoint(
        for provider: ProviderConfig,
        model: String,
        operation: NativeAPIOperation,
        taskID: String? = nil
    ) throws -> URL {
        if operation == .videoTask || operation == .musicTask {
            guard let taskID, !taskID.isEmpty else {
                throw ProviderClientError.invalidRequest("查询生成任务需要 task_id")
            }
        }
        let endpointKind: ProviderEndpointKind = switch operation {
        case .imageGeneration: .imageGeneration
        case .musicGeneration: .musicGeneration
        case .musicTask: .musicTask
        case .videoGeneration: .videoGeneration
        case .videoTask: .videoTask
        case .speech: .speech
        case .transcription: .transcription
        case .embeddings: .embeddings
        case .reranking: .reranking
        }
        if isBailian(provider), !hasExplicitEndpoint(
            provider,
            kind: endpointKind,
            model: model
        ) {
            if operation == .imageGeneration {
                let path = model.caseInsensitiveCompare("wanx-v1") == .orderedSame
                    ? "/api/v1/services/aigc/text2image/image-synthesis"
                    : "/api/v1/services/aigc/multimodal-generation/generation"
                if let official = bailianURL(provider: provider, path: path) { return official }
            }
            if operation == .videoGeneration,
               let official = bailianURL(
                   provider: provider,
                   path: "/api/v1/services/aigc/video-generation/video-synthesis"
               ) {
                return official
            }
            if operation == .videoTask, let taskID,
               let encoded = taskID.addingPercentEncoding(
                   withAllowedCharacters: .urlPathAllowed.subtracting(
                       CharacterSet(charactersIn: "/?#")
                   )
               ),
               let official = bailianURL(provider: provider, path: "/api/v1/tasks/\(encoded)") {
                return official
            }
            if operation == .embeddings {
                let path = model.lowercased().contains("vl-embedding")
                    ? "/api/v1/services/embeddings/multimodal-embedding/multimodal-embedding"
                    : "/compatible-mode/v1/embeddings"
                if let official = bailianURL(provider: provider, path: path) { return official }
            }
            if operation == .reranking {
                let path = model.lowercased().contains("vl-rerank")
                    ? "/api/v1/services/rerank/text-rerank/text-rerank"
                    : "/compatible-api/v1/reranks"
                if let official = bailianURL(provider: provider, path: path) { return official }
            }
        }
        return try configuredURL(
            for: provider,
            kind: endpointKind,
            model: model,
            taskID: taskID
        )
    }

    public func nativeRequest(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        operation: NativeAPIOperation,
        taskID: String? = nil,
        contentType: String = "application/json",
        timeoutInterval: TimeInterval = 600
    ) throws -> URLRequest {
        try validateCredential(provider: provider, apiKey: apiKey)

        var request = URLRequest(
            url: try nativeEndpoint(
                for: provider,
                model: targetModel,
                operation: operation,
                taskID: taskID
            )
        )
        let isTaskQuery = operation == .videoTask || operation == .musicTask
        if isTaskQuery, MiniMaxNativeAdapter.isMiniMax(provider) {
            try MiniMaxNativeAdapter.validateExactModelID(
                MiniMaxNativeAdapter.canonicalModelID(forStoredModelID: targetModel),
                operation: operation
            )
        }
        if !isTaskQuery,
           MiniMaxNativeAdapter.isMiniMax(provider),
           !contentType.lowercased().contains("application/json") {
            throw ProviderClientError.invalidRequest(
                "MiniMax 图片、音乐、视频和语音原生接口只接受 application/json"
            )
        }
        request.httpMethod = isTaskQuery ? "GET" : "POST"
        request.timeoutInterval = timeoutInterval

        if !isTaskQuery {
            if contentType.lowercased().contains("application/json") {
                var json = try jsonObject(from: rawBody)
                json["model"] = targetModel
                if MiniMaxNativeAdapter.isMiniMax(provider) {
                    json = try MiniMaxNativeAdapter.normalizedRequest(
                        json,
                        model: targetModel,
                        operation: operation
                    )
                } else if operation == .speech && isBailian(provider) {
                    json = normalizeBailianSpeechJSON(json, model: targetModel)
                } else if operation == .imageGeneration,
                          isBailian(provider),
                          targetModel.caseInsensitiveCompare("wanx-v1") == .orderedSame {
                    json = normalizeBailianWanxJSON(json, model: targetModel)
                    request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
                } else if operation == .imageGeneration, isBailian(provider) {
                    json = normalizeQianwenImageJSON(json, model: targetModel)
                } else if operation == .videoGeneration, isBailian(provider) {
                    json = normalizeQianwenVideoJSON(json, model: targetModel)
                    request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else {
                request.httpBody = rewriteMultipartModel(
                    in: rawBody,
                    contentType: contentType,
                    targetModel: targetModel
                )
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func isBailian(_ provider: ProviderConfig) -> Bool {
        provider.kind.isBailian
            || provider.baseURL.lowercased().contains("aliyuncs.com")
            || provider.name.contains("百炼")
            || provider.name.contains("千问AI平台")
    }

    private func hasExplicitEndpoint(
        _ provider: ProviderConfig,
        kind: ProviderEndpointKind,
        model: String
    ) -> Bool {
        provider.endpointURLs[ProviderEndpointRecord.key(for: kind, model: model)] != nil
            || provider.endpointURLs[ProviderEndpointRecord.key(for: kind)] != nil
    }

    private func bailianURL(provider: ProviderConfig, path: String) -> URL? {
        guard var components = URLComponents(string: provider.baseURL) else { return nil }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func normalizeBailianSpeechJSON(
        _ original: [String: Any],
        model: String
    ) -> [String: Any] {
        guard let text = original["input"] as? String else {
            return original
        }

        var json = original
        let voice = json.removeValue(forKey: "voice")
        let responseFormat = json.removeValue(forKey: "response_format")
        let sampleRate = json.removeValue(forKey: "sample_rate")
        let lowered = model.lowercased()

        if lowered.hasPrefix("minimax/") {
            var input: [String: Any] = ["text": text]
            if let voiceSetting = json.removeValue(forKey: "voice_setting") {
                input["voice_setting"] = voiceSetting
            } else if let voice {
                input["voice_setting"] = ["voice_id": voice]
            }
            if let audioSetting = json.removeValue(forKey: "audio_setting") {
                input["audio_setting"] = audioSetting
            } else if responseFormat != nil || sampleRate != nil {
                var audio: [String: Any] = [:]
                if let responseFormat { audio["format"] = responseFormat }
                if let sampleRate { audio["sample_rate"] = sampleRate }
                input["audio_setting"] = audio
            }
            json["input"] = input
            return json
        }

        var input: [String: Any] = ["text": text]
        if let voice { input["voice"] = voice }
        if lowered.hasPrefix("cosyvoice") || lowered.hasPrefix("qwen-audio-") {
            if let responseFormat { input["format"] = responseFormat }
            if let sampleRate { input["sample_rate"] = sampleRate }
        } else if let languageType = json.removeValue(forKey: "language_type") {
            input["language_type"] = languageType
        }
        json["input"] = input
        return json
    }

    private func normalizeBailianWanxJSON(
        _ original: [String: Any],
        model: String
    ) -> [String: Any] {
        let prompt = original["prompt"] as? String ?? "ModelHub connection test"
        var parameters: [String: Any] = [:]
        if let count = original["n"] as? NSNumber {
            parameters["n"] = count
        }
        return [
            "model": model,
            "input": ["prompt": prompt],
            "parameters": parameters
        ]
    }

    private func normalizeQianwenImageJSON(
        _ original: [String: Any],
        model: String
    ) -> [String: Any] {
        let prompt = original["prompt"] as? String ?? "ModelHub connection test"
        var parameters = original["parameters"] as? [String: Any] ?? [:]
        for key in ["size", "n", "negative_prompt", "prompt_extend", "watermark", "seed"] {
            if let value = original[key] { parameters[key] = value }
        }
        let input: [String: Any]
        if let nativeInput = original["input"] as? [String: Any],
           let messages = nativeInput["messages"] as? [Any],
           !messages.isEmpty {
            input = nativeInput
        } else {
            var content: [[String: Any]] = []
            if let imageURL = original["image_url"] as? String, !imageURL.isEmpty {
                content.append(["image": imageURL])
            }
            content.append(["text": prompt])
            input = [
                "messages": [[
                    "role": "user",
                    "content": content
                ]]
            ]
        }
        return [
            "model": model,
            "input": input,
            "parameters": parameters
        ]
    }

    private func normalizeQianwenVideoJSON(
        _ original: [String: Any],
        model: String
    ) -> [String: Any] {
        let prompt = original["prompt"] as? String ?? "ModelHub connection test"
        var input = original["input"] as? [String: Any] ?? [:]
        input["prompt"] = input["prompt"] ?? prompt
        if let imageURL = original["image_url"] { input["img_url"] = imageURL }
        var parameters = original["parameters"] as? [String: Any] ?? [:]
        for key in [
            "resolution", "duration", "size", "prompt_extend", "watermark",
            "seed", "audio", "negative_prompt"
        ] where original[key] != nil {
            parameters[key] = original[key]
        }
        return ["model": model, "input": input, "parameters": parameters]
    }

    private func rewriteMultipartModel(
        in body: Data,
        contentType: String,
        targetModel: String
    ) -> Data {
        guard contentType.lowercased().contains("multipart/form-data"),
              let boundaryPart = contentType.split(separator: ";")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.lowercased().hasPrefix("boundary=") })
        else {
            return body
        }

        let rawBoundary = String(boundaryPart.dropFirst("boundary=".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !rawBoundary.isEmpty,
              let dispositionRange = body.range(of: Data(#"name="model""#.utf8)),
              let valueSeparator = body.range(
                of: Data("\r\n\r\n".utf8),
                in: dispositionRange.upperBound..<body.endIndex
              )
        else {
            return body
        }

        let valueStart = valueSeparator.upperBound
        let closingMarker = Data("\r\n--\(rawBoundary)".utf8)
        guard let valueEnd = body.range(
            of: closingMarker,
            in: valueStart..<body.endIndex
        )?.lowerBound else {
            return body
        }

        var rewritten = body
        rewritten.replaceSubrange(valueStart..<valueEnd, with: Data(targetModel.utf8))
        return rewritten
    }

    public func sendNative(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        operation: NativeAPIOperation,
        taskID: String? = nil,
        contentType: String = "application/json",
        timeoutInterval: TimeInterval = 600,
        proxy: ProviderProxyEndpoint? = nil
    ) async throws -> ProviderResponse {
        try await execute(
            nativeRequest(
                rawBody: rawBody,
                targetModel: targetModel,
                provider: provider,
                apiKey: apiKey,
                operation: operation,
                taskID: taskID,
                contentType: contentType,
                timeoutInterval: timeoutInterval
            ),
            proxy: proxy
        )
    }

    public func nativePassthroughRequest(
        rawBody: Data,
        method: String,
        upstreamPath: String,
        queryItems: [String: String] = [:],
        provider: ProviderConfig,
        apiKey: String?,
        headers: [String: String] = [:],
        timeoutInterval: TimeInterval = 600
    ) throws -> URLRequest {
        try nativePassthroughRequest(
            rawBody: rawBody,
            method: method,
            upstreamPath: upstreamPath,
            orderedQueryItems: queryItems.sorted(by: { $0.key < $1.key }).map {
                NativeQueryItem(name: $0.key, value: $0.value)
            },
            provider: provider,
            apiKey: apiKey,
            headers: headers,
            timeoutInterval: timeoutInterval
        )
    }

    public func nativePassthroughRequest(
        rawBody: Data,
        method: String,
        upstreamPath: String,
        orderedQueryItems: [NativeQueryItem],
        provider: ProviderConfig,
        apiKey: String?,
        headers: [String: String] = [:],
        timeoutInterval: TimeInterval = 600
    ) throws -> URLRequest {
        try validateCredential(provider: provider, apiKey: apiKey)

        let normalizedMethod = method.uppercased()
        let allowedMethods = ["GET", "POST", "PUT", "PATCH", "DELETE"]
        guard allowedMethods.contains(normalizedMethod) else {
            throw ProviderClientError.invalidRequest("原生透传不支持 \(method) 方法")
        }
        guard upstreamPath.hasPrefix("/"),
              !upstreamPath.hasPrefix("//"),
              !upstreamPath.contains("\\"),
              !upstreamPath.contains("\0"),
              !upstreamPath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == ".." }),
              URLComponents(string: upstreamPath)?.scheme == nil,
              URLComponents(string: upstreamPath)?.host == nil
        else {
            throw ProviderClientError.invalidRequest("upstream_path 必须是供应商主机内的绝对路径")
        }

        guard var base = URLComponents(string: provider.baseURL),
              base.scheme != nil,
              base.host != nil
        else {
            throw ProviderClientError.invalidBaseURL
        }
        base.path = upstreamPath
        base.query = nil
        base.fragment = nil
        base.queryItems = orderedQueryItems.map {
            URLQueryItem(name: $0.name, value: $0.value)
        }
        guard let url = base.url else {
            throw ProviderClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = normalizedMethod
        request.timeoutInterval = timeoutInterval
        if normalizedMethod != "GET" && normalizedMethod != "DELETE" {
            request.httpBody = rawBody
        } else if !rawBody.isEmpty {
            request.httpBody = rawBody
        }

        let blockedHeaders = Set([
            "authorization", "api-key", "x-api-key", "x-goog-api-key",
            "host", "content-length", "connection", "accept-encoding"
        ])
        for (name, value) in headers where !blockedHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        switch provider.kind {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            if request.value(forHTTPHeaderField: "anthropic-version") == nil {
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        case .gemini:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        default:
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    public func sendNativePassthrough(
        rawBody: Data,
        method: String,
        upstreamPath: String,
        queryItems: [String: String] = [:],
        provider: ProviderConfig,
        apiKey: String?,
        headers: [String: String] = [:],
        timeoutInterval: TimeInterval = 600,
        proxy: ProviderProxyEndpoint? = nil
    ) async throws -> ProviderResponse {
        try await sendNativePassthrough(
            rawBody: rawBody,
            method: method,
            upstreamPath: upstreamPath,
            orderedQueryItems: queryItems.sorted(by: { $0.key < $1.key }).map {
                NativeQueryItem(name: $0.key, value: $0.value)
            },
            provider: provider,
            apiKey: apiKey,
            headers: headers,
            timeoutInterval: timeoutInterval,
            proxy: proxy
        )
    }

    public func sendNativePassthrough(
        rawBody: Data,
        method: String,
        upstreamPath: String,
        orderedQueryItems: [NativeQueryItem],
        provider: ProviderConfig,
        apiKey: String?,
        headers: [String: String] = [:],
        timeoutInterval: TimeInterval = 600,
        proxy: ProviderProxyEndpoint? = nil
    ) async throws -> ProviderResponse {
        try await execute(
            nativePassthroughRequest(
                rawBody: rawBody,
                method: method,
                upstreamPath: upstreamPath,
                orderedQueryItems: orderedQueryItems,
                provider: provider,
                apiKey: apiKey,
                headers: headers,
                timeoutInterval: timeoutInterval
            ),
            proxy: proxy
        )
    }

    private func validateCredential(
        provider: ProviderConfig,
        apiKey: String?
    ) throws {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if provider.kind.needsAPIKey && key.isEmpty {
            throw ProviderClientError.missingAPIKey
        }
        if let message = ProviderCredentialPolicy.validationMessage(
            for: provider.kind,
            apiKey: key
        ) {
            throw ProviderClientError.credentialMismatch(message)
        }
    }

    private func sendUnifiedCompatible(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval,
        proxy: ProviderProxyEndpoint?
    ) async throws -> ProviderResponse {
        try await execute(chatRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        ), proxy: proxy)
    }

    private func sendAnthropic(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String,
        timeoutInterval: TimeInterval,
        proxy: ProviderProxyEndpoint?
    ) async throws -> ProviderResponse {
        let request = try chatRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        )
        let response = try await execute(request, proxy: proxy)
        guard (200..<300).contains(response.statusCode) else { return response }
        return try UnifiedProtocolBridge.normalizeAnthropic(response)
    }

    private func sendGemini(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String,
        timeoutInterval: TimeInterval,
        proxy: ProviderProxyEndpoint?
    ) async throws -> ProviderResponse {
        let request = try chatRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        )
        let response = try await execute(request, proxy: proxy)
        guard (200..<300).contains(response.statusCode) else { return response }
        return try UnifiedProtocolBridge.normalizeGemini(response, model: targetModel)
    }

    private func geminiEndpoint(
        for provider: ProviderConfig,
        model: String,
        streaming: Bool
    ) throws -> URL {
        try configuredURL(
            for: provider,
            kind: streaming ? .chatStream : .chat,
            model: model
        )
    }

    private func configuredURL(
        for provider: ProviderConfig,
        kind: ProviderEndpointKind,
        model: String? = nil,
        taskID: String? = nil
    ) throws -> URL {
        let modelKey = ProviderEndpointRecord.key(for: kind, model: model)
        let genericKey = ProviderEndpointRecord.key(for: kind)
        let recordedEndpoint = provider.endpointURLs[modelKey]
            ?? provider.endpointURLs[genericKey]
        if kind == .musicTask, recordedEndpoint?.isEmpty != false {
            throw ProviderClientError.invalidRequest("查询音乐任务需要保存精确的 musicTask 端点")
        }
        var configured = (recordedEndpoint ?? provider.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.contains("{model}") {
            guard let model, !model.isEmpty else {
                throw ProviderClientError.invalidRequest("模型端点模板需要模型名称")
            }
            configured = configured.replacingOccurrences(
                of: "{model}",
                with: encodedModelTemplateValue(model, providerKind: provider.kind)
            )
        }
        if (kind == .videoTask || kind == .musicTask), configured.contains("{task_id}") {
            guard let taskID, !taskID.isEmpty else {
                throw ProviderClientError.invalidRequest("查询生成任务需要 task_id")
            }
            var pathAllowed = CharacterSet.urlPathAllowed
            pathAllowed.remove(charactersIn: "/")
            let encoded = taskID.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? taskID
            configured = configured.replacingOccurrences(of: "{task_id}", with: encoded)
        }
        guard let components = URLComponents(string: configured),
              ProviderEndpointSecurity.isSafeConfigurationURL(components),
              let url = components.url
        else {
            throw ProviderClientError.invalidBaseURL
        }
        return url
    }

    private func encodedModelTemplateValue(
        _ model: String,
        providerKind: ProviderKind
    ) -> String {
        var raw = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if providerKind == .gemini {
            if raw.lowercased().hasPrefix("models/") {
                raw.removeFirst("models/".count)
            }
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%{}")
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
        return providerKind == .gemini ? "models/\(encoded)" : encoded
    }

    private func requestStreams(_ rawBody: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] else {
            return false
        }
        return object["stream"] as? Bool == true
    }

    private func execute(
        _ request: URLRequest,
        proxy: ProviderProxyEndpoint? = nil
    ) async throws -> ProviderResponse {
        let transport = if let proxy {
            await ProviderProxySessionPool.shared.session(for: proxy)
        } else {
            session
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderClientError.nonHTTPResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return ProviderResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    private func executeStream(
        _ request: URLRequest,
        proxy: ProviderProxyEndpoint? = nil
    ) async throws -> ProviderStreamResponse {
        let transport = if let proxy {
            await ProviderProxySessionPool.shared.session(for: proxy)
        } else {
            session
        }
        let (bytes, response) = try await transport.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderClientError.nonHTTPResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(4_096)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if chunk.count >= 4_096 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return ProviderStreamResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: stream
        )
    }

    private func normalizeAnthropic(_ response: ProviderResponse) throws -> ProviderResponse {
        let json = try jsonObject(from: response.body)
        let content = json["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined()
        let usage = json["usage"] as? [String: Any] ?? [:]
        let normalized: [String: Any] = [
            "id": json["id"] as? String ?? "chatcmpl-anthropic",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": json["model"] as? String ?? "",
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": text],
                "finish_reason": finishReason(json["stop_reason"] as? String)
            ]],
            "usage": [
                "prompt_tokens": usage["input_tokens"] as? Int ?? 0,
                "completion_tokens": usage["output_tokens"] as? Int ?? 0,
                "total_tokens": (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0)
            ]
        ]
        return ProviderResponse(
            statusCode: response.statusCode,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: normalized)
        )
    }

    private func normalizeGemini(_ response: ProviderResponse, model: String) throws -> ProviderResponse {
        let json = try jsonObject(from: response.body)
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let first = candidates.first ?? [:]
        let content = first["content"] as? [String: Any] ?? [:]
        let parts = content["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        let usage = json["usageMetadata"] as? [String: Any] ?? [:]
        let normalized: [String: Any] = [
            "id": "chatcmpl-gemini-\(UUID().uuidString.lowercased())",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": text],
                "finish_reason": "stop"
            ]],
            "usage": [
                "prompt_tokens": usage["promptTokenCount"] as? Int ?? 0,
                "completion_tokens": usage["candidatesTokenCount"] as? Int ?? 0,
                "total_tokens": usage["totalTokenCount"] as? Int ?? 0
            ]
        ]
        return ProviderResponse(
            statusCode: response.statusCode,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: normalized)
        )
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidRequest("JSON body 必须是对象")
        }
        return json
    }

    private func finishReason(_ reason: String?) -> String {
        switch reason {
        case "max_tokens": "length"
        case "tool_use": "tool_calls"
        default: "stop"
        }
    }
}
