import Foundation
import XCTest
import Darwin
@testable import ModelHub
@testable import ModelHubCore

final class ProxySubscriptionRuntimeTests: XCTestCase {
    func testSubscriptionPayloadInspectorRecognizesMihomoSupportedFormats() throws {
        let yaml = Data("proxies:\n  - name: Synthetic\n    type: direct\n".utf8)
        let uriList = Data("ss://synthetic@example.invalid:443#Synthetic\n".utf8)
        let base64 = Data(uriList.base64EncodedString().utf8)
        let anyTLS = Data(
            Data("anytls://credential@example.invalid:443?sni=example.invalid#Synthetic\n".utf8)
                .base64EncodedString()
                .utf8
        )

        XCTAssertEqual(try ProxySubscriptionPayloadInspector.inspect(yaml).format, .yaml)
        XCTAssertEqual(try ProxySubscriptionPayloadInspector.inspect(uriList).format, .uriList)
        XCTAssertEqual(try ProxySubscriptionPayloadInspector.inspect(base64).format, .base64)
        XCTAssertEqual(try ProxySubscriptionPayloadInspector.inspect(anyTLS).format, .base64)
    }

    func testSubscriptionPayloadInspectorRejectsLoginAndJSONResponsesWithoutEchoingContent() {
        let html = Data("<html><body>token=do-not-echo</body></html>".utf8)
        let json = Data(#"{"error":"token=do-not-echo"}"#.utf8)

        for payload in [html, json] {
            XCTAssertThrowsError(try ProxySubscriptionPayloadInspector.inspect(payload)) { error in
                XCTAssertEqual(
                    error as? ProxySubscriptionRuntimeError,
                    .unsupportedContent
                )
                XCTAssertFalse(error.localizedDescription.contains("do-not-echo"))
            }
        }
    }

    func testNodeDiscoveryFailureMessageIsTerminalAndReportsRetainedNodesSafely() {
        let message = ProxySubscriptionStatusMessage.discoveryFailure(
            error: ProxySubscriptionRuntimeError.coreValidationFailed,
            retainedNodeCount: 12,
            format: .yaml
        )

        XCTAssertTrue(message.contains("节点读取失败"))
        XCTAssertTrue(message.contains("YAML"))
        XCTAssertTrue(message.contains("保留上次 12 个节点"))
        XCTAssertFalse(message.contains("正在读取"))
    }

    func testNodeDelayRequestEncodesProxyNameAndKeepsSecretOutOfURL() throws {
        let request = try ModelProxyControllerClient.delayRequest(
            subscriptionID: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
            proxyName: "[mh-test] 香港/01 ?",
            secret: "controller-secret"
        )
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer controller-secret")
        XCTAssertTrue(components.percentEncodedPath.contains("%2F"))
        XCTAssertTrue(components.path.hasPrefix("/providers/proxies/modelhub_"))
        XCTAssertTrue(components.path.hasSuffix("/healthcheck"))
        XCTAssertEqual(query["url"], "https://www.gstatic.com/generate_204")
        XCTAssertEqual(query["timeout"], "5000")
        XCTAssertNil(query["expected"])
        XCTAssertFalse(request.url?.absoluteString.contains("controller-secret") == true)
    }

    func testNodeDelayResponseAcceptsBoundedDelayAndRejectsFailureSentinel() throws {
        XCTAssertEqual(
            try ModelProxyControllerClient.parseDelay(
                Data(#"{"delay":128}"#.utf8),
                statusCode: 200
            ),
            128
        )
        XCTAssertThrowsError(try ModelProxyControllerClient.parseDelay(
            Data(#"{"delay":65535}"#.utf8),
            statusCode: 200
        ))
        XCTAssertThrowsError(try ModelProxyControllerClient.parseDelay(
            Data(#"{"delay":128}"#.utf8),
            statusCode: 500
        )) { error in
            XCTAssertEqual(
                error as? ProxySubscriptionRuntimeError,
                .nodeDelayHTTPStatus(500)
            )
        }
        XCTAssertThrowsError(try ModelProxyControllerClient.parseDelay(
            Data(#"{"unexpected":true}"#.utf8),
            statusCode: 200
        )) { error in
            XCTAssertEqual(
                error as? ProxySubscriptionRuntimeError,
                .nodeDelayInvalidResponse
            )
        }
    }

    func testNodeLatencyProbesAreSequentialWithinManagedProvider() {
        XCTAssertEqual(ProxyNodeLatencyPolicy.maximumConcurrentTests, 1)
    }

    func testNodeLatencyFailureClassificationKeepsControllerStatusObservable() {
        XCTAssertEqual(
            ProxyNodeLatencyFailure.classify(
                ProxySubscriptionRuntimeError.nodeDelayHTTPStatus(503)
            ),
            .controllerRejected(statusCode: 503)
        )
        XCTAssertEqual(
            ProxyNodeLatencyFailure.classify(
                ProxySubscriptionRuntimeError.nodeDelayInvalidResponse
            ),
            .invalidResponse
        )
        XCTAssertEqual(
            ProxyNodeLatencyFailure.classify(URLError(.timedOut)),
            .timeout
        )
    }

    func testSubscriptionUsageHeaderParsing() {
        let usage = ProxySubscriptionDownloader.parseUsage(
            "upload=1024; download=2048; total=8192; expire=1786704000"
        )

        XCTAssertEqual(usage.uploadBytes, 1_024)
        XCTAssertEqual(usage.downloadBytes, 2_048)
        XCTAssertEqual(usage.totalBytes, 8_192)
        XCTAssertEqual(usage.expiresAt?.timeIntervalSince1970, 1_786_704_000)
    }

    func testSubscriptionURLRequiresHTTPSAndRejectsAuthorityCredentials() throws {
        XCTAssertNoThrow(try ProxySubscriptionURLValidator.validate(
            "https://example.com/sub?token=secret"
        ))
        XCTAssertThrowsError(try ProxySubscriptionURLValidator.validate(
            "http://example.com/sub?token=secret"
        ))
        XCTAssertThrowsError(try ProxySubscriptionURLValidator.validate(
            "https://user:password@example.com/sub"
        ))
        XCTAssertThrowsError(try ProxySubscriptionURLValidator.validate(
            "https://example.com/sub#fragment"
        ))
    }

    func testManagedCoreExecutableUsesDedicatedRuntimeNameWithoutMutatingOriginalCore() throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appending(path: "ModelHubManagedCoreTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeDirectory = testDirectory
            .appending(path: "runtime", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: testDirectory) }

        let originalCoreURL = testDirectory
            .appending(path: "original", directoryHint: .isDirectory)
            .appending(path: "verge-mihomo")
        try fileManager.createDirectory(
            at: originalCoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let originalContents = Data("#!/bin/sh\nexit 0\n".utf8)
        try originalContents.write(to: originalCoreURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: originalCoreURL.path
        )
        let originalAttributes = try fileManager.attributesOfItem(
            atPath: originalCoreURL.path
        )

        let managedCoreURL = try ModelProxyRuntimeManager.prepareManagedCoreExecutable(
            coreURL: originalCoreURL,
            runtimeDirectory: runtimeDirectory
        )

        XCTAssertEqual(managedCoreURL.lastPathComponent, "modelhub-mihomo")
        XCTAssertEqual(
            managedCoreURL.deletingLastPathComponent().standardizedFileURL,
            runtimeDirectory.standardizedFileURL
        )
        XCTAssertNotEqual(managedCoreURL.standardizedFileURL, originalCoreURL.standardizedFileURL)
        XCTAssertTrue(fileManager.isExecutableFile(atPath: managedCoreURL.path))
        XCTAssertEqual(try Data(contentsOf: originalCoreURL), originalContents)
        let retainedAttributes = try fileManager.attributesOfItem(
            atPath: originalCoreURL.path
        )
        XCTAssertEqual(
            retainedAttributes[.posixPermissions] as? NSNumber,
            originalAttributes[.posixPermissions] as? NSNumber
        )
    }

    func testManagedMihomoDiscoversNodeTransportsHTTPSAndMeasuresDelay() async throws {
        guard ProcessInfo.processInfo.environment["MODELHUB_PROXY_EXTERNAL_ACCEPTANCE"] == "1"
        else { throw XCTSkip("仅在显式外部代理验收时启动本机 Mihomo") }

        let fixtureURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/proxy-subscription-synthetic.yaml")
        let payload = try Data(contentsOf: fixtureURL)
        let subscription = ProxySubscription(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
            name: "Synthetic",
            sourceHost: "local.test"
        )
        let secret = "external-acceptance-secret"
        let manager = ModelProxyRuntimeManager()
        defer { manager.stop() }

        let node = ProxySubscriptionNode(
            subscriptionID: subscription.id,
            name: "Synthetic Direct",
            type: "Direct"
        )
        let providerID = UUID()
        let settings = ModelProxySettings(
            enabled: true,
            subscriptions: [subscription],
            nodes: [node],
            assignments: [ModelProxyAssignment(
                providerID: providerID,
                model: "acceptance-model",
                nodeID: node.id
            )]
        )
        try manager.start(
            settings: settings,
            payloads: [subscription.id: payload],
            controllerSecret: secret
        )
        let runtimeDirectory = try XCTUnwrap(manager.runtimeDirectory)
        let processID = try XCTUnwrap(manager.process?.processIdentifier)
        XCTAssertEqual(manager.process?.executableURL?.lastPathComponent, "modelhub-mihomo")
        XCTAssertEqual(
            manager.process?.executableURL?.deletingLastPathComponent().standardizedFileURL,
            runtimeDirectory.standardizedFileURL
        )
        var runtimeName: String?
        for _ in 0..<30 where runtimeName == nil {
            let providersData = try curl([
                "--silent", "--show-error", "--max-time", "5",
                "--header", "Authorization: Bearer \(secret)",
                "http://127.0.0.1:\(ModelProxySettings.controllerPort)/providers/proxies"
            ], retryCount: 20)
            let providers = try? JSONDecoder().decode(
                MihomoProvidersResponse.self,
                from: providersData
            )
            runtimeName = providers?.providers[
                ModelProxyRuntimeConfiguration.providerKey(subscription.id)
            ]?.proxies.first?.name
            if runtimeName == nil { usleep(100_000) }
        }
        let discoveredRuntimeName = try XCTUnwrap(runtimeName)
        let prefix = subscription.runtimePrefix + " "
        XCTAssertTrue(discoveredRuntimeName.hasPrefix(prefix))
        let latency = try await ModelProxyControllerClient.delay(
            subscriptionID: subscription.id,
            proxyName: discoveredRuntimeName,
            secret: secret
        )
        XCTAssertGreaterThan(latency, 0)
        let endpoint = try XCTUnwrap(settings.endpoint(
            providerID: providerID,
            model: "acceptance-model"
        ))
        let statusData = try curl([
            "--silent", "--show-error", "--max-time", "15",
            "--proxy", "http://\(endpoint.host):\(endpoint.port)",
            "--output", "/dev/null", "--write-out", "%{http_code}",
            "https://www.baidu.com"
        ])
        let statusCode = try XCTUnwrap(Int(String(decoding: statusData, as: UTF8.self)))
        XCTAssertTrue((200...499).contains(statusCode))

        manager.stop()
        for _ in 0..<30 where processExists(processID) {
            usleep(100_000)
        }
        XCTAssertFalse(processExists(processID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeDirectory.path))
    }

    private func curl(_ arguments: [String], retryCount: Int = 1) throws -> Data {
        var finalError: Error = ProxySubscriptionRuntimeError.controllerUnavailable
        for attempt in 0..<retryCount {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/curl")
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0 { return data }
            finalError = ProxySubscriptionRuntimeError.controllerUnavailable
            if attempt + 1 < retryCount { usleep(200_000) }
        }
        throw finalError
    }

    private func processExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
