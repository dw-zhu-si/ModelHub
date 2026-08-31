import XCTest
@testable import ModelHubCore

final class ResponseCacheTests: XCTestCase {
    func testCacheSeparatesAccessScopesAndHashesRequestBody() {
        let body = Data(#"{"model":"smart","messages":[]}"#.utf8)
        let primary = ResponseCacheKey.digest(
            method: "POST",
            path: "/v1/chat/completions",
            canonicalQuery: "",
            semanticHeaders: [:],
            body: body,
            accessScope: "primary"
        )
        let workspace = ResponseCacheKey.digest(
            method: "POST",
            path: "/v1/chat/completions",
            canonicalQuery: "",
            semanticHeaders: [:],
            body: body,
            accessScope: "workspace-key"
        )
        XCTAssertNotEqual(primary, workspace)
        XCTAssertFalse(primary.contains("smart"))
    }

    func testCacheKeySeparatesCanonicalQueryAndSemanticHeaders() {
        let body = Data(#"{"model":"smart","messages":[]}"#.utf8)
        let baseline = ResponseCacheKey.digest(
            method: "POST",
            path: "/v1/chat/completions",
            canonicalQuery: "mode=fast",
            semanticHeaders: ["content-type": "application/json"],
            body: body,
            accessScope: "primary"
        )
        let differentQuery = ResponseCacheKey.digest(
            method: "POST",
            path: "/v1/chat/completions",
            canonicalQuery: "mode=precise",
            semanticHeaders: ["content-type": "application/json"],
            body: body,
            accessScope: "primary"
        )
        let differentHeader = ResponseCacheKey.digest(
            method: "POST",
            path: "/v1/chat/completions",
            canonicalQuery: "mode=fast",
            semanticHeaders: ["content-type": "application/json; charset=utf-8"],
            body: body,
            accessScope: "primary"
        )

        XCTAssertNotEqual(baseline, differentQuery)
        XCTAssertNotEqual(baseline, differentHeader)
    }

    func testCachedResponseHeaderPolicyAllowsOnlyRepresentationMetadata() {
        let sanitized = ResponseCacheHeaderPolicy.sanitized([
            "Content-Type": "application/json",
            "Content-Language": "zh-CN",
            "Set-Cookie": "session=secret",
            "WWW-Authenticate": "Bearer realm=upstream",
            "Retry-After": "30",
            "X-Request-ID": "upstream-trace",
            "Connection": "keep-alive"
        ])

        XCTAssertEqual(sanitized["Content-Type"], "application/json")
        XCTAssertEqual(sanitized["Content-Language"], "zh-CN")
        XCTAssertEqual(sanitized.count, 2)
    }

    func testCacheTransitionsFreshStaleAndExpired() async {
        let cache = BoundedResponseCache()
        let settings = ResponseCacheSettings(
            enabled: true,
            timeToLiveSeconds: 10,
            staleFallbackSeconds: 20,
            maximumEntries: 10,
            maximumBytes: 1_048_576
        )
        let response = CachedGatewayResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("result".utf8)
        )
        let start = Date(timeIntervalSince1970: 1_000)
        await cache.insert(key: "key", response: response, settings: settings, now: start)
        let fresh = await cache.lookup(
            key: "key", settings: settings, now: start.addingTimeInterval(5)
        )
        let stale = await cache.lookup(
            key: "key", settings: settings, now: start.addingTimeInterval(15)
        )
        let expired = await cache.lookup(
            key: "key", settings: settings, now: start.addingTimeInterval(21)
        )
        XCTAssertEqual(fresh, .fresh(response))
        XCTAssertEqual(stale, .stale(response))
        XCTAssertEqual(expired, .miss)
    }

    func testCacheEvictsLeastRecentlyUsedWithinBounds() async {
        let cache = BoundedResponseCache()
        let settings = ResponseCacheSettings(
            enabled: true,
            timeToLiveSeconds: 60,
            staleFallbackSeconds: 120,
            maximumEntries: 2,
            maximumBytes: 1_048_576
        )
        let response = CachedGatewayResponse(statusCode: 200, headers: [:], body: Data("x".utf8))
        let start = Date(timeIntervalSince1970: 1_000)
        await cache.insert(key: "a", response: response, settings: settings, now: start)
        await cache.insert(key: "b", response: response, settings: settings, now: start.addingTimeInterval(1))
        _ = await cache.lookup(key: "a", settings: settings, now: start.addingTimeInterval(2))
        await cache.insert(key: "c", response: response, settings: settings, now: start.addingTimeInterval(3))

        let evicted = await cache.lookup(key: "b", settings: settings)
        XCTAssertEqual(evicted, .miss)
        let metrics = await cache.metrics()
        XCTAssertEqual(metrics.entries, 2)
        XCTAssertEqual(metrics.bytes, 2)
        XCTAssertEqual(metrics.freshLookups, 1)
        XCTAssertEqual(metrics.misses, 1)
        XCTAssertEqual(metrics.evictions, 1)
    }

    func testCacheMetricsSeparateFreshStaleAndExpiredLookups() async {
        let cache = BoundedResponseCache()
        let settings = ResponseCacheSettings(
            enabled: true,
            timeToLiveSeconds: 10,
            staleFallbackSeconds: 20,
            maximumEntries: 10,
            maximumBytes: 1_048_576
        )
        let response = CachedGatewayResponse(statusCode: 200, headers: [:], body: Data("x".utf8))
        let start = Date(timeIntervalSince1970: 1_000)
        await cache.insert(key: "key", response: response, settings: settings, now: start)
        _ = await cache.lookup(key: "key", settings: settings, now: start.addingTimeInterval(5))
        _ = await cache.lookup(key: "key", settings: settings, now: start.addingTimeInterval(15))
        _ = await cache.lookup(key: "key", settings: settings, now: start.addingTimeInterval(21))
        await cache.removeAll()

        let metrics = await cache.metrics()
        XCTAssertEqual(metrics.freshLookups, 1)
        XCTAssertEqual(metrics.staleLookups, 1)
        XCTAssertEqual(metrics.misses, 1)
        XCTAssertEqual(metrics.insertions, 1)
        XCTAssertEqual(metrics.clears, 1)
        XCTAssertEqual(metrics.entries, 0)
        XCTAssertEqual(metrics.bytes, 0)
    }
}
