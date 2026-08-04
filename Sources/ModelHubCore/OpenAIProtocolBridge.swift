import Foundation

enum OpenAIProtocolBridge {
    static func anthropicBody(from rawBody: Data, targetModel: String) throws -> Data {
        let root = try jsonObject(rawBody)
        let sourceMessages = try messages(root)
        var systemText: [String] = []
        var convertedMessages: [[String: Any]] = []

        for source in sourceMessages {
            let role = source["role"] as? String ?? "user"
            if role == "system" {
                systemText.append(try textContent(source["content"]))
                continue
            }
            if role == "tool" || role == "function" {
                guard let callID = source["tool_call_id"] as? String, !callID.isEmpty else {
                    throw ProviderClientError.invalidRequest("工具结果缺少 tool_call_id")
                }
                convertedMessages.append([
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": callID,
                        "content": try textContent(source["content"])
                    ]]
                ])
                continue
            }

            var blocks = try anthropicContentBlocks(source["content"])
            if role == "assistant", let calls = source["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          !name.isEmpty
                    else { throw ProviderClientError.invalidRequest("工具调用缺少函数名") }
                    let identifier = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
                    blocks.append([
                        "type": "tool_use",
                        "id": identifier,
                        "name": name,
                        "input": try functionArguments(function["arguments"])
                    ])
                }
            }
            convertedMessages.append([
                "role": role == "assistant" ? "assistant" : "user",
                "content": blocks
            ])
        }

        var body: [String: Any] = [
            "model": targetModel,
            "messages": convertedMessages,
            "max_tokens": root["max_tokens"] as? Int ?? 4_096
        ]
        if !systemText.isEmpty { body["system"] = systemText.joined(separator: "\n\n") }
        copyNumber("temperature", from: root, to: &body)
        copyNumber("top_p", from: root, to: &body)
        if let stop = root["stop"] as? String { body["stop_sequences"] = [stop] }
        if let stop = root["stop"] as? [String] { body["stop_sequences"] = stop }
        if root["stream"] as? Bool == true { body["stream"] = true }
        if let tools = root["tools"] as? [[String: Any]], !tools.isEmpty {
            body["tools"] = try tools.map(anthropicTool)
        }
        if let choice = root["tool_choice"] {
            body["tool_choice"] = try anthropicToolChoice(choice)
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func geminiBody(from rawBody: Data) throws -> Data {
        let root = try jsonObject(rawBody)
        let sourceMessages = try messages(root)
        var systemText: [String] = []
        var contents: [[String: Any]] = []
        var toolNamesByID: [String: String] = [:]

        for source in sourceMessages {
            let role = source["role"] as? String ?? "user"
            if role == "system" {
                systemText.append(try textContent(source["content"]))
                continue
            }
            if role == "tool" || role == "function" {
                let callID = source["tool_call_id"] as? String ?? ""
                let name = toolNamesByID[callID]
                    ?? source["name"] as? String
                    ?? (callID.isEmpty ? "tool" : callID)
                contents.append([
                    "role": "function",
                    "parts": [[
                        "functionResponse": [
                            "name": name,
                            "response": ["result": try jsonCompatibleContent(source["content"])]
                        ]
                    ]]
                ])
                continue
            }

            var parts = try geminiParts(source["content"])
            if role == "assistant", let calls = source["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          !name.isEmpty
                    else { throw ProviderClientError.invalidRequest("工具调用缺少函数名") }
                    if let identifier = call["id"] as? String { toolNamesByID[identifier] = name }
                    parts.append([
                        "functionCall": [
                            "name": name,
                            "args": try functionArguments(function["arguments"])
                        ]
                    ])
                }
            }
            contents.append([
                "role": role == "assistant" ? "model" : "user",
                "parts": parts
            ])
        }

        var body: [String: Any] = ["contents": contents]
        if !systemText.isEmpty {
            body["systemInstruction"] = [
                "parts": [["text": systemText.joined(separator: "\n\n")]]
            ]
        }
        var generation: [String: Any] = [:]
        copyNumber("temperature", from: root, to: &generation)
        copyNumber("top_p", from: root, to: &generation, outputKey: "topP")
        if let maxTokens = root["max_tokens"] as? Int { generation["maxOutputTokens"] = maxTokens }
        if let stop = root["stop"] as? String { generation["stopSequences"] = [stop] }
        if let stop = root["stop"] as? [String] { generation["stopSequences"] = stop }
        if !generation.isEmpty { body["generationConfig"] = generation }
        if let tools = root["tools"] as? [[String: Any]], !tools.isEmpty {
            body["tools"] = [["functionDeclarations": try tools.map(geminiTool)]]
        }
        if let choice = root["tool_choice"] {
            body["toolConfig"] = ["functionCallingConfig": try geminiToolChoice(choice)]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func normalizeAnthropic(_ response: ProviderResponse) throws -> ProviderResponse {
        let json = try jsonObject(response.body)
        let content = json["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        let calls = try content.compactMap { block -> [String: Any]? in
            guard block["type"] as? String == "tool_use" else { return nil }
            let input = block["input"] ?? [:]
            return [
                "id": block["id"] as? String ?? "toolu_unknown",
                "type": "function",
                "function": [
                    "name": block["name"] as? String ?? "tool",
                    "arguments": try jsonString(input)
                ]
            ]
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !calls.isEmpty { message["tool_calls"] = calls }
        let normalized: [String: Any] = [
            "id": json["id"] as? String ?? "chatcmpl-anthropic",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": json["model"] as? String ?? "",
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason(json["stop_reason"] as? String)
            ]],
            "usage": openAIUsage(
                input: usage["input_tokens"],
                output: usage["output_tokens"]
            )
        ]
        return jsonResponse(response.statusCode, normalized)
    }

    static func normalizeGemini(_ response: ProviderResponse, model: String) throws -> ProviderResponse {
        let json = try jsonObject(response.body)
        let candidate = (json["candidates"] as? [[String: Any]])?.first ?? [:]
        let content = candidate["content"] as? [String: Any] ?? [:]
        let parts = content["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        let calls = try parts.compactMap { part -> [String: Any]? in
            guard let call = part["functionCall"] as? [String: Any] else { return nil }
            return [
                "id": "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
                "type": "function",
                "function": [
                    "name": call["name"] as? String ?? "tool",
                    "arguments": try jsonString(call["args"] ?? [:])
                ]
            ]
        }
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !calls.isEmpty { message["tool_calls"] = calls }
        let usage = json["usageMetadata"] as? [String: Any] ?? [:]
        let normalized: [String: Any] = [
            "id": "chatcmpl-gemini-\(UUID().uuidString.lowercased())",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": geminiFinishReason(candidate["finishReason"] as? String)
            ]],
            "usage": [
                "prompt_tokens": integer(usage["promptTokenCount"]),
                "completion_tokens": integer(usage["candidatesTokenCount"]),
                "total_tokens": integer(usage["totalTokenCount"])
            ]
        ]
        return jsonResponse(response.statusCode, normalized)
    }

    static func anthropicStream(_ upstream: ProviderStreamResponse, model: String) -> ProviderStreamResponse {
        let identifier = "chatcmpl-anthropic-\(UUID().uuidString.lowercased())"
        let stream = transformSSE(upstream.body) { object in
            guard let type = object["type"] as? String else { return [] }
            var delta: [String: Any] = [:]
            var finish: Any = NSNull()
            var usage: [String: Any]?
            switch type {
            case "message_start":
                delta["role"] = "assistant"
                if let message = object["message"] as? [String: Any],
                   let sourceUsage = message["usage"] as? [String: Any] {
                    usage = openAIUsage(input: sourceUsage["input_tokens"], output: 0)
                }
            case "content_block_start":
                guard let index = object["index"] as? Int,
                      let block = object["content_block"] as? [String: Any],
                      block["type"] as? String == "tool_use"
                else { return [] }
                delta["tool_calls"] = [[
                    "index": index,
                    "id": block["id"] as? String ?? "toolu_unknown",
                    "type": "function",
                    "function": [
                        "name": block["name"] as? String ?? "tool",
                        "arguments": ""
                    ]
                ]]
            case "content_block_delta":
                guard let sourceDelta = object["delta"] as? [String: Any] else { return [] }
                if sourceDelta["type"] as? String == "text_delta" {
                    delta["content"] = sourceDelta["text"] as? String ?? ""
                } else if sourceDelta["type"] as? String == "input_json_delta" {
                    delta["tool_calls"] = [[
                        "index": object["index"] as? Int ?? 0,
                        "function": ["arguments": sourceDelta["partial_json"] as? String ?? ""]
                    ]]
                } else { return [] }
            case "message_delta":
                if let sourceDelta = object["delta"] as? [String: Any] {
                    finish = finishReason(sourceDelta["stop_reason"] as? String)
                }
                if let sourceUsage = object["usage"] as? [String: Any] {
                    usage = openAIUsage(input: 0, output: sourceUsage["output_tokens"])
                }
            case "error":
                return [try sseData(["error": object["error"] ?? [:]])]
            default:
                return []
            }
            return [try sseData(chatChunk(
                id: identifier,
                model: model,
                delta: delta,
                finishReason: finish,
                usage: usage
            ))]
        }
        return ProviderStreamResponse(
            statusCode: upstream.statusCode,
            headers: ["Content-Type": "text/event-stream"],
            body: stream
        )
    }

    static func geminiStream(_ upstream: ProviderStreamResponse, model: String) -> ProviderStreamResponse {
        let identifier = "chatcmpl-gemini-\(UUID().uuidString.lowercased())"
        let stream = transformSSE(upstream.body) { object in
            let candidate = (object["candidates"] as? [[String: Any]])?.first ?? [:]
            let content = candidate["content"] as? [String: Any] ?? [:]
            let parts = content["parts"] as? [[String: Any]] ?? []
            var results: [Data] = []
            for (index, part) in parts.enumerated() {
                var delta: [String: Any] = [:]
                if let text = part["text"] as? String {
                    delta["content"] = text
                } else if let call = part["functionCall"] as? [String: Any] {
                    delta["tool_calls"] = [[
                        "index": index,
                        "id": "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
                        "type": "function",
                        "function": [
                            "name": call["name"] as? String ?? "tool",
                            "arguments": try jsonString(call["args"] ?? [:])
                        ]
                    ]]
                } else { continue }
                results.append(try sseData(chatChunk(
                    id: identifier,
                    model: model,
                    delta: delta,
                    finishReason: NSNull(),
                    usage: nil
                )))
            }
            if let reason = candidate["finishReason"] as? String {
                let usage = object["usageMetadata"] as? [String: Any] ?? [:]
                results.append(try sseData(chatChunk(
                    id: identifier,
                    model: model,
                    delta: [:],
                    finishReason: geminiFinishReason(reason),
                    usage: [
                        "prompt_tokens": integer(usage["promptTokenCount"]),
                        "completion_tokens": integer(usage["candidatesTokenCount"]),
                        "total_tokens": integer(usage["totalTokenCount"])
                    ]
                )))
            }
            return results
        }
        return ProviderStreamResponse(
            statusCode: upstream.statusCode,
            headers: ["Content-Type": "text/event-stream"],
            body: stream
        )
    }

    private static func messages(_ root: [String: Any]) throws -> [[String: Any]] {
        guard let messages = root["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw ProviderClientError.invalidRequest("messages 必须是非空数组")
        }
        return messages
    }

    private static func anthropicContentBlocks(_ content: Any?) throws -> [[String: Any]] {
        if let string = content as? String { return [["type": "text", "text": string]] }
        guard let items = content as? [[String: Any]] else {
            if content == nil || content is NSNull { return [] }
            throw ProviderClientError.invalidRequest("消息 content 格式不受支持")
        }
        return try items.map { item in
            switch (item["type"] as? String ?? "text").lowercased() {
            case "text", "input_text":
                return ["type": "text", "text": item["text"] as? String ?? ""]
            case "image_url", "input_image":
                return ["type": "image", "source": try anthropicImageSource(item)]
            default:
                throw ProviderClientError.invalidRequest("Anthropic 不支持内容类型 \(item["type"] ?? "unknown")")
            }
        }
    }

    private static func geminiParts(_ content: Any?) throws -> [[String: Any]] {
        if let string = content as? String { return [["text": string]] }
        guard let items = content as? [[String: Any]] else {
            if content == nil || content is NSNull { return [] }
            throw ProviderClientError.invalidRequest("消息 content 格式不受支持")
        }
        return try items.map { item in
            switch (item["type"] as? String ?? "text").lowercased() {
            case "text", "input_text":
                return ["text": item["text"] as? String ?? ""]
            case "image_url", "input_image", "input_audio", "audio_url":
                let url = try mediaURL(item)
                if let data = dataURI(url) {
                    return ["inline_data": ["mime_type": data.mimeType, "data": data.data]]
                }
                guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https" else {
                    throw ProviderClientError.invalidRequest("Gemini 外部媒体必须使用 HTTPS 或 data URI")
                }
                return ["file_data": [
                    "mime_type": inferredMediaType(from: parsed),
                    "file_uri": url
                ]]
            default:
                throw ProviderClientError.invalidRequest("Gemini 不支持内容类型 \(item["type"] ?? "unknown")")
            }
        }
    }

    private static func anthropicImageSource(_ item: [String: Any]) throws -> [String: Any] {
        let url = try mediaURL(item)
        if let data = dataURI(url) {
            guard data.mimeType.hasPrefix("image/") else {
                throw ProviderClientError.invalidRequest("Anthropic image_url 必须是图像")
            }
            return ["type": "base64", "media_type": data.mimeType, "data": data.data]
        }
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https" else {
            throw ProviderClientError.invalidRequest("Anthropic 外部图像必须使用 HTTPS 或 data URI")
        }
        return ["type": "url", "url": url]
    }

    private static func mediaURL(_ item: [String: Any]) throws -> String {
        for key in ["image_url", "audio_url", "file_url"] {
            if let value = item[key] as? String, !value.isEmpty { return value }
            if let value = item[key] as? [String: Any],
               let url = value["url"] as? String,
               !url.isEmpty { return url }
        }
        throw ProviderClientError.invalidRequest("多模态内容缺少 URL")
    }

    private static func dataURI(_ value: String) -> (mimeType: String, data: String)? {
        guard value.hasPrefix("data:"),
              let separator = value.firstIndex(of: ",")
        else { return nil }
        let header = value[value.index(value.startIndex, offsetBy: 5)..<separator]
        guard header.hasSuffix(";base64") else { return nil }
        let mime = String(header.dropLast(";base64".count))
        let data = String(value[value.index(after: separator)...])
        guard !mime.isEmpty, Data(base64Encoded: data) != nil else { return nil }
        return (mime, data)
    }

    private static func anthropicTool(_ source: [String: Any]) throws -> [String: Any] {
        guard source["type"] as? String == "function",
              let function = source["function"] as? [String: Any],
              let name = function["name"] as? String,
              !name.isEmpty
        else { throw ProviderClientError.invalidRequest("仅支持 OpenAI function 工具") }
        var result: [String: Any] = [
            "name": name,
            "input_schema": function["parameters"] as? [String: Any] ?? ["type": "object"]
        ]
        if let description = function["description"] as? String { result["description"] = description }
        return result
    }

    private static func geminiTool(_ source: [String: Any]) throws -> [String: Any] {
        guard source["type"] as? String == "function",
              let function = source["function"] as? [String: Any],
              let name = function["name"] as? String,
              !name.isEmpty
        else { throw ProviderClientError.invalidRequest("仅支持 OpenAI function 工具") }
        var result: [String: Any] = [
            "name": name,
            "parameters": function["parameters"] as? [String: Any] ?? ["type": "object"]
        ]
        if let description = function["description"] as? String { result["description"] = description }
        return result
    }

    private static func anthropicToolChoice(_ source: Any) throws -> [String: Any] {
        if let value = source as? String {
            switch value {
            case "none": return ["type": "none"]
            case "required": return ["type": "any"]
            default: return ["type": "auto"]
            }
        }
        if let object = source as? [String: Any],
           let function = object["function"] as? [String: Any],
           let name = function["name"] as? String {
            return ["type": "tool", "name": name]
        }
        throw ProviderClientError.invalidRequest("tool_choice 格式不受支持")
    }

    private static func geminiToolChoice(_ source: Any) throws -> [String: Any] {
        if let value = source as? String {
            switch value {
            case "none": return ["mode": "NONE"]
            case "required": return ["mode": "ANY"]
            default: return ["mode": "AUTO"]
            }
        }
        if let object = source as? [String: Any],
           let function = object["function"] as? [String: Any],
           let name = function["name"] as? String {
            return ["mode": "ANY", "allowedFunctionNames": [name]]
        }
        throw ProviderClientError.invalidRequest("tool_choice 格式不受支持")
    }

    private static func functionArguments(_ source: Any?) throws -> [String: Any] {
        if source == nil || source is NSNull { return [:] }
        if let object = source as? [String: Any] { return object }
        if let string = source as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        throw ProviderClientError.invalidRequest("工具 arguments 必须是 JSON 对象")
    }

    private static func textContent(_ content: Any?) throws -> String {
        if let text = content as? String { return text }
        if content == nil || content is NSNull { return "" }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        throw ProviderClientError.invalidRequest("文本 content 格式不受支持")
    }

    private static func jsonCompatibleContent(_ content: Any?) throws -> Any {
        if content == nil || content is NSNull { return "" }
        if let string = content as? String {
            if let data = string.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
            return string
        }
        guard JSONSerialization.isValidJSONObject(["value": content!]) else {
            throw ProviderClientError.invalidRequest("工具结果不是有效 JSON")
        }
        return content!
    }

    private static func transformSSE(
        _ input: AsyncThrowingStream<Data, Error>,
        convert: @escaping @Sendable ([String: Any]) throws -> [Data]
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    for try await chunk in input {
                        try Task.checkCancellation()
                        buffer.append(chunk)
                        while let boundary = sseBoundary(in: buffer) {
                            let event = Data(buffer[..<boundary.lowerBound])
                            buffer.removeSubrange(..<boundary.upperBound)
                            if let object = try sseJSONObject(event) {
                                for output in try convert(object) { continuation.yield(output) }
                            }
                        }
                    }
                    if let object = try sseJSONObject(buffer) {
                        for output in try convert(object) { continuation.yield(output) }
                    }
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func sseBoundary(in data: Data) -> Range<Data.Index>? {
        data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8))
    }

    private static func sseJSONObject(_ event: Data) throws -> [String: Any]? {
        guard !event.isEmpty else { return nil }
        let text = String(decoding: event, as: UTF8.self)
        let payload = text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("data:") }
            .map { line in
                let value = line.dropFirst(5)
                return value.first == " " ? String(value.dropFirst()) : String(value)
            }
            .joined(separator: "\n")
        guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else {
            return nil
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidRequest("上游 SSE data 必须是 JSON 对象")
        }
        return object
    }

    private static func chatChunk(
        id: String,
        model: String,
        delta: [String: Any],
        finishReason: Any,
        usage: [String: Any]?
    ) -> [String: Any] {
        var chunk: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [["index": 0, "delta": delta, "finish_reason": finishReason]]
        ]
        if let usage { chunk["usage"] = usage }
        return chunk
    }

    private static func sseData(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object)
        return Data("data: ".utf8) + data + Data("\n\n".utf8)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidRequest("JSON body 必须是对象")
        }
        return object
    }

    private static func jsonString(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw ProviderClientError.invalidRequest("工具参数不是有效 JSON")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private static func jsonResponse(_ statusCode: Int, _ object: [String: Any]) -> ProviderResponse {
        ProviderResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        )
    }

    private static func openAIUsage(input: Any?, output: Any?) -> [String: Any] {
        let inputCount = integer(input)
        let outputCount = integer(output)
        return [
            "prompt_tokens": inputCount,
            "completion_tokens": outputCount,
            "total_tokens": inputCount + outputCount
        ]
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private static func finishReason(_ reason: String?) -> String {
        switch reason {
        case "max_tokens": "length"
        case "tool_use": "tool_calls"
        default: "stop"
        }
    }

    private static func geminiFinishReason(_ reason: String?) -> String {
        switch reason?.uppercased() {
        case "MAX_TOKENS": "length"
        case "STOP": "stop"
        default: reason == nil ? "stop" : "content_filter"
        }
    }

    private static func copyNumber(
        _ inputKey: String,
        from input: [String: Any],
        to output: inout [String: Any],
        outputKey: String? = nil
    ) {
        if let value = input[inputKey] as? NSNumber { output[outputKey ?? inputKey] = value }
    }

    private static func inferredMediaType(from url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "mp4": "video/mp4"
        default: "image/jpeg"
        }
    }
}
