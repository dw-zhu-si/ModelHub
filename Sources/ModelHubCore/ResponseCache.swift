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
        canonicalQuery: String = "",
        semanticHeaders: [String: String] = [:],
        body: Data,
        accessScope: String
    ) -> String {
        var input = Data(method.uppercased().utf8)
        input.append(0)
        input.append(contentsOf: path.utf8)
        input.append(0)
        input.append(contentsOf: canonicalQuery.utf8)
        input.append(0)
        let normalizedHeaders: [(String, String)] = semanticHeaders.map { entry in
            let name = entry.key.lowercased()
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, value)
        }
        let sortedHeaders = normalizedHeaders.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        for (name, value) in sortedHeaders {
            input.append(contentsOf: name.utf8)
            input.append(0x3A)
            input.append(contentsOf: value.utf8)
            input.append(0)
        }
        input.append(contentsOf: accessScope.utf8)
        input.append(0)
        input.append(body)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ResponseCacheHeaderPolicy {
    private static let allowedNames: Set<String> = [
        "content-type",
        "content-language"
    ]

    /// Cached gateway responses retain only representation metadata. Hop-by-hop
    /// headers, cookies, authentication challenges, retry instructions and
    /// upstream tracing identifiers must never be replayed to another request.
    public static func sanitized(_ headers: [String: String]) -> [String: String] {
        headers.filter { allowedNames.contains($0.key.lowercased()) }
    }
}

public struct ResponseCacheMetrics: Equatable, Sendable {
    public let entries: Int
    public let bytes: Int
    public let freshLookups: UInt64
    public let staleLookups: UInt64
    public let misses: UInt64
    public let insertions: UInt64
    public let evictions: UInt64
    public let clears: UInt64
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
    private var freshLookups: UInt64 = 0
    private var staleLookups: UInt64 = 0
    private var misses: UInt64 = 0
    private var insertions: UInt64 = 0
    private var evictions: UInt64 = 0
    private var clears: UInt64 = 0

    public init() {}

    public func lookup(
        key: String,
        settings rawSettings: ResponseCacheSettings,
        now: Date = .now
    ) -> ResponseCacheLookup {
        let settings = rawSettings.sanitized
        guard var entry = entries[key] else {
            misses &+= 1
            return .miss
        }
        let age = max(0, now.timeIntervalSince(entry.storedAt))
        guard age <= Double(settings.staleFallbackSeconds) else {
            remove(key)
            misses &+= 1
            return .miss
        }
        entry.lastAccessedAt = now
        entries[key] = entry
        if age <= Double(settings.timeToLiveSeconds) {
            freshLookups &+= 1
            return .fresh(entry.response)
        }
        staleLookups &+= 1
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
        insertions &+= 1
        evictIfNeeded(settings: settings)
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalBytes = 0
        clears &+= 1
    }

    public func metrics() -> ResponseCacheMetrics {
        ResponseCacheMetrics(
            entries: entries.count,
            bytes: totalBytes,
            freshLookups: freshLookups,
            staleLookups: staleLookups,
            misses: misses,
            insertions: insertions,
            evictions: evictions,
            clears: clears
        )
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
            evictions &+= 1
        }
    }
}
