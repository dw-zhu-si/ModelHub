import Foundation

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
    case invalidRequest(String)
    case nonHTTPResponse

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "供应商 Base URL 无效"
        case .missingAPIKey: "供应商 API Key 未配置"
        case .invalidRequest(let detail): "请求无法转换：\(detail)"
        case .nonHTTPResponse: "供应商返回了非 HTTP 响应"
        }
    }

    public var isInvalidClientRequest: Bool {
        if case .invalidRequest = self { return true }
        return false
    }
}

public struct ProviderClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 180
    ) async throws -> ProviderResponse {
        if provider.kind.needsAPIKey && (apiKey?.isEmpty != false) {
            throw ProviderClientError.missingAPIKey
        }

        switch provider.kind {
        case .anthropic:
            return try await sendAnthropic(
                rawBody: rawBody,
                targetModel: targetModel,
                provider: provider,
                apiKey: apiKey ?? "",
                timeoutInterval: timeoutInterval
            )
        case .gemini:
            return try await sendGemini(
                rawBody: rawBody,
                targetModel: targetModel,
                provider: provider,
                apiKey: apiKey ?? "",
                timeoutInterval: timeoutInterval
            )
        default:
            return try await sendOpenAICompatible(
                rawBody: rawBody,
                targetModel: targetModel,
                provider: provider,
                apiKey: apiKey,
                timeoutInterval: timeoutInterval
            )
        }
    }

    public func endpoint(for provider: ProviderConfig, model: String) throws -> URL {
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty else { throw ProviderClientError.invalidBaseURL }

        switch provider.kind {
        case .anthropic:
            guard let url = URL(string: "\(base)/v1/messages") else {
                throw ProviderClientError.invalidBaseURL
            }
            return url
        case .gemini:
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            guard let url = URL(string: "\(base)/v1beta/models/\(encodedModel):generateContent") else {
                throw ProviderClientError.invalidBaseURL
            }
            return url
        case .azureOpenAI:
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            let version = provider.apiVersion.isEmpty ? "2024-10-21" : provider.apiVersion
            guard let url = URL(string: "\(base)/openai/deployments/\(encodedModel)/chat/completions?api-version=\(version)") else {
                throw ProviderClientError.invalidBaseURL
            }
            return url
        default:
            let hasVersionedAPIPath = ["/v1", "/v2", "/v3"].contains {
                base.hasSuffix($0)
            }
            let suffix = hasVersionedAPIPath ? "/chat/completions" : "/v1/chat/completions"
            guard let url = URL(string: base + suffix) else {
                throw ProviderClientError.invalidBaseURL
            }
            return url
        }
    }

    public func responsesEndpoint(for provider: ProviderConfig) throws -> URL {
        guard provider.kind.usesOpenAIProtocol, provider.kind != .azureOpenAI else {
            throw ProviderClientError.invalidRequest("该供应商暂不支持 Responses API 透传")
        }
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty else { throw ProviderClientError.invalidBaseURL }
        let root = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
        guard let url = URL(string: root + "/v1/responses") else {
            throw ProviderClientError.invalidBaseURL
        }
        return url
    }

    public func responsesRequest(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 180
    ) throws -> URLRequest {
        if provider.kind.needsAPIKey && (apiKey?.isEmpty != false) {
            throw ProviderClientError.missingAPIKey
        }
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
        if provider.kind.needsAPIKey && (apiKey?.isEmpty != false) {
            throw ProviderClientError.missingAPIKey
        }
        switch provider.kind {
        case .anthropic:
            var request = URLRequest(url: try endpoint(for: provider, model: targetModel))
            request.httpMethod = "POST"
            request.httpBody = try OpenAIProtocolBridge.anthropicBody(
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
            request.httpBody = try OpenAIProtocolBridge.geminiBody(from: rawBody)
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
        if provider.kind == .azureOpenAI {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        } else if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    public func startChatStream(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?
    ) async throws -> ProviderStreamResponse {
        let response = try await executeStream(chatRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey
        ))
        guard (200..<300).contains(response.statusCode) else { return response }
        switch provider.kind {
        case .anthropic:
            return OpenAIProtocolBridge.anthropicStream(response, model: targetModel)
        case .gemini:
            return OpenAIProtocolBridge.geminiStream(response, model: targetModel)
        default:
            return response
        }
    }

    public func startResponsesStream(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?
    ) async throws -> ProviderStreamResponse {
        try await executeStream(responsesRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey
        ))
    }

    public func sendResponses(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 180
    ) async throws -> ProviderResponse {
        try await execute(responsesRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        ))
    }

    public func nativeEndpoint(
        for provider: ProviderConfig,
        model: String,
        operation: NativeAPIOperation,
        taskID: String? = nil
    ) throws -> URL {
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard var components = URLComponents(string: base),
              components.scheme != nil,
              components.host != nil
        else {
            throw ProviderClientError.invalidBaseURL
        }

        let providerName = provider.name.lowercased()
        let hostname = components.host?.lowercased() ?? ""
        let isAPIMart = hostname.contains("apimart.ai") || providerName.contains("apimart")
        let isAgnes = hostname.contains("agnes-ai.com") || providerName.contains("agnes")
        let isBailian = hostname.contains("dashscope.aliyuncs.com")
            || providerName.contains("百炼")

        if isBailian {
            components.path = ""
        } else if components.path.hasSuffix("/v1") {
            components.path.removeLast(3)
        }
        components.query = nil
        components.fragment = nil
        guard let root = components.url?.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) else {
            throw ProviderClientError.invalidBaseURL
        }

        let suffix: String
        switch operation {
        case .imageGeneration:
            suffix = "/v1/images/generations"
        case .videoGeneration:
            suffix = isAgnes ? "/v1/videos" : "/v1/videos/generations"
        case .videoTask:
            guard let taskID, !taskID.isEmpty else {
                throw ProviderClientError.invalidRequest("查询视频任务需要 task_id")
            }
            var pathAllowed = CharacterSet.urlPathAllowed
            pathAllowed.remove(charactersIn: "/")
            let encoded = taskID.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? taskID
            suffix = isAPIMart ? "/v1/tasks/\(encoded)" : "/v1/videos/\(encoded)"
        case .speech:
            if isBailian {
                let lowered = model.lowercased()
                if lowered.hasPrefix("cosyvoice") || lowered.hasPrefix("qwen-audio-") {
                    suffix = "/api/v1/services/audio/tts/SpeechSynthesizer"
                } else {
                    suffix = "/api/v1/services/aigc/multimodal-generation/generation"
                }
            } else {
                suffix = "/v1/audio/speech"
            }
        case .transcription:
            suffix = "/v1/audio/transcriptions"
        case .embeddings:
            suffix = "/v1/embeddings"
        case .reranking:
            suffix = "/v1/rerank"
        }

        guard let url = URL(string: root + suffix) else {
            throw ProviderClientError.invalidBaseURL
        }
        return url
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
        if provider.kind.needsAPIKey && (apiKey?.isEmpty != false) {
            throw ProviderClientError.missingAPIKey
        }

        var request = URLRequest(
            url: try nativeEndpoint(
                for: provider,
                model: targetModel,
                operation: operation,
                taskID: taskID
            )
        )
        request.httpMethod = operation == .videoTask ? "GET" : "POST"
        request.timeoutInterval = timeoutInterval

        if operation != .videoTask {
            if contentType.lowercased().contains("application/json") {
                var json = try jsonObject(from: rawBody)
                json["model"] = targetModel
                if operation == .speech && isBailian(provider) {
                    json = normalizeBailianSpeechJSON(json, model: targetModel)
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

        if provider.kind == .azureOpenAI {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        } else if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func isBailian(_ provider: ProviderConfig) -> Bool {
        provider.baseURL.lowercased().contains("dashscope.aliyuncs.com")
            || provider.name.contains("百炼")
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
        timeoutInterval: TimeInterval = 600
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
            )
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
        if provider.kind.needsAPIKey && (apiKey?.isEmpty != false) {
            throw ProviderClientError.missingAPIKey
        }

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
        case .azureOpenAI:
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
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
        timeoutInterval: TimeInterval = 600
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
            timeoutInterval: timeoutInterval
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
        timeoutInterval: TimeInterval = 600
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
            )
        )
    }

    private func sendOpenAICompatible(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval
    ) async throws -> ProviderResponse {
        try await execute(chatRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        ))
    }

    private func sendAnthropic(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String,
        timeoutInterval: TimeInterval
    ) async throws -> ProviderResponse {
        let request = try chatRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        )
        let response = try await execute(request)
        guard (200..<300).contains(response.statusCode) else { return response }
        return try OpenAIProtocolBridge.normalizeAnthropic(response)
    }

    private func sendGemini(
        rawBody: Data,
        targetModel: String,
        provider: ProviderConfig,
        apiKey: String,
        timeoutInterval: TimeInterval
    ) async throws -> ProviderResponse {
        let request = try chatRequest(
            rawBody: rawBody,
            targetModel: targetModel,
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        )
        let response = try await execute(request)
        guard (200..<300).contains(response.statusCode) else { return response }
        return try OpenAIProtocolBridge.normalizeGemini(response, model: targetModel)
    }

    private func geminiEndpoint(
        for provider: ProviderConfig,
        model: String,
        streaming: Bool
    ) throws -> URL {
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let operation = streaming ? "streamGenerateContent" : "generateContent"
        guard let url = URL(string: "\(base)/v1beta/models/\(encodedModel):\(operation)") else {
            throw ProviderClientError.invalidBaseURL
        }
        return url
    }

    private func requestStreams(_ rawBody: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] else {
            return false
        }
        return object["stream"] as? Bool == true
    }

    private func execute(_ request: URLRequest) async throws -> ProviderResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderClientError.nonHTTPResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return ProviderResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    private func executeStream(_ request: URLRequest) async throws -> ProviderStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
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
