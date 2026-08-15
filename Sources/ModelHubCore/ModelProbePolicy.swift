import Foundation

public enum ModelNativeProtocol: String, Codable, Equatable, Sendable {
    case imageGeneration
    case musicGeneration
    case videoGeneration
    case speech
    case transcription
    case embeddings
    case reranking
    case providerNative

    public var displayName: String {
        switch self {
        case .imageGeneration: "图像生成"
        case .musicGeneration: "音乐生成"
        case .videoGeneration: "视频生成"
        case .speech: "语音合成"
        case .transcription: "语音转录"
        case .embeddings: "向量"
        case .reranking: "重排"
        case .providerNative: "供应商专用"
        }
    }
}

public enum ModelProbeDisposition: Equatable, Sendable {
    case readyForChatProbe
    case configurationRequired
    case readyForNativeProtocol(ModelNativeProtocol)
}

public struct ModelProbePayload: Equatable, Sendable {
    public let body: Data
    public let contentType: String

    public init(body: Data, contentType: String) {
        self.body = body
        self.contentType = contentType
    }
}

public struct NativeResponseAssessment: Equatable, Sendable {
    public let availability: ModelAvailability
    public let isAccepted: Bool
    public let isPending: Bool
    public let gatewayStatusCode: Int
    public let detail: String

    public init(
        availability: ModelAvailability,
        isAccepted: Bool,
        isPending: Bool = false,
        gatewayStatusCode: Int,
        detail: String
    ) {
        self.availability = availability
        self.isAccepted = isAccepted
        self.isPending = isPending
        self.gatewayStatusCode = gatewayStatusCode
        self.detail = detail
    }
}

public enum ModelProbeRetryDecision: Equatable, Sendable {
    case stop
    case retry(after: TimeInterval)
}

public enum ModelProbeRetryPolicy {
    public static let maximumAttempts = 2

    public static func decision(
        statusCode: Int,
        headers: [String: String],
        attempt: Int
    ) -> ModelProbeRetryDecision {
        guard attempt < maximumAttempts,
              statusCode == 429 || (500...599).contains(statusCode)
        else { return .stop }
        if statusCode == 429,
           let raw = headers.first(where: {
               $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
           })?.value,
           let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .retry(after: min(max(seconds, 0.25), 30))
        }
        return .retry(after: statusCode == 429 ? 2 : 1)
    }

    public static func shouldRetryNetworkError(_ error: URLError, attempt: Int) -> Bool {
        guard attempt < maximumAttempts else { return false }
        return isTransientNetworkError(error)
    }

    public static func isTransientNetworkError(_ error: URLError) -> Bool {
        return [
            .timedOut, .networkConnectionLost, .cannotConnectToHost,
            .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed
        ].contains(error.code)
    }
}

public enum ModelTestBatchPolicy {
    public static let maximumSize = 3

    public static func nextSize(current: Int, statusCodes: [Int]) -> Int {
        if statusCodes.contains(429) { return 1 }
        let allSuccessful = statusCodes.count >= 3
            && statusCodes.allSatisfy { (200..<300).contains($0) }
        if allSuccessful { return min(maximumSize, current + 1) }
        return min(max(current, 1), maximumSize)
    }
}

