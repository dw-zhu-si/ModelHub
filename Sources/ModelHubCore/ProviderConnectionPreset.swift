import Foundation

public enum ProviderConnectionPresetApplicationMode: Sendable {
    case fillMissing
    case replaceURLs
}

public struct ProviderConnectionPreset: Equatable, Sendable {
    public let kind: ProviderKind
    public let baseURL: String
    public let endpointURLs: [String: String]
    public let documentationURL: String

    public init(
        kind: ProviderKind,
        baseURL: String,
        endpointURLs: [String: String],
        documentationURL: String
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.endpointURLs = endpointURLs
        self.documentationURL = documentationURL
    }

    public func applying(
        to provider: ProviderConfig,
        mode: ProviderConnectionPresetApplicationMode
    ) -> ProviderConfig {
        var updated = provider
        updated.kind = kind
        switch mode {
        case .replaceURLs:
            updated.baseURL = baseURL
            updated.endpointURLs = endpointURLs
        case .fillMissing:
            let trimmedBase = updated.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedBase.isEmpty || trimmedBase == baseURL else { return updated }
            if trimmedBase.isEmpty { updated.baseURL = baseURL }
            for (key, value) in endpointURLs
                where updated.endpointURLs[key]?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty != false
            {
                updated.endpointURLs[key] = value
            }
        }
        return updated
    }
}

