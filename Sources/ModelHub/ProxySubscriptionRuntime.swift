import Foundation
import ModelHubCore
import Darwin

struct ProxySubscriptionUsageInfo: Sendable {
    var uploadBytes: Int64?
    var downloadBytes: Int64?
    var totalBytes: Int64?
    var expiresAt: Date?
}

struct ProxySubscriptionDownload: Sendable {
    let data: Data
    let sourceHost: String
    let usage: ProxySubscriptionUsageInfo
}

enum ProxySubscriptionRuntimeError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case credentialBearingURL
    case responseTooLarge
    case invalidResponse
    case httpStatus(Int)
    case missingCore
    case coreValidationFailed
    case coreExited
    case controllerUnavailable
    case invalidProviderResponse
    case unsupportedContent
    case providerNotLoaded
    case noNodes
    case nodeDelayFailed
    case nodeDelayHTTPStatus(Int)
    case nodeDelayInvalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: "订阅链接无效"
        case .insecureURL: "订阅链接必须使用 HTTPS，且重定向也不得降级为 HTTP"
        case .credentialBearingURL: "订阅链接不得在 authority 中包含用户名或密码"
        case .responseTooLarge: "订阅内容超过 4 MiB 安全上限"
        case .invalidResponse: "订阅服务器返回了无效响应"
        case .httpStatus(let status): "订阅更新失败（HTTP \(status)）"
        case .missingCore: "未找到可执行的 Mihomo 内核；可安装 Clash Verge 或 Mihomo"
        case .coreValidationFailed: "Mihomo 拒绝了订阅或运行配置"
        case .coreExited: "ModelHub 代理内核启动后意外退出"
        case .controllerUnavailable: "ModelHub 代理内核控制接口未就绪"
        case .invalidProviderResponse: "Mihomo 返回了无法识别的节点数据"
        case .unsupportedContent: "订阅返回的是网页或 JSON 错误信息，不是 Mihomo 节点内容"
        case .providerNotLoaded: "Mihomo 未能加载这个订阅的节点提供器"
        case .noNodes: "订阅已加载，但没有发现可选择的节点"
        case .nodeDelayFailed: "节点访问外网的延迟测试失败或超时"
        case .nodeDelayHTTPStatus(let status):
            "节点内核拒绝了外网测速（HTTP \(status)）"
        case .nodeDelayInvalidResponse: "节点内核返回了无法识别的测速结果"
        }
    }
}

enum ProxySubscriptionPayloadFormat: String, Sendable {
    case yaml
    case uriList
    case base64
    case unknown

    var displayName: String {
        switch self {
        case .yaml: "YAML"
        case .uriList: "URI 列表"
        case .base64: "Base64 URI 列表"
        case .unknown: "未知格式"
        }
    }
}

struct ProxySubscriptionPayloadInspection: Sendable {
    let format: ProxySubscriptionPayloadFormat
    let byteCount: Int
}

enum ProxySubscriptionPayloadInspector {
    private static let supportedURISchemes = [
        "ss://", "ssr://", "vmess://", "vless://", "trojan://",
        "hysteria://", "hysteria2://", "hy2://", "tuic://", "wireguard://",
        "anytls://"
    ]

    static func inspect(_ data: Data) throws -> ProxySubscriptionPayloadInspection {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8)
        else {
            return .init(format: .unknown, byteCount: data.count)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard !lowercased.hasPrefix("<html"),
              !lowercased.hasPrefix("<!doctype html"),
              !trimmed.hasPrefix("{"),
              !trimmed.hasPrefix("[")
        else {
            throw ProxySubscriptionRuntimeError.unsupportedContent
        }

        if looksLikeYAML(trimmed) {
            return .init(format: .yaml, byteCount: data.count)
        }
        if looksLikeURIList(trimmed) {
            return .init(format: .uriList, byteCount: data.count)
        }

        let compact = trimmed.filter { !$0.isWhitespace }
        if compact.count >= 16,
           let decoded = Data(base64Encoded: compact),
           let decodedText = String(data: decoded, encoding: .utf8)
        {
            let decodedTrimmed = decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeURIList(decodedTrimmed) || looksLikeYAML(decodedTrimmed) {
                return .init(format: .base64, byteCount: data.count)
            }
        }
        return .init(format: .unknown, byteCount: data.count)
    }

    private static func looksLikeYAML(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let normalized = line.trimmingCharacters(in: .whitespaces)
            return normalized == "proxies:" || normalized.hasPrefix("proxies: ")
        }
    }

    private static func looksLikeURIList(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            supportedURISchemes.contains { line.hasPrefix($0) }
        }
    }
}