public enum ModelProbePolicy {
    public static func chatProbeBody(
        provider: ProviderConfig,
        model: String
    ) -> Data? {
        let normalizedModel = model.lowercased()
        let outputTokenCount = normalizedModel == "gpt-5.4-pro"
            || normalizedModel.hasPrefix("gpt-5.4-pro-")
            ? 16
            : 1
        var object: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "只回复 OK"]],
            "stream": false,
            "max_tokens": outputTokenCount
        ]
        if shouldDisableThinkingForNonStreamingProbe(provider: provider, model: model) {
            object["enable_thinking"] = false
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    public static func nativeOperation(for nativeProtocol: ModelNativeProtocol) -> NativeAPIOperation? {
        switch nativeProtocol {
        case .imageGeneration: .imageGeneration
        case .musicGeneration: .musicGeneration
        case .videoGeneration: .videoGeneration
        case .speech: .speech
        case .transcription: .transcription
        case .embeddings: .embeddings
        case .reranking: .reranking
        case .providerNative: nil
        }
    }

    public static func shouldSkipNativeProbe(
        status: ModelAvailability?,
        nativeProtocol: ModelNativeProtocol,
        allowNativeProbe: Bool
    ) -> Bool {
        status?.isQuarantined == true && !allowNativeProbe
    }

    public static func nativeProbeBody(
        for nativeProtocol: ModelNativeProtocol,
        model: String
    ) -> Data? {
        nativeProbePayload(for: nativeProtocol, model: model)?.body
    }

    public static func nativeProbePayload(
        for nativeProtocol: ModelNativeProtocol,
        model: String
    ) -> ModelProbePayload? {
        let object: [String: Any]
        switch nativeProtocol {
        case .imageGeneration:
            object = ["prompt": "ModelHub connection test", "n": 1]
        case .musicGeneration:
            // This minimal body is sent only after explicit confirmation that
            // the provider may bill a real protocol probe.
            object = [
                "prompt": "ModelHub connection test",
                "duration": 5,
                "instrumental": true
            ]
        case .videoGeneration:
            // Use the documented Seedance 2.0 minimum that is accepted across the
            // standard and fast variants. Keep resolution and audio at their
            // lowest-cost settings because this probe can create a billable task.
            object = [
                "prompt": "ModelHub connection test",
                "duration": 5,
                "resolution": "480p",
                "size": "16:9",
                "generate_audio": false
            ]
        case .speech:
            object = [
                "input": "ModelHub connection test",
                "voice": MiniMaxNativeAdapter.speechModelIDs.contains(model)
                    ? "male-qn-qingse"
                    : "alloy"
            ]
        case .embeddings:
            if model.lowercased().contains("vl-embedding") {
                object = [
                    "input": [
                        "contents": [["text": "ModelHub connection test"]]
                    ]
                ]
            } else {
                object = ["input": "ModelHub connection test"]
            }
        case .reranking:
            object = [
                "query": "ModelHub connection test",
                "documents": ["ModelHub connection test"]
            ]
        case .transcription:
            return transcriptionProbePayload(model: model)
        case .providerNative:
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return ModelProbePayload(body: data, contentType: "application/json")
    }

    public static func nativeProbeUnavailableReason(
        provider: ProviderConfig,
        model _: String,
        nativeProtocol: ModelNativeProtocol
    ) -> String {
        if nativeProtocol == .providerNative {
            if MiniMaxNativeAdapter.isMiniMax(provider) {
                return "MiniMax 原生模型 ID 与当前官方精确枚举不匹配；已隔离且不会按聊天协议调用，请从官方文档复制完整模型 ID。"
            }
            let hostname = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
            let isBailian = provider.kind.isBailian
                && (hostname == BailianEndpointPolicy.payAsYouGoHost
                    || hostname == BailianEndpointPolicy.tokenPlanHost
                    || provider.name.contains("百炼")
                    || provider.name.contains("千问AI平台"))
            if isBailian {
                return "千问AI平台部署/工作流模型需要部署代码、素材或专用参数；不会作为聊天模型请求，请在 API 调试中按供应商文档验证。"
            }
            return "供应商专用模型需要素材或专用参数；不会作为聊天模型请求，请在 API 调试中按供应商文档验证。"
        }
        return "\(nativeProtocol.displayName)尚未通过真实协议验证，已隔离（未自动发起可能计费的请求）"
    }

    public static func videoTaskID(in response: ProviderResponse) -> String? {
        guard (200..<300).contains(response.statusCode),
              let root = try? JSONSerialization.jsonObject(with: response.body)
        else { return nil }

        let candidates: [Any?]
        if let object = root as? [String: Any] {
            if let baseResponse = object["base_resp"] as? [String: Any],
               let statusCode = integer(baseResponse["status_code"]),
               statusCode != 0 {
                return nil
            }
            if let businessCode = object["code"] as? NSNumber,
               !(200..<300).contains(businessCode.intValue) {
                return nil
            }
            let dataObject = object["data"] as? [String: Any]
            let firstDataObject = (object["data"] as? [[String: Any]])?.first
            candidates = [
                object["task_id"], object["taskId"], object["id"],
                dataObject?["task_id"], dataObject?["taskId"], dataObject?["id"],
                firstDataObject?["task_id"], firstDataObject?["taskId"], firstDataObject?["id"]
            ]
        } else {
            return nil
        }

        return candidates.compactMap { value -> String? in
            guard let taskID = value as? String,
                  !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return taskID
        }.first
    }

    public static func nativeResponseAssessment(
        _ response: ProviderResponse,
        provider: ProviderConfig,
        operation: NativeAPIOperation,
        model: String? = nil
    ) -> NativeResponseAssessment {
        guard (200..<300).contains(response.statusCode) else {
            if let documentedFailure = documentedQianwenConfigurationFailure(
                response,
                provider: provider,
                operation: operation,
                model: model
            ) {
                return documentedFailure
            }
            return transportFailure(response)
        }
        guard MiniMaxNativeAdapter.isMiniMax(provider) else {
            return transportSuccess(response.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body)
                as? [String: Any]
        else {
            return NativeResponseAssessment(
                availability: .unavailable,
                isAccepted: false,
                gatewayStatusCode: 502,
                detail: "MiniMax 响应不是有效 JSON"
            )
        }
        let baseAssessment = miniMaxBaseAssessment(
            object,
            transportStatusCode: response.statusCode
        )
        guard baseAssessment.isAccepted else { return baseAssessment }

        switch operation {
        case .videoGeneration:
            guard videoTaskID(in: response) != nil else {
                return NativeResponseAssessment(
                    availability: .unavailable,
                    isAccepted: false,
                    gatewayStatusCode: 502,
                    detail: "MiniMax 视频任务未返回 task_id"
                )
            }
            return acceptedMiniMax(detail: "MiniMax 视频任务已提交")
        case .videoTask:
            let status = (object["status"] as? String)?.lowercased()
            switch status {
            case "preparing", "queueing", "processing":
                return acceptedMiniMax(detail: "MiniMax 视频任务处理中", pending: true)
            case "success":
                return acceptedMiniMax(detail: "MiniMax 视频任务完成")
            case "fail", "failed":
                return NativeResponseAssessment(
                    availability: .unavailable,
                    isAccepted: false,
                    gatewayStatusCode: 502,
                    detail: "MiniMax 视频任务失败"
                )
            default:
                return NativeResponseAssessment(
                    availability: .unavailable,
                    isAccepted: false,
                    gatewayStatusCode: 502,
                    detail: "MiniMax 视频任务返回未知业务状态"
                )
            }
        case .musicGeneration, .speech:
            guard let data = object["data"] as? [String: Any],
                  let status = integer(data["status"]),
                  status == 1 || status == 2
            else {
                return NativeResponseAssessment(
                    availability: .unavailable,
                    isAccepted: false,
                    gatewayStatusCode: 502,
                    detail: "MiniMax 音频响应缺少有效 data.status"
                )
            }
            return acceptedMiniMax(
                detail: status == 1 ? "MiniMax 音频生成中" : "MiniMax 音频生成完成",
                pending: status == 1
            )
        case .imageGeneration:
            let metadata = object["metadata"] as? [String: Any]
            let successCount = integer(metadata?["success_count"])
            let data = object["data"] as? [String: Any]
            let imageURLs = data?["image_urls"] as? [Any]
            let images = data?["image_base64"] as? [Any]
            guard successCount.map({ $0 > 0 }) == true
                    || imageURLs?.isEmpty == false
                    || images?.isEmpty == false
            else {
                return NativeResponseAssessment(
                    availability: .unavailable,
                    isAccepted: false,
                    gatewayStatusCode: 502,
                    detail: "MiniMax 图片响应未包含成功生成结果"
                )
            }
            return acceptedMiniMax(detail: "MiniMax 图片生成完成")
        case .musicTask, .transcription, .embeddings, .reranking:
            return acceptedMiniMax(detail: "MiniMax 业务请求成功")
        }
    }

    /// Applies MiniMax's `base_resp.status_code` contract to chat and native
    /// responses. MiniMax can report a business failure inside HTTP 200, so
    /// transport success alone is never enough for routing or health checks.
    public static func providerResponseAssessment(
        _ response: ProviderResponse,
        provider: ProviderConfig
    ) -> NativeResponseAssessment {
        guard (200..<300).contains(response.statusCode) else {
            return transportFailure(response)
        }
        guard MiniMaxNativeAdapter.isMiniMax(provider) else {
            return transportSuccess(response.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body)
                as? [String: Any]
        else {
            return NativeResponseAssessment(
                availability: .unavailable,
                isAccepted: false,
                gatewayStatusCode: 502,
                detail: "MiniMax 响应缺少 base_resp.status_code"
            )
        }
        return miniMaxBaseAssessment(object, transportStatusCode: response.statusCode)
    }

    private static func miniMaxBaseAssessment(
        _ object: [String: Any],
        transportStatusCode: Int
    ) -> NativeResponseAssessment {
        guard let baseResponse = object["base_resp"] as? [String: Any],
              let businessCode = integer(baseResponse["status_code"])
        else {
            return NativeResponseAssessment(
                availability: .unavailable,
                isAccepted: false,
                gatewayStatusCode: 502,
                detail: "MiniMax 响应缺少 base_resp.status_code"
            )
        }
        guard businessCode != 0 else {
            return NativeResponseAssessment(
                availability: .available,
                isAccepted: true,
                gatewayStatusCode: transportStatusCode,
                detail: "MiniMax 业务请求成功"
            )
        }
        return miniMaxBusinessFailure(code: businessCode)
    }

    private static func transportSuccess(_ statusCode: Int) -> NativeResponseAssessment {
        NativeResponseAssessment(
            availability: .available,
            isAccepted: true,
            gatewayStatusCode: statusCode,
            detail: "HTTP \(statusCode)"
        )
    }

    private static func transportFailure(_ response: ProviderResponse) -> NativeResponseAssessment {
        let detail = ProviderErrorDiagnostics.summary(for: response)
        let normalizedDetail = detail.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let isWrappedParameterValidationFailure = normalizedDetail.contains(
            "integer_below_min_value"
        ) || normalizedDetail.contains("integer_above_max_value")
        let availability: ModelAvailability = if normalizedDetail.contains("access_denied")
            || normalizedDetail.contains("permission_denied")
            || normalizedDetail.contains("insufficient permission")
        {
            .configurationRequired
        } else if isWrappedParameterValidationFailure {
            .unavailable
        } else {
            ModelAvailability(statusCode: response.statusCode)
        }
        return NativeResponseAssessment(
            availability: availability,
            isAccepted: false,
            gatewayStatusCode: isWrappedParameterValidationFailure ? 400 : response.statusCode,
            detail: detail
        )
    }

    private static func shouldDisableThinkingForNonStreamingProbe(
        provider: ProviderConfig,
        model: String
    ) -> Bool {
        guard provider.kind.isBailian else { return false }
        let name = model.lowercased()
        guard name.hasPrefix("qwen3-") else { return false }
        return !name.contains("thinking")
            && !name.hasPrefix("qwen3-next-")
    }

    private static func documentedQianwenConfigurationFailure(
        _ response: ProviderResponse,
        provider: ProviderConfig,
        operation: NativeAPIOperation,
        model: String?
    ) -> NativeResponseAssessment? {
        guard response.statusCode == 404,
              provider.kind.isBailian,
              let model,
              let details = QianwenModelCapabilityRegistry.details(for: model)
        else { return nil }

        let isDocumentedForOperation = switch operation {
        case .imageGeneration:
            details.outputModalities.contains(.image)
        case .videoGeneration:
            details.outputModalities.contains(.video)
        case .speech:
            details.outputModalities.contains(.audio)
        case .embeddings:
            details.outputModalities.contains(.vector)
        case .musicGeneration, .musicTask, .videoTask, .transcription, .reranking:
            false
        }
        guard isDocumentedForOperation else { return nil }

        let upstream = ProviderErrorDiagnostics.summary(for: response)
        return NativeResponseAssessment(
            availability: .configurationRequired,
            isAccepted: false,
            gatewayStatusCode: response.statusCode,
            detail: "\(upstream) · 官方能力目录确认支持该模型；当前地域、业务空间、推理端点与 API Key 组合未找到可调用实例，请确认该空间已开通模型并优先使用同地域业务空间专属域名"
        )
    }

    private static func acceptedMiniMax(
        detail: String,
        pending: Bool = false
    ) -> NativeResponseAssessment {
        NativeResponseAssessment(
            availability: .available,
            isAccepted: true,
            isPending: pending,
            gatewayStatusCode: 200,
            detail: detail
        )
    }

    private static func miniMaxBusinessFailure(code: Int) -> NativeResponseAssessment {
        let availability: ModelAvailability
        let statusCode: Int
        let reason: String
        switch code {
        case 1004, 2049:
            availability = .configurationRequired
            statusCode = 401
            reason = "鉴权失败"
        case 1002, 1039:
            availability = .unavailable
            statusCode = 429
            reason = "触发限流"
        case 1008:
            availability = .unavailable
            statusCode = 429
            reason = "账户余额不足"
        case 1026, 1027, 1042:
            availability = .unavailable
            statusCode = 422
            reason = "内容安全或字符校验失败"
        case 2013:
            availability = .unavailable
            statusCode = 400
            reason = "请求参数不符合 MiniMax 协议"
        default:
            availability = .unavailable
            statusCode = 502
            reason = "供应商业务错误"
        }
        return NativeResponseAssessment(
            availability: availability,
            isAccepted: false,
            gatewayStatusCode: statusCode,
            detail: "MiniMax \(reason)（业务码 \(code)）"
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    public static func disposition(
        provider: ProviderConfig,
        model: String,
        hasAPIKey: Bool
    ) -> ModelProbeDisposition {
        if provider.kind.needsAPIKey && !hasAPIKey {
            return .configurationRequired
        }
        if let nativeProtocol = nativeProtocol(provider: provider, model: model) {
            return .readyForNativeProtocol(nativeProtocol)
        }
        return .readyForChatProbe
    }

    public static func nativeProtocol(
        provider: ProviderConfig,
        model: String
    ) -> ModelNativeProtocol? {
        let providerName = provider.name.lowercased()
        let name = model.lowercased()

        if MiniMaxNativeAdapter.isMiniMax(provider) {
            let exactModel = MiniMaxNativeAdapter.canonicalModelID(forStoredModelID: model)
            if let exact = MiniMaxNativeAdapter.nativeProtocol(forExactModelID: exactModel) {
                return exact
            }
            return MiniMaxNativeAdapter.resemblesNativeModelID(model) ? .providerNative : nil
        }

        // Token Plan exposes its own product-scoped model capabilities. Never
        // derive a pay-as-you-go DashScope native endpoint for it. Models that
        // look like native generation models stay quarantined until the user
        // configures and verifies the provider-specific endpoint explicitly.
        if provider.kind.isBailianTokenPlan,
           isLikelyNativeGenerationModel(name)
        {
            return .providerNative
        }

        let musicEndpointKeys = [
            ProviderEndpointRecord.key(for: .musicGeneration, model: model),
            ProviderEndpointRecord.key(for: .musicGeneration)
        ]
        if isMusicModel(name),
           musicEndpointKeys.contains(where: { provider.endpointURLs[$0]?.isEmpty == false })
        {
            return .musicGeneration
        }

        if isBailian(provider), name == "wanx-v1" {
            return .imageGeneration
        }
        if isProviderNativeModel(provider: provider, name: name) {
            return .providerNative
        }
        if providerName.contains("tts") {
            return .speech
        }
        if name.contains("rerank") {
            return .reranking
        }
        if name.contains("embedding") {
            return .embeddings
        }
        if name.contains("whisper") || name.contains("transcrib") {
            return .transcription
        }
        if isSpeechModel(name) {
            return .speech
        }
        if isImageModel(name) {
            return .imageGeneration
        }
        if isVideoModel(name) {
            return .videoGeneration
        }
        if isMusicModel(name) {
            return .musicGeneration
        }
        return nil
    }

    private static func isProviderNativeModel(
        provider: ProviderConfig,
        name: String
    ) -> Bool {
        let providerName = provider.name.lowercased()
        let hostname = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
        let isYunwu = providerName.contains("云雾") || hostname.contains("yunwu.ai")
        let isBailian = provider.kind.isBailian
            || providerName.contains("百炼")
            || providerName.contains("千问ai平台")
            || hostname == BailianEndpointPolicy.payAsYouGoHost
            || hostname == BailianEndpointPolicy.tokenPlanHost

        if isYunwu {
            let exactPrefixes = [
                "mj_", "suno_", "kling-", "pixverse-", "happyhorse-",
                "hailuo-", "vidu", "wan2."
            ]
            let actionMarkers = [
                "-i2v", "-t2v", "-r2v", "lipsync", "sound-effect",
                "voice-design", "music-open"
            ]
            if exactPrefixes.contains(where: { name.hasPrefix($0) })
                || actionMarkers.contains(where: { name.contains($0) })
            {
                return true
            }
        }

        if isBailian {
            return name.contains("voice-design")
                || name.contains("voice-clone")
                || name.contains("realtime")
                || name.hasPrefix("wanx-")
                || name.hasPrefix("emo")
                || name.hasPrefix("animate-anyone")
        }
        return false
    }

    private static func isBailian(_ provider: ProviderConfig) -> Bool {
        let hostname = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
        return provider.kind.isBailian
            || provider.name.lowercased().contains("百炼")
            || provider.name.lowercased().contains("千问ai平台")
            || hostname == BailianEndpointPolicy.payAsYouGoHost
            || hostname == BailianEndpointPolicy.tokenPlanHost
    }

    private static func isLikelyNativeGenerationModel(_ name: String) -> Bool {
        isSpeechModel(name)
            || isImageModel(name)
            || isVideoModel(name)
            || isMusicModel(name)
            || name.contains("embedding")
            || name.contains("rerank")
            || name.contains("whisper")
            || name.contains("transcrib")
            || name.contains("voice-design")
            || name.contains("voice-clone")
            || name.contains("realtime")
    }

    private static func isSpeechModel(_ name: String) -> Bool {
        let markers = [
            "tts", "speech-", "/speech"
        ]
        return markers.contains { name.contains($0) }
    }

    private static func isImageModel(_ name: String) -> Bool {
        let markers = [
            "image", "seedream", "flux", "dall-e", "z-image"
        ]
        return markers.contains { name.contains($0) }
    }

    private static func isVideoModel(_ name: String) -> Bool {
        let markers = [
            "seedance", "video", "sora", "veo", "-t2v", "-i2v", "-r2v"
        ]
        if markers.contains(where: { name.contains($0) }) {
            return true
        }
        return false
    }

    private static func isMusicModel(_ name: String) -> Bool {
        let markers = [
            "music", "suno", "udio", "song", "musicgen", "ace-step",
            "audio-generation"
        ]
        return markers.contains { name.contains($0) }
    }

    private static func transcriptionProbePayload(model: String) -> ModelProbePayload {
        let boundary = "ModelHubProbeBoundary"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        body.append(Data("\(model)\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"modelhub-probe.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(silentWAV())
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return ModelProbePayload(
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = 800
        let dataSize = sampleCount * 2
        var data = Data("RIFF".utf8)
        appendLittleEndian(36 + dataSize, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * 2, to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(dataSize, to: &data)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

public enum ModelHealthMigration {
    public static func normalize(
        records: [ModelHealthRecord],
        providers: [ProviderConfig]
    ) -> [ModelHealthRecord] {
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        var normalized = records.compactMap { original -> ModelHealthRecord? in
            guard let provider = providersByID[original.providerID],
                  provider.models.contains(where: {
                      $0.trimmingCharacters(in: .whitespacesAndNewlines)
                          .caseInsensitiveCompare(original.model.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          )) == .orderedSame
                  })
            else { return nil }

            var record = original
            if original.detail == "未配置 API Key" {
                record.status = .configurationRequired
                record.latencyMilliseconds = nil
                record.statusCode = nil
                record.detail = "需要配置或更新 API Key（旧结果已纠正）"
                return record
            }

            if original.statusCode == 401 || original.statusCode == 403 {
                record.status = .configurationRequired
                return record
            }

            if original.status == .unavailable,
               let cause = original.quarantineCause,
               [.missingCredential, .invalidCredential, .insufficientPermission]
                .contains(cause)
            {
                record.status = .configurationRequired
                return record
            }

            if ModelHealthRecoveryPolicy.isRecoveredPendingVerification(original) {
                return original
            }

            if ModelHealthRecoveryPolicy.isDeferredNativePendingVerification(original) {
                return original
            }

            if let nativeProtocol = ModelProbePolicy.nativeProtocol(
                provider: provider,
                model: original.model
            ) {
                if original.status == .available
                    || original.status == .configurationRequired
                    || original.status == .unsupported
                    || original.detail.hasPrefix("原生")
                {
                    return original
                }
                record.status = .unavailable
                record.latencyMilliseconds = nil
                record.statusCode = nil
                record.detail = ModelProbePolicy.nativeProbeUnavailableReason(
                    provider: provider,
                    model: original.model,
                    nativeProtocol: nativeProtocol
                )
                return record
            }

            if original.status == .unknown {
                record.status = .unavailable
                record.latencyMilliseconds = nil
                record.statusCode = nil
                record.detail = "尚未完成在线验证，已隔离"
            }
            return record
        }

        var recordedKeys = Set(normalized.map {
            healthKey(providerID: $0.providerID, model: $0.model)
        })
        for provider in providers {
            for model in provider.models {
                let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedModel.isEmpty else { continue }
                let key = healthKey(providerID: provider.id, model: trimmedModel)
                guard recordedKeys.insert(key).inserted else { continue }

                let detail: String
                if let nativeProtocol = ModelProbePolicy.nativeProtocol(
                    provider: provider,
                    model: trimmedModel
                ) {
                    detail = ModelProbePolicy.nativeProbeUnavailableReason(
                        provider: provider,
                        model: trimmedModel,
                        nativeProtocol: nativeProtocol
                    )
                } else {
                    detail = "尚未完成在线验证，已隔离"
                }
                normalized.append(
                    ModelHealthRecord(
                        providerID: provider.id,
                        model: trimmedModel,
                        status: .unavailable,
                        detail: detail
                    )
                )
            }
        }
        return normalized
    }

    private static func healthKey(providerID: UUID, model: String) -> String {
        "\(providerID.uuidString.lowercased())/\(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}