/// Exact built-in connection presets. These values are never applied to the
/// generic compatible provider, and a user-entered custom Base URL is never
/// silently replaced or mixed with a vendor preset when an editor opens.
public enum ProviderConnectionPresets {
    public static func preset(for kind: ProviderKind) -> ProviderConnectionPreset? {
        let chat = ProviderEndpointRecord.key(for: .chat)
        let chatStream = ProviderEndpointRecord.key(for: .chatStream)
        let catalog = ProviderEndpointRecord.key(for: .modelCatalog)

        func make(
            baseURL: String,
            chatURL: String,
            catalogURL: String? = nil,
            extras: [ProviderEndpointKind: String] = [:],
            documentationURL: String
        ) -> ProviderConnectionPreset {
            var endpoints = [chat: chatURL, chatStream: chatURL]
            if let catalogURL { endpoints[catalog] = catalogURL }
            for (endpointKind, url) in extras {
                endpoints[ProviderEndpointRecord.key(for: endpointKind)] = url
            }
            return ProviderConnectionPreset(
                kind: kind,
                baseURL: baseURL,
                endpointURLs: endpoints,
                documentationURL: documentationURL
            )
        }

        switch kind {
        case .anthropic:
            return make(
                baseURL: "https://api.anthropic.com",
                chatURL: "https://api.anthropic.com/v1/messages",
                catalogURL: "https://api.anthropic.com/v1/models?limit=1000",
                documentationURL: "https://docs.anthropic.com/en/api/messages"
            )
        case .gemini:
            return make(
                baseURL: "https://generativelanguage.googleapis.com",
                chatURL: "https://generativelanguage.googleapis.com/v1beta/{model}:generateContent",
                catalogURL: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000",
                documentationURL: "https://ai.google.dev/api/generate-content"
            ).replacingEndpoint(
                .chatStream,
                with: "https://generativelanguage.googleapis.com/v1beta/{model}:streamGenerateContent"
            )
        case .deepSeek:
            return make(
                baseURL: "https://api.deepseek.com",
                chatURL: "https://api.deepseek.com/chat/completions",
                catalogURL: "https://api.deepseek.com/models",
                documentationURL: "https://api-docs.deepseek.com/api/create-chat-completion"
            )
        case .qwen, .qwenBusiness:
            return make(
                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                chatURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                catalogURL: "https://dashscope.aliyuncs.com/api/v1/models",
                documentationURL: "https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope"
            )
        case .qwenPersonal, .qwenEnterprise:
            return make(
                baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
                chatURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions",
                catalogURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/models",
                documentationURL: "https://help.aliyun.com/zh/model-studio/token-based-model-service"
            )
        case .moonshot:
            return make(
                baseURL: "https://api.moonshot.cn/v1",
                chatURL: "https://api.moonshot.cn/v1/chat/completions",
                catalogURL: "https://api.moonshot.cn/v1/models",
                documentationURL: "https://platform.moonshot.cn/docs/api/chat"
            )
        case .zhipu:
            return make(
                baseURL: "https://open.bigmodel.cn/api/paas/v4",
                chatURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
                catalogURL: "https://open.bigmodel.cn/api/paas/v4/models",
                documentationURL: "https://open.bigmodel.cn/dev/api/normal-model/glm-4"
            )
        case .xAI:
            return make(
                baseURL: "https://api.x.ai/v1",
                chatURL: "https://api.x.ai/v1/chat/completions",
                catalogURL: "https://api.x.ai/v1/models",
                documentationURL: "https://docs.x.ai/docs/api-reference#chat-completions"
            )
        case .groq:
            return make(
                baseURL: "https://api.groq.com/openai/v1",
                chatURL: "https://api.groq.com/openai/v1/chat/completions",
                catalogURL: "https://api.groq.com/openai/v1/models",
                documentationURL: "https://console.groq.com/docs/api-reference#chat-create"
            )
        case .mistral:
            return make(
                baseURL: "https://api.mistral.ai/v1",
                chatURL: "https://api.mistral.ai/v1/chat/completions",
                catalogURL: "https://api.mistral.ai/v1/models",
                documentationURL: "https://docs.mistral.ai/api/endpoint/chat"
            )
        case .ollama:
            return make(
                baseURL: "http://127.0.0.1:11434",
                chatURL: "http://127.0.0.1:11434/v1/chat/completions",
                catalogURL: "http://127.0.0.1:11434/api/tags",
                documentationURL: "https://docs.ollama.com/openai"
            )
        case .openRouter:
            return make(
                baseURL: "https://openrouter.ai/api/v1",
                chatURL: "https://openrouter.ai/api/v1/chat/completions",
                catalogURL: "https://openrouter.ai/api/v1/models",
                documentationURL: "https://openrouter.ai/docs/api-reference/chat-completion"
            )
        case .togetherAI:
            return make(
                baseURL: "https://api.together.xyz/v1",
                chatURL: "https://api.together.xyz/v1/chat/completions",
                catalogURL: "https://api.together.xyz/v1/models",
                documentationURL: "https://docs.together.ai/reference/chat-completions-1"
            )
        case .fireworksAI:
            return make(
                baseURL: "https://api.fireworks.ai/inference/v1",
                chatURL: "https://api.fireworks.ai/inference/v1/chat/completions",
                catalogURL: "https://api.fireworks.ai/inference/v1/models",
                documentationURL: "https://docs.fireworks.ai/api-reference/post-chatcompletions"
            )
        case .perplexity:
            return make(
                baseURL: "https://api.perplexity.ai/v1",
                chatURL: "https://api.perplexity.ai/v1/chat/completions",
                catalogURL: "https://api.perplexity.ai/v1/models",
                documentationURL: "https://docs.perplexity.ai/api-reference/chat-completions-post"
            )
        case .cohere:
            return make(
                baseURL: "https://api.cohere.ai/compatibility/v1",
                chatURL: "https://api.cohere.ai/compatibility/v1/chat/completions",
                catalogURL: "https://api.cohere.ai/v1/models",
                documentationURL: "https://docs.cohere.com/reference/chat"
            )
        case .siliconFlow:
            return make(
                baseURL: "https://api.siliconflow.cn/v1",
                chatURL: "https://api.siliconflow.cn/v1/chat/completions",
                catalogURL: "https://api.siliconflow.cn/v1/models",
                documentationURL: "https://docs.siliconflow.cn/api-reference/chat-completions/chat-completions"
            )
        case .volcengine:
            return make(
                baseURL: "https://ark.cn-beijing.volces.com/api/v3",
                chatURL: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
                catalogURL: "https://ark.cn-beijing.volces.com/api/v3/models",
                documentationURL: "https://www.volcengine.com/docs/82379/1298454"
            )
        case .baiduQianfan:
            return make(
                baseURL: "https://qianfan.baidubce.com/v2",
                chatURL: "https://qianfan.baidubce.com/v2/chat/completions",
                catalogURL: "https://qianfan.baidubce.com/v2/models",
                documentationURL: "https://cloud.baidu.com/doc/WENXINWORKSHOP/s/clntwmv7t"
            )
        case .minimax:
            // Official MiniMax endpoint references:
            // https://platform.minimax.io/docs/api-reference/models/openai/list-models
            // https://platform.minimax.io/docs/api-reference/text-chat-openai
            // https://platform.minimax.io/docs/api-reference/image-generation-t2i
            // https://platform.minimax.io/docs/api-reference/video-generation-t2v
            // https://platform.minimax.io/docs/api-reference/video-generation-query
            // https://platform.minimax.io/docs/api-reference/speech-t2a-http
            // https://platform.minimax.io/docs/api-reference/music-generation
            return make(
                baseURL: "https://api.minimax.io/v1",
                chatURL: "https://api.minimax.io/v1/chat/completions",
                catalogURL: "https://api.minimax.io/v1/models",
                extras: [
                    .imageGeneration: "https://api.minimax.io/v1/image_generation",
                    .musicGeneration: "https://api.minimax.io/v1/music_generation",
                    .videoGeneration: "https://api.minimax.io/v1/video_generation",
                    .videoTask: "https://api.minimax.io/v1/query/video_generation?task_id={task_id}",
                    .speech: "https://api.minimax.io/v1/t2a_v2"
                ],
                documentationURL: "https://platform.minimax.io/docs/api-reference/api-overview"
            )
        case .minimaxChina:
            // MiniMax 中国站官方端点：
            // https://platform.minimaxi.com/docs/api-reference/models/openai/list-models
            // https://platform.minimaxi.com/docs/api-reference/text-chat-openai
            // https://platform.minimaxi.com/docs/api-reference/image-generation-t2i
            // https://platform.minimaxi.com/docs/api-reference/video-generation-t2v
            // https://platform.minimaxi.com/docs/api-reference/video-generation-query
            // https://platform.minimaxi.com/docs/api-reference/speech-t2a-http
            // https://platform.minimaxi.com/docs/api-reference/music-generation
            return make(
                baseURL: "https://api.minimaxi.com/v1",
                chatURL: "https://api.minimaxi.com/v1/chat/completions",
                catalogURL: "https://api.minimaxi.com/v1/models",
                extras: [
                    .imageGeneration: "https://api.minimaxi.com/v1/image_generation",
                    .musicGeneration: "https://api.minimaxi.com/v1/music_generation",
                    .videoGeneration: "https://api.minimaxi.com/v1/video_generation",
                    .videoTask: "https://api.minimaxi.com/v1/query/video_generation?task_id={task_id}",
                    .speech: "https://api.minimaxi.com/v1/t2a_v2"
                ],
                documentationURL: "https://platform.minimaxi.com/docs/api-reference/api-overview"
            )
        case .apimart:
            return make(
                baseURL: "https://api.apimart.ai/v1",
                chatURL: "https://api.apimart.ai/v1/chat/completions",
                catalogURL: "https://api.apimart.ai/v1/models",
                extras: [
                    .responses: "https://api.apimart.ai/v1/responses",
                    .imageGeneration: "https://api.apimart.ai/v1/images/generations",
                    .videoGeneration: "https://api.apimart.ai/v1/videos/generations",
                    .videoTask: "https://api.apimart.ai/v1/tasks/{task_id}",
                    .speech: "https://api.apimart.ai/v1/audio/speech",
                    .transcription: "https://api.apimart.ai/v1/audio/transcriptions"
                ],
                documentationURL: "https://docs.apimart.ai"
            )
        case .agnes:
            return make(
                baseURL: "https://apihub.agnes-ai.com/v1",
                chatURL: "https://apihub.agnes-ai.com/v1/chat/completions",
                catalogURL: "https://apihub.agnes-ai.com/v1/models",
                documentationURL: "https://agnes-ai.com"
            )
        case .yunwu:
            return make(
                baseURL: "https://yunwu.ai/v1",
                chatURL: "https://yunwu.ai/v1/chat/completions",
                catalogURL: "https://yunwu.ai/v1/models",
                documentationURL: "https://yunwu.ai"
            )
        case .unifiedCompatible:
            return nil
        }
    }
}

