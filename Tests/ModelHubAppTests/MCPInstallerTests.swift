import Foundation
import XCTest
@testable import ModelHub

final class MCPInstallerTests: XCTestCase {
    func testCodexMergeReplacesOnlyModelHubBlock() throws {
        let existing = """
        [mcp_servers.node_repl]
        command = \"node\"

        [mcp_servers.modelhub]
        url = \"http://old/mcp\"

        [mcp_servers.modelhub.http_headers]
        Authorization = \"Bearer old\"

        [mcp_servers.other]
        url = \"http://other/mcp\"
        """
        let merged = try MCPInstaller.mergedCodexConfig(
            existing: existing,
            endpoint: "http://127.0.0.1:11435/mcp",
            token: "test-token"
        )
        XCTAssertTrue(merged.contains("[mcp_servers.node_repl]"))
        XCTAssertTrue(merged.contains("[mcp_servers.other]"))
        XCTAssertEqual(merged.components(separatedBy: "[mcp_servers.modelhub]").count - 1, 1)
        XCTAssertTrue(merged.contains("Authorization = \"Bearer test-token\""))
        XCTAssertFalse(merged.contains("Bearer old"))
    }

    func testClaudeMergePreservesOtherServers() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "theme": "dark",
            "mcpServers": ["other": ["type": "http", "url": "http://other"]]
        ])
        let data = try MCPInstaller.mergedClaudeConfig(
            existing: existing,
            endpoint: "http://127.0.0.1:11435/mcp",
            token: "test-token"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["theme"] as? String, "dark")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        let modelhub = try XCTUnwrap(servers["modelhub"] as? [String: Any])
        XCTAssertEqual(modelhub["type"] as? String, "http")
        XCTAssertEqual((modelhub["headers"] as? [String: String])?["Authorization"], "Bearer test-token")
    }

    func testManualSnippetContainsBothSupportedInstallModes() throws {
        let snippet = try MCPInstaller.manualSnippet(endpoint: "http://127.0.0.1:11435/mcp", token: "test-token")
        XCTAssertTrue(snippet.contains("mcp_servers.modelhub"))
        XCTAssertTrue(snippet.contains("claude mcp add"))
        XCTAssertTrue(snippet.contains("test-token"))
    }

    func testOneClickInstallWritesUserConfigWithPrivatePermissions() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelhub-mcp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = try MCPInstaller.installCodex(
            endpoint: "http://127.0.0.1:11435/mcp",
            token: "test-token",
            homeURL: home
        )
        let claude = try MCPInstaller.installClaude(
            endpoint: "http://127.0.0.1:11435/mcp",
            token: "test-token",
            homeURL: home
        )
        let codexMode = try FileManager.default.attributesOfItem(atPath: codex.path)[.posixPermissions] as? NSNumber
        let claudeMode = try FileManager.default.attributesOfItem(atPath: claude.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(codexMode?.intValue, 0o600)
        XCTAssertEqual(claudeMode?.intValue, 0o600)
        XCTAssertTrue(String(decoding: try Data(contentsOf: codex), as: UTF8.self).contains("mcp_servers.modelhub"))
        XCTAssertTrue(String(decoding: try Data(contentsOf: claude), as: UTF8.self).contains("modelhub"))
    }
}
