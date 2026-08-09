import XCTest
@testable import ModelHubCore

final class ResponseCacheTests: XCTestCase {
    func testCacheSeparatesAccessScopesAndHashesRequestBody() {
        let body = Data(#"{"model":"smart","messages":[]}"#.utf8)
        let primary = ResponseCacheKey.digest(
            method: "POST",
            path: "/v1/chat/completions",
            body: body,
            accessScope: "primary"
        )
        let workspace = ResponseCacheKey.digest(
            method: "POST",
            path: "/v1/chat/completions",
            body: body,
            accessScope: "workspace-key"
        )
        XCTAssertNotEqual(primary, workspace)
        XCTAssertFalse(primary.contains("smart"))
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
    }
}