/// Repairs the pre-preset APIMart configuration that stored a single video
/// creation endpoint as the provider-wide Base URL. The migration is limited
/// to APIMart's exact HTTPS host so a similarly named custom gateway is never
/// claimed or rewritten. Provider identity, models and custom-host endpoints
/// are retained, which also preserves the existing Keychain account binding.
public enum ProviderConnectionPresetMigration {
    private static let apimartHost = "api.apimart.ai"

    public static func migratedProvider(_ provider: ProviderConfig) -> ProviderConfig? {
        guard provider.kind == .unifiedCompatible || provider.kind == .apimart,
              isOfficialAPIMartURL(provider.baseURL),
              let preset = ProviderConnectionPresets.preset(for: .apimart)
        else { return nil }

        var migrated = provider
        migrated.kind = .apimart
        migrated.baseURL = preset.baseURL

        for (key, officialURL) in preset.endpointURLs {
            guard let existing = migrated.endpointURLs[key] else {
                migrated.endpointURLs[key] = officialURL
                continue
            }
            if isOfficialAPIMartURL(existing) {
                migrated.endpointURLs[key] = officialURL
            }
        }

        // Older releases could have expanded the one Base URL into hundreds
        // of per-model records. Correct only records that still point at the
        // official APIMart origin; explicit custom/proxy endpoints are kept.
        for (key, existing) in provider.endpointURLs where isOfficialAPIMartURL(existing) {
            let rawKind = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
            guard let endpointKind = ProviderEndpointKind(rawValue: rawKind),
                  let officialURL = preset.endpointURLs[
                      ProviderEndpointRecord.key(for: endpointKind)
                  ]
            else { continue }
            migrated.endpointURLs[key] = officialURL
        }

        return migrated == provider ? nil : migrated
    }

    private static func isOfficialAPIMartURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(
            string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == apimartHost
            && components.user == nil
            && components.password == nil
    }
}

private extension ProviderConnectionPreset {
    func replacingEndpoint(
        _ kind: ProviderEndpointKind,
        with value: String
    ) -> ProviderConnectionPreset {
        var endpoints = endpointURLs
        endpoints[ProviderEndpointRecord.key(for: kind)] = value
        return ProviderConnectionPreset(
            kind: self.kind,
            baseURL: baseURL,
            endpointURLs: endpoints,
            documentationURL: documentationURL
        )
    }
}
