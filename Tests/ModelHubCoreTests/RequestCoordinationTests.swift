import XCTest
@testable import ModelHubCore

final class RequestCoordinationTests: XCTestCase {
    func testFingerprintNormalizesSemanticHeadersAndIgnoresCredentialsAndTracing() {
        let body = Data("{\"prompt\":\"hello\"}".utf8)
        let first = BoundedIdempotencyStore.fingerprint(
            method: "post",
            path: "/v1/messages",
            orderedQuery: "stream=false",
            headers: [
                "Content-Type": "Application/JSON; Charset=UTF-8",
                "Anthropic-Beta": "  prompt-caching-2024-07-31   tools-2024-05-16 ",
                "X-ModelHub-Session-ID": "session-a",
                "Authorization": "Bearer secret-a",
                "X-Request-ID": "trace-a",
                "X-Idempotency-Key": "alternate-request-key-a",
                "X-Amz-Security-Token": "temporary-secret-a",
                "B3": "trace-context-a",
                "Idempotency-Key": "request-key-a"
            ],
            body: body
        )
        let normalizedEquivalent = BoundedIdempotencyStore.fingerprint(
            method: "POST",
            path: "/v1/messages",
            orderedQuery: "stream=false",
            headers: [
                "content-type": "application/json;charset=UTF-8",
                "anthropic-beta": "prompt-caching-2024-07-31 tools-2024-05-16",
                "x-modelhub-session-id": "session-a",
                "authorization": "Bearer different-secret",
                "request-id": "trace-b",
                "x-idempotency-key": "alternate-request-key-b",
                "x-amz-security-token": "temporary-secret-b",
                "b3": "trace-context-b",
                "idempotency-key": "request-key-b"
            ],
            body: body
        )
        let differentContentType = BoundedIdempotencyStore.fingerprint(
            method: "POST",
            path: "/v1/messages",
            orderedQuery: "stream=false",
            headers: [
                "content-type": "application/cbor",
                "anthropic-beta": "prompt-caching-2024-07-31 tools-2024-05-16",
                "x-modelhub-session-id": "session-a"
            ],
            body: body
        )
        let differentNativeBusinessHeader = BoundedIdempotencyStore.fingerprint(
            method: "POST",
            path: "/v1/messages",
            orderedQuery: "stream=false",
            headers: [
                "content-type": "application/json;charset=UTF-8",
                "anthropic-beta": "tools-2024-05-16",
                "x-modelhub-session-id": "session-a"
            ],
            body: body
        )
        let differentSession = BoundedIdempotencyStore.fingerprint(
            method: "POST",
            path: "/v1/messages",
            orderedQuery: "stream=false",
            headers: [
                "content-type": "application/json;charset=UTF-8",
                "anthropic-beta": "prompt-caching-2024-07-31 tools-2024-05-16",
                "x-modelhub-session-id": "session-b"
            ],
            body: body
        )

        XCTAssertEqual(first, normalizedEquivalent)
        XCTAssertNotEqual(first, differentContentType)
        XCTAssertNotEqual(first, differentNativeBusinessHeader)
        XCTAssertNotEqual(first, differentSession)
    }