enum ProxySubscriptionStatusMessage {
    static func discoveryFailure(
        error: Error,
        retainedNodeCount: Int,
        format: ProxySubscriptionPayloadFormat
    ) -> String {
        let safeReason: String
        if let runtimeError = error as? ProxySubscriptionRuntimeError {
            safeReason = runtimeError.localizedDescription
        } else {
            safeReason = "节点读取发生未知错误（未记录订阅内容）"
        }
        let retained = retainedNodeCount > 0
            ? "；保留上次 \(retainedNodeCount) 个节点"
            : ""
        return "节点读取失败（\(format.displayName)）：\(safeReason)\(retained)"
    }
}

enum ProxySubscriptionURLValidator {
    static func validate(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 4_096,
              let components = URLComponents(string: trimmed),
              let url = components.url,
              components.host?.isEmpty == false
        else { throw ProxySubscriptionRuntimeError.invalidURL }
        guard components.scheme?.lowercased() == "https" else {
            throw ProxySubscriptionRuntimeError.insecureURL
        }
        guard components.user == nil, components.password == nil else {
            throw ProxySubscriptionRuntimeError.credentialBearingURL
        }
        guard components.fragment == nil else {
            throw ProxySubscriptionRuntimeError.invalidURL
        }
        return url
    }
}

private final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

enum ProxySubscriptionDownloader {
    static let maximumBytes = 4 * 1_024 * 1_024

    static func fetch(_ url: URL) async throws -> ProxySubscriptionDownload {
        let configuration = ProviderNetworkSession.directConfiguration()
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.httpAdditionalHeaders = [
            "Accept": "application/yaml, text/yaml, text/plain, application/octet-stream",
            "User-Agent": "ModelHub/1.9"
        ]
        let session = URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https"
        else { throw ProxySubscriptionRuntimeError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw ProxySubscriptionRuntimeError.httpStatus(http.statusCode)
        }
        guard response.expectedContentLength <= Int64(maximumBytes)
            || response.expectedContentLength == NSURLSessionTransferSizeUnknown
        else {
            throw ProxySubscriptionRuntimeError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(
            max(Int(response.expectedContentLength), 0),
            maximumBytes
        ))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                session.invalidateAndCancel()
                throw ProxySubscriptionRuntimeError.responseTooLarge
            }
            data.append(byte)
        }
        guard !data.isEmpty else { throw ProxySubscriptionRuntimeError.invalidResponse }
        return ProxySubscriptionDownload(
            data: data,
            sourceHost: http.url?.host ?? url.host ?? "",
            usage: parseUsage(http.value(forHTTPHeaderField: "Subscription-Userinfo"))
        )
    }

    static func parseUsage(_ rawValue: String?) -> ProxySubscriptionUsageInfo {
        guard let rawValue else { return .init() }
        var values: [String: Int64] = [:]
        for part in rawValue.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, let value = Int64(pair[1]), value >= 0 else { continue }
            values[pair[0].lowercased()] = value
        }
        return ProxySubscriptionUsageInfo(
            uploadBytes: values["upload"],
            downloadBytes: values["download"],
            totalBytes: values["total"],
            expiresAt: values["expire"].flatMap { value in
                value > 0 ? Date(timeIntervalSince1970: TimeInterval(value)) : nil
            }
        )
    }
}

final class ModelProxyRuntimeManager: @unchecked Sendable {
    private(set) var process: Process?
    private(set) var runtimeDirectory: URL?

    var isRunning: Bool { process?.isRunning == true }

