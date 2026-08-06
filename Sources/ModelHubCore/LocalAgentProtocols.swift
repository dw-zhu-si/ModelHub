import Foundation

public struct AgentReadOnlySnapshot: Sendable {
    public let serviceRunning: Bool
    public let baseURL: String
    public let availableModels: [String]
    public let enabledProviders: Int
    public let enabledRoutes: Int
    public let month: String
    public let requests: Int
    public let successfulRequests: Int
    public let estimatedCostUSD: Double
    public let taskContext: String?

    public init(
        serviceRunning: Bool,
        baseURL: String,
        availableModels: [String],
        enabledProviders: Int,
        enabledRoutes: Int,
        month: String,
        requests: Int,
        successfulRequests: Int,
        estimatedCostUSD: Double,
        taskContext: String? = nil
    ) {
        self.serviceRunning = serviceRunning
        self.baseURL = baseURL
        self.availableModels = availableModels
        self.enabledProviders = enabledProviders
        self.enabledRoutes = enabledRoutes
        self.month = month
        self.requests = requests
        self.successfulRequests = successfulRequests
        self.estimatedCostUSD = estimatedCostUSD
        self.taskContext = taskContext
    }
}

public struct AgentProtocolResponse: Sendable {
    public let statusCode: Int
    public let contentType: String
    public let body: Data

    public init(statusCode: Int, contentType: String = "application/json", body: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

public enum MCPActionTool: String, CaseIterable, Sendable {
    case generateText = "generate_text"
    case generateImage = "generate_image"
    case generateVideo = "generate_video"
    case generateSpeech = "generate_speech"
    case getVideoTask = "get_video_task"
    case createEmbeddings = "create_embeddings"
    case rerankDocuments = "rerank_documents"
}

public struct MCPActionInvocation: Sendable {
    public let tool: MCPActionTool
    public let argumentsJSON: Data

    public init(tool: MCPActionTool, argumentsJSON: Data) {
        self.tool = tool
        self.argumentsJSON = argumentsJSON
    }
}

public struct MCPGatewayRequest: Sendable {
    public let method: String
    public let path: String
    public let queryItems: [String: String]
    public let body: Data

    public init(
        method: String,
        path: String,
        queryItems: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.body = body
    }
}

public enum MCPActionValidationError: Error, Equatable, LocalizedError {
    case invalidArguments
    case billableConfirmationRequired
    case missingRequiredField(String)
    case invalidValue(String)
    case unsupportedField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "工具参数必须是 JSON 对象。"
        case .billableConfirmationRequired:
            "本次操作可能计费；只有用户明确授权后，才能将 confirm_billable 设为 true。"
        case .missingRequiredField(let field):
            "缺少必填参数：\(field)"
        case .invalidValue(let field):
            "参数值无效：\(field)"
        case .unsupportedField(let field):
            "不支持的参数：\(field)"
        }
    }
}

public enum LocalAgentProtocols {
    public static let mcpProtocolVersion = "2025-06-18"
    public static let serverVersion = "1.9.0"

