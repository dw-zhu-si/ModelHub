import Foundation

enum MCPInstallerError: LocalizedError {
    case invalidEndpoint
    case invalidClaudeConfig(URL)
    case cannotRead(URL)
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "MCP 地址无效"
        case .invalidClaudeConfig(let url): "Claude 配置文件不是有效 JSON：\(url.path)"
        case .cannotRead(let url): "无法读取 MCP 配置：\(url.path)"
        case .cannotWrite(let url): "无法写入 MCP 配置：\(url.path)"
        }
    }
}

/// 生成并安装 ModelHub 的本机 HTTP MCP 配置。
/// 写入范围仅限用户主目录下的 Codex/Claude 配置，令牌不经过 shell 参数。
enum MCPInstaller {
    static let serverName = "modelhub"

    static func codexBlock(endpoint: String, token: String) throws -> String {
        guard URL(string: endpoint)?.scheme != nil else { throw MCPInstallerError.invalidEndpoint }
        return """
        [mcp_servers.modelhub]
        url = "\(tomlEscape(endpoint))"

        [mcp_servers.modelhub.http_headers]
        Authorization = "Bearer \(tomlEscape(token))"
        Origin = "http://127.0.0.1"
        """
    }

    static func mergedCodexConfig(existing: String, endpoint: String, token: String) throws -> String {
        let block = try codexBlock(endpoint: endpoint, token: token)
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var skipping = false
        for line in lines {
            let heading = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if heading == "[mcp_servers.\(serverName)]" || heading.hasPrefix("[mcp_servers.\(serverName).") {
                skipping = true
                continue
            }
            if skipping, heading.hasPrefix("[") && heading.hasSuffix("]") {
                skipping = false
            }
            if !skipping { output.append(line) }
        }
        while output.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            output.removeLast()
        }
        if !output.isEmpty { output.append("") }
        output.append(contentsOf: block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        return output.joined(separator: "\n") + "\n"
    }

    static func claudeServer(endpoint: String, token: String) throws -> [String: Any] {
        guard URL(string: endpoint)?.scheme != nil else { throw MCPInstallerError.invalidEndpoint }
        return [
            "type": "http",
            "url": endpoint,
            "headers": [
                "Authorization": "Bearer \(token)",
                "Origin": "http://127.0.0.1"
            ]
        ]
    }

    static func mergedClaudeConfig(existing: Data?, endpoint: String, token: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing {
            guard let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw MCPInstallerError.invalidClaudeConfig(claudeConfigURL(homeURL: FileManager.default.homeDirectoryForCurrentUser))
            }
            root = decoded
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = try claudeServer(endpoint: endpoint, token: token)
        root["mcpServers"] = servers
        guard JSONSerialization.isValidJSONObject(root) else {
            throw MCPInstallerError.invalidClaudeConfig(claudeConfigURL(homeURL: FileManager.default.homeDirectoryForCurrentUser))
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    @discardableResult
    static func installCodex(
        endpoint: String,
        token: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let url = codexConfigURL(homeURL: homeURL)
        let existing = try readIfPresent(url)
        let merged = try mergedCodexConfig(existing: existing, endpoint: endpoint, token: token)
        try writeSecure(Data(merged.utf8), to: url)
        return url
    }

    @discardableResult
    static func installClaude(
        endpoint: String,
        token: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let url = claudeConfigURL(homeURL: homeURL)
        let existing = try readDataIfPresent(url)
        let merged = try mergedClaudeConfig(existing: existing, endpoint: endpoint, token: token)
        try writeSecure(merged, to: url)
        return url
    }

    static func manualSnippet(endpoint: String, token: String) throws -> String {
        """
        # ModelHub MCP（HTTP，只读）
        # Codex：追加到 ~/.codex/config.toml
        \(try codexBlock(endpoint: endpoint, token: token))

        # Claude Code：运行以下命令，或将同名条目合并到 ~/.claude.json
        claude mcp add --transport http --scope user --header "Authorization: Bearer \(token)" --header "Origin: http://127.0.0.1" modelhub \(endpoint)
        """
    }

    private static func codexConfigURL(homeURL: URL) -> URL {
        homeURL.appendingPathComponent(".codex/config.toml")
    }

    private static func claudeConfigURL(homeURL: URL) -> URL {
        homeURL.appendingPathComponent(".claude.json")
    }

    private static func readIfPresent(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { throw MCPInstallerError.cannotRead(url) }
        return value
    }

    private static func readDataIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let value = try? Data(contentsOf: url) else { throw MCPInstallerError.cannotRead(url) }
        return value
    }

    private static func writeSecure(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw MCPInstallerError.cannotWrite(url)
        }
    }

    private static func tomlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
