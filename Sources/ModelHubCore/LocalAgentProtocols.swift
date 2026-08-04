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

    public init(
        serviceRunning: Bool,
        baseURL: String,
        availableModels: [String],
        enabledProviders: Int,
        enabledRoutes: Int,
        month: String,
        requests: Int,
        successfulRequests: Int,
        estimatedCostUSD: Double
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

public enum LocalAgentProtocols {
    public static let mcpProtocolVersion = "2025-06-18"

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
                "serverInfo": ["name": "ModelHub", "version": "1.8.0"],
                "instructions": "仅提供本机只读状态、可用模型和聚合用量；不会返回提示词、响应正文或密钥。"
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
            "version": "1.8.0",
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
            "version": "1.8.0",
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

    private static func mcpTools() -> [[String: Any]] {
        [
            tool("modelhub_status", "读取 ModelHub 本机状态"),
            tool("list_available_models", "只列出未隔离且可路由的模型"),
            tool("get_usage_summary", "读取不含提示词和响应正文的聚合用量")
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

    private static func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func jsonString(_ object: Any) -> String {
        String(decoding: jsonData(object), as: UTF8.self)
    }
}