    func testFingerprintMatchesIncrementalSHA256ForLargeBody() {
        let body = Data(repeating: 0x5a, count: 8 * 1_024 * 1_024)
        let digest = BoundedIdempotencyStore.fingerprint(
            method: "POST",
            path: "/v1/videos",
            orderedQuery: "",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(
            digest,
            BoundedIdempotencyStore.fingerprint(
                method: "post",
                path: "/v1/videos",
                orderedQuery: "",
                headers: ["content-type": "application/json"],
                body: body
            )
        )
    }

    func testConcurrentIdempotentFollowersShareOneLeaderResult() async {
        let store = BoundedIdempotencyStore(capacity: 8, ttl: 60)
        let counter = LockedCounter()

        async let first = store.execute(
            scope: "workspace-a",
            key: "create-001",
            fingerprint: "same"
        ) {
            counter.increment()
            try? await Task.sleep(for: .milliseconds(30))
            return IdempotentResponse(statusCode: 202, headers: [:], body: Data("task-1".utf8))
        }
        async let second = store.execute(
            scope: "workspace-a",
            key: "create-001",
            fingerprint: "same"
        ) {
            counter.increment()
            return IdempotentResponse(statusCode: 202, headers: [:], body: Data("task-2".utf8))
        }

        let results = await [first, second]
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(Set(results.compactMap(\.response?.body)).count, 1)
        XCTAssertEqual(results.filter(\.isReplay).count, 1)
    }

    func testIdempotencyRejectsSameKeyWithDifferentFingerprintAndScopesKeys() async {
        let store = BoundedIdempotencyStore(capacity: 8, ttl: 60)
        _ = await store.execute(scope: "a", key: "same", fingerprint: "one") {
            IdempotentResponse(statusCode: 200, headers: [:], body: Data("a".utf8))
        }
        let conflict = await store.execute(scope: "a", key: "same", fingerprint: "two") {
            IdempotentResponse(statusCode: 200, headers: [:], body: Data("wrong".utf8))
        }
        let otherScope = await store.execute(scope: "b", key: "same", fingerprint: "two") {
            IdempotentResponse(statusCode: 200, headers: [:], body: Data("b".utf8))
        }

        XCTAssertEqual(conflict, .conflict)
        XCTAssertEqual(otherScope.response?.body, Data("b".utf8))
    }

    func testAccessPolicyRevisionPartitionsIdempotencyReplayScope() async {
        let store = BoundedIdempotencyStore(capacity: 8, ttl: 60)
        let counter = LockedCounter()

        let original = await store.execute(
            scope: "workspace-a",
            accessPolicyRevision: "allow:model-a",
            key: "same",
            fingerprint: "same"
        ) {
            counter.increment()
            return IdempotentResponse(statusCode: 200, headers: [:], body: Data("v1".utf8))
        }
        let replay = await store.execute(
            scope: "workspace-a",
            accessPolicyRevision: "allow:model-a",
            key: "same",
            fingerprint: "same"
        ) {
            counter.increment()
            return IdempotentResponse(statusCode: 500, headers: [:], body: Data())
        }
        let changedPolicy = await store.execute(
            scope: "workspace-a",
            accessPolicyRevision: "allow:model-b",
            key: "same",
            fingerprint: "same"
        ) {
            counter.increment()
            return IdempotentResponse(statusCode: 200, headers: [:], body: Data("v2".utf8))
        }
        let legacyCall = await store.execute(
            scope: "workspace-b",
            key: "same",
            fingerprint: "same"
        ) {
            counter.increment()
            return IdempotentResponse(statusCode: 200, headers: [:], body: Data("legacy".utf8))
        }
        let legacyReplay = await store.execute(
            scope: "workspace-b",
            key: "same",
            fingerprint: "same"
        ) {
            counter.increment()
            return IdempotentResponse(statusCode: 500, headers: [:], body: Data())
        }

        XCTAssertEqual(original.response?.body, Data("v1".utf8))
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(changedPolicy.response?.body, Data("v2".utf8))
        XCTAssertFalse(changedPolicy.isReplay)
        XCTAssertEqual(legacyCall.response?.body, Data("legacy".utf8))
        XCTAssertTrue(legacyReplay.isReplay)
        XCTAssertEqual(counter.value, 3)
    }

    func testCancellingOneWaiterDoesNotCancelSharedLeaderOrDuplicateExecution() async {
        let store = BoundedIdempotencyStore(capacity: 8, ttl: 60)
        let counter = LockedCounter()
        let leader = Task {
            await store.execute(scope: "a", key: "cancel-safe", fingerprint: "f") {
                counter.increment()
                try? await Task.sleep(for: .milliseconds(40))
                return IdempotentResponse(
                    statusCode: 202,
                    headers: [:],
                    body: Data("shared".utf8)
                )
            }
        }
        try? await Task.sleep(for: .milliseconds(5))
        let follower = Task {
            await store.execute(scope: "a", key: "cancel-safe", fingerprint: "f") {
                counter.increment()
                return IdempotentResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        leader.cancel()

        let followerResult = await follower.value
        XCTAssertEqual(followerResult.response?.body, Data("shared".utf8))
        XCTAssertEqual(counter.value, 1)
    }

    func testIdempotencyTTLAndCapacityAreBounded() async {
        let store = BoundedIdempotencyStore(capacity: 2, ttl: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<3 {
            _ = await store.execute(
                scope: "a",
                key: "key-\(index)",
                fingerprint: "f",
                now: start.addingTimeInterval(Double(index))
            ) {
                IdempotentResponse(statusCode: 200, headers: [:], body: Data())
            }
        }
        let boundedMetrics = await store.metrics(now: start.addingTimeInterval(2))
        XCTAssertEqual(boundedMetrics.entries, 2)

        let expired = await store.execute(
            scope: "a",
            key: "key-2",
            fingerprint: "new",
            now: start.addingTimeInterval(20)
        ) {
            IdempotentResponse(statusCode: 201, headers: [:], body: Data("new".utf8))
        }
        XCTAssertEqual(expired.response?.statusCode, 201)
        XCTAssertFalse(expired.isReplay)
    }

    func testIdempotencyReplayExtendsTTLWithoutChangingLRUSemantics() async {
        let store = BoundedIdempotencyStore(capacity: 2, ttl: 10)
        let start = Date(timeIntervalSince1970: 1_500)
        _ = await store.execute(
            scope: "a",
            key: "first",
            fingerprint: "f",
            now: start
        ) {
            IdempotentResponse(statusCode: 200, headers: [:], body: Data("first".utf8))
        }
        let replay = await store.execute(
            scope: "a",
            key: "first",
            fingerprint: "f",
            now: start.addingTimeInterval(9)
        ) {
            IdempotentResponse(statusCode: 500, headers: [:], body: Data())
        }

        XCTAssertTrue(replay.isReplay)
        let retained = await store.metrics(now: start.addingTimeInterval(11))
        let expired = await store.metrics(now: start.addingTimeInterval(20))
        XCTAssertEqual(retained.entries, 1)
        XCTAssertEqual(expired.entries, 0)
    }

    func testIdempotencyByteBudgetEvictsLeastRecentlyUsedReplayableResponse() async {
        let store = BoundedIdempotencyStore(
            capacity: 4,
            ttl: 60,
            maximumResponseBytes: 100,
            maximumTotalBytes: 150
        )
        let counter = LockedCounter()
        let start = Date(timeIntervalSince1970: 1_600)
        for (index, key) in ["old", "new"].enumerated() {
            _ = await store.execute(
                scope: "a",
                key: key,
                fingerprint: "f",
                now: start.addingTimeInterval(Double(index))
            ) {
                counter.increment()
                return IdempotentResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(repeating: UInt8(index), count: 16)
                )
            }
        }
        let oldAgain = await store.execute(
            scope: "a",
            key: "old",
            fingerprint: "f",
            now: start.addingTimeInterval(2)
        ) {
            counter.increment()
            return IdempotentResponse(statusCode: 201, headers: [:], body: Data())
        }

        XCTAssertFalse(oldAgain.isReplay)
        XCTAssertEqual(oldAgain.response?.statusCode, 201)
        XCTAssertEqual(counter.value, 3)
        let metrics = await store.metrics(now: start.addingTimeInterval(2))
        XCTAssertGreaterThanOrEqual(metrics.evictions, 1)
    }

    func testOversizedIdempotentResponseLeavesANonReplayableSentinel() async {
        let store = BoundedIdempotencyStore(
            capacity: 4,
            ttl: 60,
            maximumResponseBytes: 8,
            maximumTotalBytes: 16
        )
        let counter = LockedCounter()
        let first = await store.execute(
            scope: "a",
            key: "large-response",
            fingerprint: "same"
        ) {
            counter.increment()
            return IdempotentResponse(
                statusCode: 200,
                headers: [:],
                body: Data(repeating: 0x61, count: 9)
            )
        }
        let retry = await store.execute(
            scope: "a",
            key: "large-response",
            fingerprint: "same"
        ) {
            counter.increment()
            return IdempotentResponse(statusCode: 200, headers: [:], body: Data())
        }
        let metrics = await store.metrics()

        XCTAssertEqual(first.response?.body.count, 9)
        XCTAssertEqual(retry, .responseUnavailable)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(metrics.retainedBytes, 0)
        XCTAssertEqual(metrics.unreplayableResponses, 1)
    }

    func testIdempotencyHotPathDoesNotWalkUnexpiredTable() async {
        let store = BoundedIdempotencyStore(capacity: 1_024, ttl: 600)
        let start = Date(timeIntervalSince1970: 10_000)
        for index in 0..<1_000 {
            _ = await store.execute(
                scope: "scope",
                key: "key-\(index)",
                fingerprint: "f",
                now: start
            ) {
                IdempotentResponse(statusCode: 200, headers: [:], body: Data())
            }
        }
        let before = await store.debugMaintenanceStats()
        for index in 0..<200 {
            _ = await store.execute(
                scope: "scope",
                key: "key-\(index)",
                fingerprint: "f",
                now: start.addingTimeInterval(1)
            ) {
                IdempotentResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let after = await store.debugMaintenanceStats()

        XCTAssertEqual(after.expiryHeapPops, before.expiryHeapPops)
        XCTAssertEqual(after.fullTableScans, 0)
    }

    func testStickySessionUsesStableProviderAndModelRatherThanRouteTargetID() async {
        let router = StickySessionRouter(capacity: 16, ttl: 60)
        let provider = UUID()
        let firstGeneration = RouteTarget(providerID: provider, model: " Model-A ")
        await router.recordSuccess(
            accessScope: "primary",
            requestedModel: "alias",
            sessionID: "session-1",
            target: firstGeneration
        )

        let other = RouteTarget(providerID: UUID(), model: "model-b")
        let regeneratedSameTarget = RouteTarget(providerID: provider, model: "model-a")
        let ordered = await router.order(
            candidates: [other, regeneratedSameTarget],
            accessScope: "primary",
            requestedModel: "alias",
            sessionID: "session-1"
        )

        XCTAssertNotEqual(firstGeneration.id, regeneratedSameTarget.id)
        XCTAssertEqual(ordered.first?.providerID, provider)
        let metrics = await router.metrics()
        XCTAssertEqual(metrics.hits, 1)
    }

    func testStickySessionHitExtendsTTL() async {
        let router = StickySessionRouter(capacity: 4, ttl: 10)
        let start = Date(timeIntervalSince1970: 2_000)
        let target = RouteTarget(providerID: UUID(), model: "model")
        await router.recordSuccess(
            accessScope: "scope",
            requestedModel: "alias",
            sessionID: "session",
            target: target,
            now: start
        )
        _ = await router.order(
            candidates: [target],
            accessScope: "scope",
            requestedModel: "alias",
            sessionID: "session",
            now: start.addingTimeInterval(9)
        )

        let retained = await router.metrics(now: start.addingTimeInterval(11))
        let expired = await router.metrics(now: start.addingTimeInterval(20))
        XCTAssertEqual(retained.entries, 1)
        XCTAssertEqual(expired.entries, 0)
    }

    func testStickySessionMigratesWhenTargetDisappearsAndDoesNotExposeRawSessionID() async throws {
        let router = StickySessionRouter(capacity: 1, ttl: 60)
        let old = RouteTarget(providerID: UUID(), model: "old")
        let replacement = RouteTarget(providerID: UUID(), model: "replacement")
        await router.recordSuccess(
            accessScope: "primary",
            requestedModel: "alias",
            sessionID: "private-session",
            target: old
        )

        let ordered = await router.order(
            candidates: [replacement],
            accessScope: "primary",
            requestedModel: "alias",
            sessionID: "private-session"
        )
        await router.recordSuccess(
            accessScope: "primary",
            requestedModel: "alias",
            sessionID: "private-session",
            target: replacement
        )

        XCTAssertEqual(ordered.first?.providerID, replacement.providerID)
        let diagnostics = try JSONEncoder().encode(await router.metrics())
        XCTAssertFalse(String(decoding: diagnostics, as: UTF8.self).contains("private-session"))
    }

    func testStickySessionHotPathDoesNotWalkUnexpiredTableAndStillEvictsLRU() async {
        let router = StickySessionRouter(capacity: 1_000, ttl: 600)
        let start = Date(timeIntervalSince1970: 20_000)
        let target = RouteTarget(providerID: UUID(), model: "model")
        for index in 0..<1_000 {
            await router.recordSuccess(
                accessScope: "scope",
                requestedModel: "alias",
                sessionID: "session-\(index)",
                target: target,
                now: start.addingTimeInterval(Double(index) / 10)
            )
        }
        let before = await router.debugMaintenanceStats()
        for index in 500..<700 {
            _ = await router.order(
                candidates: [target],
                accessScope: "scope",
                requestedModel: "alias",
                sessionID: "session-\(index)",
                now: start.addingTimeInterval(101)
            )
        }
        await router.recordSuccess(
            accessScope: "scope",
            requestedModel: "alias",
            sessionID: "session-new",
            target: target,
            now: start.addingTimeInterval(102)
        )
        let after = await router.debugMaintenanceStats()
        let oldestResult = await router.order(
            candidates: [target],
            accessScope: "scope",
            requestedModel: "alias",
            sessionID: "session-0",
            now: start.addingTimeInterval(102)
        )

        XCTAssertEqual(after.fullTableScans, 0)
        XCTAssertLessThan(after.expiryHeapPops - before.expiryHeapPops, 10)
        XCTAssertEqual(oldestResult, [target])
        let metrics = await router.metrics(now: start.addingTimeInterval(102))
        XCTAssertEqual(metrics.entries, 1_000)
        XCTAssertEqual(metrics.evictions, 1)
        XCTAssertGreaterThanOrEqual(metrics.misses, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
