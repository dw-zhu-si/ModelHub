import CryptoKit
import Foundation

public struct CachedGatewayResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum ResponseCacheLookup: Sendable, Equatable {
    case miss
    case fresh(CachedGatewayResponse)
    case stale(CachedGatewayResponse)
}

public enum ResponseCacheKey {
    public static func digest(
        method: String,
        path: String,
        body: Data,
        accessScope: String
    ) -> String {
        var input = Data(method.uppercased().utf8)
        input.append(0)
        input.append(contentsOf: path.utf8)
        input.append(0)
        input.append(contentsOf: accessScope.utf8)
        input.append(0)
        input.append(body)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

public actor BoundedResponseCache {
    private struct Entry: Sendable {
        let response: CachedGatewayResponse
        let storedAt: Date
        var lastAccessedAt: Date
        var byteCount: Int { response.body.count }
    }

    private var entries: [String: Entry] = [:]
    private var totalBytes = 0

    public init() {}

    public func lookup(
        key: String,
        settings rawSettings: ResponseCacheSettings,
        now: Date = .now
    ) -> ResponseCacheLookup {
        let settings = rawSettings.sanitized
        guard var entry = entries[key] else { return .miss }
        let age = max(0, now.timeIntervalSince(entry.storedAt))
        guard age <= Double(settings.staleFallbackSeconds) else {
            remove(key)
            return .miss
        }
        entry.lastAccessedAt = now
        entries[key] = entry
        if age <= Double(settings.timeToLiveSeconds) {
            return .fresh(entry.response)
        }
        return .stale(entry.response)
    }

    public func insert(
        key: String,
        response: CachedGatewayResponse,
        settings rawSettings: ResponseCacheSettings,
        now: Date = .now
    ) {
        let settings = rawSettings.sanitized
        guard response.body.count <= settings.maximumBytes else { return }
        remove(key)
        entries[key] = Entry(response: response, storedAt: now, lastAccessedAt: now)
        totalBytes += response.body.count
        evictIfNeeded(settings: settings)
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalBytes = 0
    }

    public func metrics() -> (entries: Int, bytes: Int) {
        (entries.count, totalBytes)
    }

    private func remove(_ key: String) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalBytes -= removed.byteCount
    }

    private func evictIfNeeded(settings: ResponseCacheSettings) {
        while entries.count > settings.maximumEntries || totalBytes > settings.maximumBytes {
            guard let oldest = entries.min(by: {
                $0.value.lastAccessedAt < $1.value.lastAccessedAt
            })?.key else { break }
            remove(oldest)
        }
    }
}
