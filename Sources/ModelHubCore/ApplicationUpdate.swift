import Foundation

public enum ApplicationReleaseChannel: String, Codable, Sendable {
    case appStore = "app-store"
    case github
    case local

    public static func resolve(
        explicitValue: String?,
        hasAppStoreReceipt: Bool,
        isDebugBuild: Bool
    ) -> Self {
        if isDebugBuild { return .local }
        if hasAppStoreReceipt { return .appStore }
        return Self(rawValue: explicitValue ?? "") ?? .github
    }
}

public struct ApplicationReleaseVersion: Comparable, Equatable, Sendable {
    public let components: [Int]

    public init?(_ rawValue: String) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
        let core = normalized.split(separator: "+", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        var parsed = parts.map { Int($0)! }
        while parsed.count > 1, parsed.last == 0 {
            parsed.removeLast()
        }
        components = parsed
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public struct ApplicationUpdateRelease: Equatable, Sendable {
    public let version: String
    public let pageURL: URL

    public init(version: String, pageURL: URL) {
        self.version = version
        self.pageURL = pageURL
    }
}

public struct ApplicationUpdateResult: Equatable, Sendable {
    public let currentVersion: String
    public let release: ApplicationUpdateRelease
    public let isUpdateAvailable: Bool

    public init(currentVersion: String, release: ApplicationUpdateRelease) throws {
        guard let current = ApplicationReleaseVersion(currentVersion),
              let latest = ApplicationReleaseVersion(release.version)
        else { throw ApplicationUpdateError.invalidVersion }
        self.currentVersion = currentVersion
        self.release = release
        isUpdateAvailable = current < latest
    }
}

public enum ApplicationUpdateError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedChannel
    case invalidResponse
    case responseTooLarge
    case invalidVersion
    case unsafeReleaseURL
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedChannel: "当前构建不支持在线检查更新。"
        case .invalidResponse: "更新服务返回了无法识别的数据。"
        case .responseTooLarge: "更新服务响应超过安全大小限制。"
        case .invalidVersion: "更新服务返回了无效版本号。"
        case .unsafeReleaseURL: "更新地址不属于受信任的发行渠道。"
        case .httpStatus(let status): "更新服务暂时不可用（HTTP \(status)）。"
        }
    }
}

public enum ApplicationUpdatePolicy {
    public static let appStoreID = 6_797_847_364
    public static let maximumResponseBytes = 512 * 1_024

    public static func endpoint(for channel: ApplicationReleaseChannel) throws -> URL {
        switch channel {
        case .appStore:
            return URL(string: "https://itunes.apple.com/lookup?id=6797847364&country=cn")!
        case .github:
            return URL(string: "https://api.github.com/repos/dw-zhu-si/ModelHub/releases/latest")!
        case .local:
            throw ApplicationUpdateError.unsupportedChannel
        }
    }

    public static func validateResponse(
        _ response: URLResponse,
        data: Data,
        channel: ApplicationReleaseChannel
    ) throws {
        guard data.count <= maximumResponseBytes else {
            throw ApplicationUpdateError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw ApplicationUpdateError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw ApplicationUpdateError.httpStatus(http.statusCode)
        }
        let expectedHost = try endpoint(for: channel).host
        guard http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == expectedHost
        else { throw ApplicationUpdateError.invalidResponse }
        if let mimeType = http.mimeType?.lowercased(),
           mimeType != "application/json",
           !mimeType.hasSuffix("+json")
        {
            throw ApplicationUpdateError.invalidResponse
        }
    }

    public static func parseRelease(
        data: Data,
        channel: ApplicationReleaseChannel
    ) throws -> ApplicationUpdateRelease {
        let release: ApplicationUpdateRelease
        switch channel {
        case .github:
            let payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
            guard !payload.draft, !payload.prerelease,
                  ApplicationReleaseVersion(payload.tagName) != nil,
                  let url = URL(string: payload.htmlURL)
            else { throw ApplicationUpdateError.invalidResponse }
            release = .init(
                version: payload.tagName.trimmingPrefix("v"),
                pageURL: url
            )
        case .appStore:
            let payload = try JSONDecoder().decode(AppStoreLookupPayload.self, from: data)
            guard let item = payload.results.first(where: {
                $0.trackID == appStoreID && $0.bundleID == "com.local.modelhub"
            }), ApplicationReleaseVersion(item.version) != nil,
               let url = URL(string: item.trackViewURL)
            else { throw ApplicationUpdateError.invalidResponse }
            release = .init(version: item.version, pageURL: url)
        case .local:
            throw ApplicationUpdateError.unsupportedChannel
        }
        guard isTrustedReleaseURL(release.pageURL, for: channel) else {
            throw ApplicationUpdateError.unsafeReleaseURL
        }
        return release
    }

    public static func isTrustedReleaseURL(
        _ url: URL,
        for channel: ApplicationReleaseChannel
    ) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        let host = url.host?.lowercased()
        switch channel {
        case .github:
            return host == "github.com"
                && url.path.hasPrefix("/dw-zhu-si/ModelHub/releases/")
        case .appStore:
            return ["apps.apple.com", "itunes.apple.com"].contains(host)
                && url.absoluteString.contains("id\(appStoreID)")
        case .local:
            return false
        }
    }
}

public actor ApplicationUpdateClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(
        currentVersion: String,
        channel: ApplicationReleaseChannel
    ) async throws -> ApplicationUpdateResult {
        let endpoint = try ApplicationUpdatePolicy.endpoint(for: channel)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ModelHub/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        data.reserveCapacity(min(ApplicationUpdatePolicy.maximumResponseBytes, 32 * 1_024))
        for try await byte in bytes {
            guard data.count < ApplicationUpdatePolicy.maximumResponseBytes else {
                throw ApplicationUpdateError.responseTooLarge
            }
            data.append(byte)
        }
        try ApplicationUpdatePolicy.validateResponse(
            response,
            data: data,
            channel: channel
        )
        let release = try ApplicationUpdatePolicy.parseRelease(data: data, channel: channel)
        return try ApplicationUpdateResult(
            currentVersion: currentVersion,
            release: release
        )
    }
}

private struct GitHubReleasePayload: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft, prerelease
    }
}

private struct AppStoreLookupPayload: Decodable {
    let results: [Item]

    struct Item: Decodable {
        let trackID: Int
        let bundleID: String
        let version: String
        let trackViewURL: String

        enum CodingKeys: String, CodingKey {
            case trackID = "trackId"
            case bundleID = "bundleId"
            case version
            case trackViewURL = "trackViewUrl"
        }
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}