    func start(
        settings: ModelProxySettings,
        payloads: [UUID: Data],
        controllerSecret: String
    ) throws {
        stop()
        let coreURL = try Self.findCore()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ModelHubProxyRuntime", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let subscriptionsDirectory = root.appending(
            path: "subscriptions",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: subscriptionsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: subscriptionsDirectory.path
            )
            var runtimeFiles: [ProxyRuntimeSubscriptionFile] = []
            for subscription in settings.subscriptions where subscription.enabled {
                guard let payload = payloads[subscription.id] else { continue }
                let fileURL = subscriptionsDirectory.appending(
                    path: "\(subscription.id.uuidString.lowercased()).profile"
                )
                try payload.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
                runtimeFiles.append(ProxyRuntimeSubscriptionFile(
                    subscription: subscription,
                    path: fileURL.path
                ))
            }
            let yaml = try ModelProxyRuntimeConfiguration.yaml(
                settings: settings,
                subscriptionFiles: runtimeFiles,
                controllerSecret: controllerSecret
            )
            let configURL = root.appending(path: "runtime.yaml")
            try Data(yaml.utf8).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )

            try validate(coreURL: coreURL, configURL: configURL, root: root)
            let managedCoreURL = try Self.prepareManagedCoreExecutable(
                coreURL: coreURL,
                runtimeDirectory: root
            )
            let process = Process()
            process.executableURL = managedCoreURL
            process.arguments = ["-d", root.path, "-f", configURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            self.process = process
            runtimeDirectory = root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func stop() {
        if let process, process.isRunning {
            let pid = process.processIdentifier
            _ = Darwin.kill(pid, SIGTERM)
            for _ in 0..<20 where processExists(pid) {
                usleep(100_000)
            }
            if processExists(pid) {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        process = nil
        if let runtimeDirectory {
            try? FileManager.default.removeItem(at: runtimeDirectory)
        }
        runtimeDirectory = nil
    }

    func stop(ifProcessIdentifier processIdentifier: pid_t) {
        guard process?.processIdentifier == processIdentifier else { return }
        stop()
    }

    private func processExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func findCore() throws -> URL {
        let candidates = [
            "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo",
            "/Applications/Clash Verge Rev.app/Contents/MacOS/verge-mihomo",
            "/opt/homebrew/bin/mihomo",
            "/usr/local/bin/mihomo"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        throw ProxySubscriptionRuntimeError.missingCore
    }

    static func prepareManagedCoreExecutable(
        coreURL: URL,
        runtimeDirectory: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: coreURL.path) else {
            throw ProxySubscriptionRuntimeError.missingCore
        }
        let managedCoreURL = runtimeDirectory.appending(path: "modelhub-mihomo")
        guard !fileManager.fileExists(atPath: managedCoreURL.path) else {
            throw ProxySubscriptionRuntimeError.coreValidationFailed
        }
        do {
            try fileManager.linkItem(at: coreURL, to: managedCoreURL)
        } catch {
            try fileManager.copyItem(at: coreURL, to: managedCoreURL)
        }
        guard fileManager.isExecutableFile(atPath: managedCoreURL.path) else {
            try? fileManager.removeItem(at: managedCoreURL)
            throw ProxySubscriptionRuntimeError.missingCore
        }
        return managedCoreURL
    }

    private func validate(coreURL: URL, configURL: URL, root: URL) throws {
        let process = Process()
        process.executableURL = coreURL
        process.arguments = ["-t", "-d", root.path, "-f", configURL.path]
        process.standardOutput = FileHandle.nullDevice
        // Validation output may contain provider node names or endpoints. Keep
        // it out of logs and avoid a bounded pipe becoming a deadlock source.
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProxySubscriptionRuntimeError.coreValidationFailed
        }
    }
}

struct MihomoProvidersResponse: Decodable {
    let providers: [String: MihomoProvider]
}

struct MihomoProvider: Decodable {
    let proxies: [MihomoProxy]
}

struct MihomoProxy: Decodable {
    let name: String
    let type: String
    let alive: Bool?
}

enum ModelProxyControllerClient {
    static let delayTestURL = "https://www.gstatic.com/generate_204"

    static func providers(secret: String) async throws -> MihomoProvidersResponse {
        let configuration = ProviderNetworkSession.directConfiguration()
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "http://127.0.0.1:\(ModelProxySettings.controllerPort)/providers/proxies")
        else { throw ProxySubscriptionRuntimeError.controllerUnavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProxySubscriptionRuntimeError.controllerUnavailable
        }
        do {
            return try JSONDecoder().decode(MihomoProvidersResponse.self, from: data)
        } catch {
            throw ProxySubscriptionRuntimeError.invalidProviderResponse
        }
    }

    static func delayRequest(
        subscriptionID: UUID,
        proxyName: String,
        secret: String
    ) throws -> URLRequest {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encodedName = proxyName.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) else {
            throw ProxySubscriptionRuntimeError.nodeDelayFailed
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = ModelProxySettings.controllerPort
        let providerKey = ModelProxyRuntimeConfiguration.providerKey(subscriptionID)
        components.percentEncodedPath = "/providers/proxies/\(providerKey)/\(encodedName)/healthcheck"
        components.queryItems = [
            URLQueryItem(name: "url", value: delayTestURL),
            URLQueryItem(name: "timeout", value: "5000")
        ]
        guard let url = components.url else {
            throw ProxySubscriptionRuntimeError.nodeDelayFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func delay(
        subscriptionID: UUID,
        proxyName: String,
        secret: String
    ) async throws -> Int {
        let configuration = ProviderNetworkSession.directConfiguration()
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = try delayRequest(
            subscriptionID: subscriptionID,
            proxyName: proxyName,
            secret: secret
        )
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try parseDelay(data, statusCode: statusCode)
    }

    static func parseDelay(_ data: Data, statusCode: Int) throws -> Int {
        guard statusCode == 200 else {
            throw ProxySubscriptionRuntimeError.nodeDelayHTTPStatus(statusCode)
        }
        guard let response = try? JSONDecoder().decode(MihomoDelayResponse.self, from: data),
              (1..<65_535).contains(response.delay)
        else {
            throw ProxySubscriptionRuntimeError.nodeDelayInvalidResponse
        }
        return response.delay
    }
}

private struct MihomoDelayResponse: Decodable {
    let delay: Int
}

enum ProxyNodeLatencyPolicy {
    // Mihomo runs URLTest through one shared provider. Parallel requests on
    // that provider can invalidate each other and turn healthy nodes into
    // false failures, so preserve correctness with one in-flight test.
    static let maximumConcurrentTests = 1
}
