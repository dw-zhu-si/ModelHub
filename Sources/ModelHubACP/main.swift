import Foundation

@main
struct ModelHubACPMain {
    static func main() async {
        var sessions = Set<String>()
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  request["jsonrpc"] as? String == "2.0",
                  let method = request["method"] as? String
            else {
                write(error(id: nil, code: -32600, message: "Invalid Request"))
                continue
            }
            let id = request["id"]
            switch method {
            case "initialize":
                write(result(id: id, value: [
                    "protocolVersion": 1,
                    "agentCapabilities": [
                        "loadSession": false,
                        "promptCapabilities": [
                            "image": false,
                            "audio": false,
                            "embeddedContext": false
                        ]
                    ],
                    "agentInfo": [
                        "name": "modelhub-local-management",
                        "title": "ModelHub 本机只读管理",
                        "version": "1.8.0"
                    ],
                    "authMethods": []
                ]))
            case "session/new":
                let sessionID = "sess_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                sessions.insert(sessionID)
                write(result(id: id, value: ["sessionId": sessionID]))
            case "session/prompt":
                guard let params = request["params"] as? [String: Any],
                      let sessionID = params["sessionId"] as? String,
                      sessions.contains(sessionID)
                else {
                    write(error(id: id, code: -32602, message: "Unknown session"))
                    continue
                }
                let snapshot = await fetchSnapshot()
                write([
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": [
                        "sessionId": sessionID,
                        "update": [
                            "sessionUpdate": "agent_message_chunk",
                            "messageId": "msg_" + UUID().uuidString.lowercased(),
                            "content": ["type": "text", "text": snapshot]
                        ]
                    ]
                ])
                write(result(id: id, value: ["stopReason": "end_turn"]))
            case "session/cancel":
                continue
            default:
                write(error(id: id, code: -32601, message: "Method not found"))
            }
        }
    }

    private static func fetchSnapshot() async -> String {
        let environment = ProcessInfo.processInfo.environment
        let rawBase = environment["MODELHUB_BASE_URL"] ?? "http://127.0.0.1:11435"
        let base = rawBase.hasSuffix("/v1") ? String(rawBase.dropLast(3)) : rawBase
        guard let token = environment["MODELHUB_AGENT_TOKEN"], !token.isEmpty,
              let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/agent/snapshot")
        else {
            return "ModelHub Agent 令牌未配置。请在启动该 ACP 进程时设置 MODELHUB_AGENT_TOKEN。"
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return "无法读取 ModelHub 本机状态（认证失败或服务未启动）。"
            }
            if let object = try? JSONSerialization.jsonObject(with: data),
               let formatted = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
               )
            {
                return String(decoding: formatted, as: UTF8.self)
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "无法连接 ModelHub 本机服务。"
        }
    }

    private static func result(id: Any?, value: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    private static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
    }

    private static func write(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