    public static func mcp(
        requestBody: Data,
        snapshot: AgentReadOnlySnapshot
    ) -> AgentProtocolResponse {
        guard let request = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String
        else { return jsonRPCError(id: nil, code: -32600, message: "Invalid Request") }
        let id = request["id"]

        switch method {
        case "notifications/initialized":
            return AgentProtocolResponse(statusCode: 204, body: Data())
        case "initialize":
            return jsonRPCResult(id: id, result: [
                "protocolVersion": mcpProtocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "ModelHub", "version": serverVersion],
                "instructions": "提供本机状态、可用模型、聚合用量、任务上下文，以及受隔离与计费确认保护的文字、图片、视频、语音、向量和重排调用；不会返回密钥。"
            ])
        case "tools/list":
            return jsonRPCResult(id: id, result: ["tools": mcpTools()])
        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String,
                  let output = toolOutput(name: name, snapshot: snapshot)
            else { return jsonRPCError(id: id, code: -32602, message: "Unknown read-only tool") }
            let text = jsonString(output)
            return jsonRPCResult(id: id, result: [
                "content": [["type": "text", "text": text]],
                "structuredContent": output,
                "isError": false
            ])
        default:
            return jsonRPCError(id: id, code: -32601, message: "Method not found")
        }
    }

    public static func a2aAgentCard(baseURL: String) -> Data {
        jsonData([
            "name": "ModelHub Local Management",
            "description": "ModelHub 本机只读状态与可用模型查询",
            "url": baseURL + "/a2a",
            "version": serverVersion,
            "protocolVersion": "0.3.0",
            "capabilities": ["streaming": false, "pushNotifications": false],
            "defaultInputModes": ["application/json"],
            "defaultOutputModes": ["application/json"],
            "skills": [
                ["id": "modelhub_status", "name": "ModelHub 状态", "description": "读取本机服务状态与数量", "tags": ["local", "read-only"]],
                ["id": "available_models", "name": "可用模型", "description": "只列出未隔离且可路由的模型", "tags": ["models", "read-only"]],
                ["id": "usage_summary", "name": "聚合用量", "description": "读取不含正文的本月聚合", "tags": ["usage", "read-only"]]
            ]
        ])
    }

    public static func a2a(
        requestBody: Data,
        snapshot: AgentReadOnlySnapshot
    ) -> AgentProtocolResponse {
        guard let request = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String
        else { return jsonRPCError(id: nil, code: -32600, message: "Invalid Request") }
        let id = request["id"]
        let toolName: String
        switch method {
        case "modelhub/status": toolName = "modelhub_status"
        case "modelhub/models": toolName = "list_available_models"
        case "modelhub/usage": toolName = "get_usage_summary"
        default: return jsonRPCError(id: id, code: -32601, message: "Method not found")
        }
        return jsonRPCResult(id: id, result: toolOutput(name: toolName, snapshot: snapshot) ?? [:])
    }

    public static func acpManifest(baseURL: String, command: String = "ModelHubACP") -> Data {
        jsonData([
            "name": "ModelHub",
            "version": serverVersion,
            "transport": "stdio",
            "command": command,
            "environment": [
                "MODELHUB_BASE_URL": baseURL,
                "MODELHUB_AGENT_TOKEN": "<从 ModelHub 的 Agent 协议设置复制>"
            ],
            "scope": "read-only-management",
            "notes": "ACP 使用标准输入/输出；清单不包含真实令牌。"
        ])
    }

    public static func mcpActionInvocation(requestBody: Data) -> MCPActionInvocation? {
        guard let request = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              request["method"] as? String == "tools/call",
              let params = request["params"] as? [String: Any],
              let name = params["name"] as? String,
              let tool = MCPActionTool(rawValue: name)
        else { return nil }

        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard JSONSerialization.isValidJSONObject(arguments),
              let argumentsJSON = try? JSONSerialization.data(
                  withJSONObject: arguments,
                  options: [.sortedKeys]
              )
        else { return nil }
        return MCPActionInvocation(tool: tool, argumentsJSON: argumentsJSON)
    }

    public static func gatewayRequest(
        for invocation: MCPActionInvocation
    ) throws -> MCPGatewayRequest {
        guard let arguments = try? JSONSerialization.jsonObject(
            with: invocation.argumentsJSON
        ) as? [String: Any] else {
            throw MCPActionValidationError.invalidArguments
        }

        switch invocation.tool {
        case .generateText:
            try requireBillableConfirmation(arguments)
            try rejectUnsupportedFields(
                arguments,
                allowed: ["model", "prompt", "max_output_tokens", "confirm_billable"]
            )
            let model = try requiredString("model", in: arguments, maximumLength: 1_000)
            let prompt = try requiredString("prompt", in: arguments, maximumLength: 100_000)
            let maxTokens = try optionalInteger(
                "max_output_tokens",
                in: arguments,
                defaultValue: 512,
                range: 1...4_096
            )
            return try postRequest(path: "/v1/chat/completions", object: [
                "model": model,
                "messages": [["role": "user", "content": prompt]],
                "stream": false,
                "max_tokens": maxTokens
            ])

        case .generateImage:
            try requireBillableConfirmation(arguments)
            try rejectUnsupportedFields(
                arguments,
                allowed: ["model", "prompt", "size", "quality", "confirm_billable"]
            )
            var object: [String: Any] = [
                "model": try requiredString("model", in: arguments, maximumLength: 1_000),
                "prompt": try requiredString("prompt", in: arguments, maximumLength: 20_000),
                "n": 1
            ]
            try copyOptionalString("size", from: arguments, to: &object, maximumLength: 100)
            try copyOptionalString("quality", from: arguments, to: &object, maximumLength: 100)
            return try postRequest(path: "/v1/images/generations", object: object)

        case .generateVideo:
            try requireBillableConfirmation(arguments)
            try rejectUnsupportedFields(
                arguments,
                allowed: [
                    "model", "prompt", "duration_seconds", "size", "aspect_ratio",
                    "confirm_billable"
                ]
            )
            var object: [String: Any] = [
                "model": try requiredString("model", in: arguments, maximumLength: 1_000),
                "prompt": try requiredString("prompt", in: arguments, maximumLength: 20_000),
                "duration": try optionalInteger(
                    "duration_seconds",
                    in: arguments,
                    defaultValue: 4,
                    range: 1...60
                )
            ]
            try copyOptionalString("size", from: arguments, to: &object, maximumLength: 100)
            try copyOptionalString("aspect_ratio", from: arguments, to: &object, maximumLength: 100)
            return try postRequest(path: "/v1/videos/generations", object: object)

        case .generateSpeech:
            try requireBillableConfirmation(arguments)
            try rejectUnsupportedFields(
                arguments,
                allowed: ["model", "input", "voice", "response_format", "confirm_billable"]
            )
            var object: [String: Any] = [
                "model": try requiredString("model", in: arguments, maximumLength: 1_000),
                "input": try requiredString("input", in: arguments, maximumLength: 20_000),
                "voice": try requiredString("voice", in: arguments, maximumLength: 500)
            ]
            try copyOptionalString(
                "response_format",
                from: arguments,
                to: &object,
                maximumLength: 100
            )
            return try postRequest(path: "/v1/audio/speech", object: object)

        case .getVideoTask:
            try rejectUnsupportedFields(arguments, allowed: ["model", "task_id"])
            let model = try requiredString("model", in: arguments, maximumLength: 1_000)
            let taskID = try requiredString("task_id", in: arguments, maximumLength: 2_000)
            let allowedTaskIDCharacters = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-_.:")
            )
            guard taskID.unicodeScalars.allSatisfy(allowedTaskIDCharacters.contains) else {
                throw MCPActionValidationError.invalidValue("task_id")
            }
            return MCPGatewayRequest(
                method: "GET",
                path: "/v1/videos/\(taskID)",
                queryItems: ["model": model]
            )

        case .createEmbeddings:
            try requireBillableConfirmation(arguments)
            try rejectUnsupportedFields(
                arguments,
                allowed: ["model", "input", "confirm_billable"]
            )
            return try postRequest(path: "/v1/embeddings", object: [
                "model": try requiredString("model", in: arguments, maximumLength: 1_000),
                "input": try requiredString("input", in: arguments, maximumLength: 100_000)
            ])

        case .rerankDocuments:
            try requireBillableConfirmation(arguments)
            try rejectUnsupportedFields(
                arguments,
                allowed: ["model", "query", "documents", "confirm_billable"]
            )
            guard let documents = arguments["documents"] as? [String],
                  (1...100).contains(documents.count),
                  documents.allSatisfy({ !$0.isEmpty && $0.count <= 100_000 })
            else { throw MCPActionValidationError.invalidValue("documents") }
            return try postRequest(path: "/v1/rerank", object: [
                "model": try requiredString("model", in: arguments, maximumLength: 1_000),
                "query": try requiredString("query", in: arguments, maximumLength: 20_000),
                "documents": documents
            ])
        }
    }

    public static func mcpRuntimeResult(
        requestBody: Data,
        statusCode: Int,
        contentType: String,
        responseBody: Data
    ) -> AgentProtocolResponse {
        let requestID = mcpRequestID(requestBody)
        let isError = !(200..<300).contains(statusCode)
        let responseObject: Any
        var content: [[String: Any]]

        if let object = try? JSONSerialization.jsonObject(with: responseBody) {
            responseObject = object
            content = [["type": "text", "text": jsonString(object)]]
        } else if contentType.lowercased().hasPrefix("audio/"), responseBody.count <= 8_388_608 {
            responseObject = [
                "content_type": contentType,
                "bytes": responseBody.count,
                "encoding": "base64"
            ]
            content = [[
                "type": "audio",
                "data": responseBody.base64EncodedString(),
                "mimeType": contentType
            ]]
        } else {
            responseObject = [
                "content_type": contentType,
                "bytes": responseBody.count,
                "body_omitted": true
            ]
            content = [[
                "type": "text",
                "text": "上游返回 \(contentType)，共 \(responseBody.count) 字节；为避免把大型二进制内容写入 MCP 响应，正文已省略。"
            ]]
        }

        let structuredContent: [String: Any] = [
            "http_status": statusCode,
            "response": responseObject
        ]
        return jsonRPCResult(id: requestID, result: [
            "content": content,
            "structuredContent": structuredContent,
            "isError": isError
        ])
    }

    public static func mcpToolFailure(
        requestBody: Data,
        type: String,
        message: String
    ) -> AgentProtocolResponse {
        let output: [String: Any] = [
            "error": ["type": type, "message": message]
        ]
        return jsonRPCResult(id: mcpRequestID(requestBody), result: [
            "content": [["type": "text", "text": message]],
            "structuredContent": output,
            "isError": true
        ])
    }

    private static func mcpTools() -> [[String: Any]] {
        [
            tool("modelhub_status", "读取 ModelHub 本机状态"),
            tool("list_available_models", "只列出未隔离且可路由的模型"),
            tool("get_usage_summary", "读取不含提示词和响应正文的聚合用量"),
            tool("get_task_context", "读取用户明确保存的当前任务上下文"),
            actionTool(
                .generateText,
                description: "通过 ModelHub 可用路由生成短文本。只有用户明确授权可能计费的调用后，才可将 confirm_billable 设为 true。",
                properties: [
                    "model": stringProperty("可用模型名、供应商/模型或路由别名"),
                    "prompt": stringProperty("用户要发送给模型的文本", maximumLength: 100_000),
                    "max_output_tokens": integerProperty("最大输出 token 数", minimum: 1, maximum: 4_096),
                    "confirm_billable": booleanProperty("确认用户已明确授权本次可能计费的请求")
                ],
                required: ["model", "prompt", "confirm_billable"]
            ),
            actionTool(
                .generateImage,
                description: "通过 ModelHub 原生图片协议生成图片；隔离模型不会被调用，且必须确认可能计费。",
                properties: [
                    "model": stringProperty("支持图片生成且当前可用的模型"),
                    "prompt": stringProperty("图片描述", maximumLength: 20_000),
                    "size": stringProperty("供应商支持的图片尺寸，例如 1024x1024"),
                    "quality": stringProperty("供应商支持的质量，例如 low、medium、high"),
                    "confirm_billable": booleanProperty("确认用户已明确授权本次可能计费的请求")
                ],
                required: ["model", "prompt", "confirm_billable"]
            ),
            actionTool(
                .generateVideo,
                description: "通过 ModelHub 原生视频协议创建视频任务；返回任务 ID 或上游结果，隔离模型不会被调用，且必须确认可能计费。",
                properties: [
                    "model": stringProperty("支持视频生成且当前可用的模型"),
                    "prompt": stringProperty("视频描述", maximumLength: 20_000),
                    "duration_seconds": integerProperty("视频时长（秒）", minimum: 1, maximum: 60),
                    "size": stringProperty("供应商支持的尺寸或分辨率"),
                    "aspect_ratio": stringProperty("供应商支持的画面比例"),
                    "confirm_billable": booleanProperty("确认用户已明确授权本次可能计费的请求")
                ],
                required: ["model", "prompt", "confirm_billable"]
            ),
            actionTool(
                .generateSpeech,
                description: "通过 ModelHub 原生语音协议生成语音；必须显式提供供应商支持的 voice，并确认可能计费。",
                properties: [
                    "model": stringProperty("支持语音合成且当前可用的模型"),
                    "input": stringProperty("需要合成的文本", maximumLength: 20_000),
                    "voice": stringProperty("供应商支持的音色名称"),
                    "response_format": stringProperty("可选音频格式"),
                    "confirm_billable": booleanProperty("确认用户已明确授权本次可能计费的请求")
                ],
                required: ["model", "input", "voice", "confirm_billable"]
            ),
            actionTool(
                .getVideoTask,
                description: "查询已创建视频任务的状态，不创建新任务。",
                properties: [
                    "model": stringProperty("创建任务时使用的模型或路由"),
                    "task_id": stringProperty("视频任务 ID")
                ],
                required: ["model", "task_id"],
                readOnly: true
            ),
            actionTool(
                .createEmbeddings,
                description: "通过 ModelHub 原生向量协议创建文本向量；必须确认可能计费。",
                properties: [
                    "model": stringProperty("支持向量且当前可用的模型"),
                    "input": stringProperty("需要向量化的文本", maximumLength: 100_000),
                    "confirm_billable": booleanProperty("确认用户已明确授权本次可能计费的请求")
                ],
                required: ["model", "input", "confirm_billable"]
            ),
            actionTool(
                .rerankDocuments,
                description: "通过 ModelHub 原生重排协议对文档排序；必须确认可能计费。",
                properties: [
                    "model": stringProperty("支持重排且当前可用的模型"),
                    "query": stringProperty("查询文本", maximumLength: 20_000),
                    "documents": [
                        "type": "array",
                        "description": "待排序文档，最多 100 条",
                        "items": stringProperty("单条文档", maximumLength: 100_000),
                        "minItems": 1,
                        "maxItems": 100
                    ],
                    "confirm_billable": booleanProperty("确认用户已明确授权本次可能计费的请求")
                ],
                required: ["model", "query", "documents", "confirm_billable"]
            )
        ]
    }

    private static func tool(_ name: String, _ description: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true]
        ]
    }

    private static func actionTool(
        _ tool: MCPActionTool,
        description: String,
        properties: [String: Any],
        required: [String],
        readOnly: Bool = false
    ) -> [String: Any] {
        [
            "name": tool.rawValue,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ],
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": false,
                "idempotentHint": readOnly,
                "openWorldHint": true
            ]
        ]
    }

    private static func stringProperty(
        _ description: String,
        maximumLength: Int? = nil
    ) -> [String: Any] {
        var property: [String: Any] = ["type": "string", "description": description]
        if let maximumLength { property["maxLength"] = maximumLength }
        return property
    }

    private static func integerProperty(
        _ description: String,
        minimum: Int,
        maximum: Int
    ) -> [String: Any] {
        [
            "type": "integer",
            "description": description,
            "minimum": minimum,
            "maximum": maximum
        ]
    }

    private static func booleanProperty(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func postRequest(
        path: String,
        object: [String: Any]
    ) throws -> MCPGatewayRequest {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPActionValidationError.invalidArguments
        }
        return MCPGatewayRequest(
            method: "POST",
            path: path,
            body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private static func requireBillableConfirmation(
        _ arguments: [String: Any]
    ) throws {
        guard arguments["confirm_billable"] as? Bool == true else {
            throw MCPActionValidationError.billableConfirmationRequired
        }
    }

    private static func rejectUnsupportedFields(
        _ arguments: [String: Any],
        allowed: Set<String>
    ) throws {
        if let field = arguments.keys.first(where: { !allowed.contains($0) }) {
            throw MCPActionValidationError.unsupportedField(field)
        }
    }

    private static func requiredString(
        _ name: String,
        in arguments: [String: Any],
        maximumLength: Int
    ) throws -> String {
        guard let raw = arguments[name] as? String else {
            throw MCPActionValidationError.missingRequiredField(name)
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximumLength else {
            throw MCPActionValidationError.invalidValue(name)
        }
        return value
    }

    private static func optionalInteger(
        _ name: String,
        in arguments: [String: Any],
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value = arguments[name] else { return defaultValue }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue,
              range.contains(number.intValue)
        else { throw MCPActionValidationError.invalidValue(name) }
        return number.intValue
    }

    private static func copyOptionalString(
        _ name: String,
        from arguments: [String: Any],
        to object: inout [String: Any],
        maximumLength: Int
    ) throws {
        guard let raw = arguments[name] else { return }
        guard let value = raw as? String else {
            throw MCPActionValidationError.invalidValue(name)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else {
            throw MCPActionValidationError.invalidValue(name)
        }
        object[name] = trimmed
    }

    private static func toolOutput(
        name: String,
        snapshot: AgentReadOnlySnapshot
    ) -> [String: Any]? {
        switch name {
        case "modelhub_status":
            return [
                "running": snapshot.serviceRunning,
                "base_url": snapshot.baseURL,
                "enabled_providers": snapshot.enabledProviders,
                "enabled_routes": snapshot.enabledRoutes,
                "available_models": snapshot.availableModels.count
            ]
        case "list_available_models":
            return ["object": "list", "data": snapshot.availableModels]
        case "get_usage_summary":
            return [
                "month": snapshot.month,
                "requests": snapshot.requests,
                "successful_requests": snapshot.successfulRequests,
                "estimated_cost_usd": snapshot.estimatedCostUSD,
                "contains_request_or_response_body": false
            ]
        case "get_task_context":
            return [
                "configured": snapshot.taskContext?.isEmpty == false,
                "task": snapshot.taskContext ?? "",
                "read_only": true,
                "source": "用户在 ModelHub 中明确保存的任务文本"
            ]
        default:
            return nil
        }
    }

    private static func jsonRPCResult(id: Any?, result: Any) -> AgentProtocolResponse {
        AgentProtocolResponse(
            statusCode: 200,
            body: jsonData(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
        )
    }

    private static func jsonRPCError(id: Any?, code: Int, message: String) -> AgentProtocolResponse {
        AgentProtocolResponse(
            statusCode: 200,
            body: jsonData([
                "jsonrpc": "2.0",
                "id": id ?? NSNull(),
                "error": ["code": code, "message": message]
            ])
        )
    }

    private static func mcpRequestID(_ requestBody: Data) -> Any? {
        (try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any])?["id"]
    }

    private static func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func jsonString(_ object: Any) -> String {
        String(decoding: jsonData(object), as: UTF8.self)
    }
}
