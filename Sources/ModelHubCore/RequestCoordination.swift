import CryptoKit
import Foundation

public struct IdempotentResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum IdempotencyExecutionResult: Equatable, Sendable {
    case executed(IdempotentResponse)
    case replay(IdempotentResponse)
    case conflict
    case capacityExceeded
    case responseUnavailable

    public var response: IdempotentResponse? {
        switch self {
        case .executed(let response), .replay(let response): response
        case .conflict, .capacityExceeded, .responseUnavailable: nil
        }
    }

    public var isReplay: Bool {
        if case .replay = self { return true }
        return false
    }
}

public struct IdempotencyMetrics: Codable, Equatable, Sendable {
    public let entries: Int
    public let retainedBytes: Int
    public let leaders: UInt64
    public let replays: UInt64
    public let conflicts: UInt64
    public let evictions: UInt64
    public let unreplayableResponses: UInt64
}

struct RequestCoordinationMaintenanceStats: Equatable, Sendable {
    let expiryHeapPops: UInt64
    let lruHeapPops: UInt64
    let fullTableScans: UInt64
}

private struct HeapPriority: Comparable, Sendable {
    let date: Date
    let sequence: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.sequence < rhs.sequence
    }
}

/// A bounded min-heap with stable keys. Updating an existing key replaces its
/// priority in O(log n), so hot keys cannot accumulate stale heap records.
private struct IndexedMinHeap<Key: Hashable> {
    private struct Node {
        let key: Key
        var priority: HeapPriority
    }

    private var nodes: [Node] = []
    private var positions: [Key: Int] = [:]

    var minimum: (key: Key, priority: HeapPriority)? {
        nodes.first.map { ($0.key, $0.priority) }
    }

    mutating func upsert(_ key: Key, priority: HeapPriority) {
        if let index = positions[key] {
            let previous = nodes[index].priority
            nodes[index].priority = priority
            if priority < previous {
                siftUp(from: index)
            } else if previous < priority {
                siftDown(from: index)
            }
            return
        }
        nodes.append(Node(key: key, priority: priority))
        positions[key] = nodes.count - 1
        siftUp(from: nodes.count - 1)
    }

    @discardableResult
    mutating func remove(_ key: Key) -> Bool {
        guard let index = positions.removeValue(forKey: key) else { return false }
        let lastIndex = nodes.count - 1
        if index == lastIndex {
            nodes.removeLast()
            return true
        }
        nodes.swapAt(index, lastIndex)
        nodes.removeLast()
        positions[nodes[index].key] = index
        if index > 0, nodes[index].priority < nodes[(index - 1) / 2].priority {
            siftUp(from: index)
        } else {
            siftDown(from: index)
        }
        return true
    }

    mutating func popMinimum() -> (key: Key, priority: HeapPriority)? {
        guard let first = nodes.first else { return nil }
        _ = remove(first.key)
        return (first.key, first.priority)
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        nodes.removeAll(keepingCapacity: keepingCapacity)
        positions.removeAll(keepingCapacity: keepingCapacity)
    }

    private mutating func siftUp(from startingIndex: Int) {
        var child = startingIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard nodes[child].priority < nodes[parent].priority else { return }
            swap(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from startingIndex: Int) {
        var parent = startingIndex
        while true {
            let left = parent * 2 + 1
            guard left < nodes.count else { return }
            let right = left + 1
            let child = right < nodes.count && nodes[right].priority < nodes[left].priority
                ? right
                : left
            guard nodes[child].priority < nodes[parent].priority else { return }
            swap(parent, child)
            parent = child
        }
    }

    private mutating func swap(_ lhs: Int, _ rhs: Int) {
        nodes.swapAt(lhs, rhs)
        positions[nodes[lhs].key] = lhs
        positions[nodes[rhs].key] = rhs
    }
}

/// An in-memory idempotency coordinator for billable requests. Completed bodies
/// intentionally never enter persistent configuration or diagnostics.
public actor BoundedIdempotencyStore {
    private struct Identity: Hashable, Sendable {
        let scope: String
        let accessPolicyDigest: String?
        let key: String
    }

    private struct Entry: Sendable {
        let fingerprint: String
        var task: Task<IdempotentResponse, Never>?
        var response: IdempotentResponse?
        var responseBytes: Int
        var responseUnavailable: Bool
        var lastAccess: Date
        var expiresAt: Date
    }

    private let capacity: Int
    private let ttl: TimeInterval
    private let maximumResponseBytes: Int
    private let maximumTotalBytes: Int
    private var entries: [Identity: Entry] = [:]
    private var expiryHeap = IndexedMinHeap<Identity>()
    private var evictionHeap = IndexedMinHeap<Identity>()
    private var responseEvictionHeap = IndexedMinHeap<Identity>()
    private var heapSequence: UInt64 = 0
    private var expiryHeapPops: UInt64 = 0
    private var lruHeapPops: UInt64 = 0
    private var retainedBytes = 0
    private var leaders: UInt64 = 0
    private var replays: UInt64 = 0
    private var conflicts: UInt64 = 0
    private var evictions: UInt64 = 0
    private var unreplayableResponses: UInt64 = 0

    public init(
        capacity: Int = 256,
        ttl: TimeInterval = 600,
        maximumResponseBytes: Int = 8 * 1_024 * 1_024,
        maximumTotalBytes: Int = 64 * 1_024 * 1_024
    ) {
        self.capacity = min(1_024, max(1, capacity))
        self.ttl = min(3_600, max(1, ttl))
        self.maximumResponseBytes = min(
            32 * 1_024 * 1_024,
            max(1, maximumResponseBytes)
        )
        self.maximumTotalBytes = min(
            256 * 1_024 * 1_024,
            max(1, maximumTotalBytes)
        )
    }

    public static func isValidKey(_ key: String) -> Bool {
        let utf8 = Array(key.utf8)
        guard !utf8.isEmpty, utf8.count <= 128 else { return false }
        return utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || [45, 46, 58, 95].contains(byte)
        }
    }

    public static func fingerprint(
        method: String,
        path: String,
        orderedQuery: String,
        headers: [String: String] = [:],
        body: Data
    ) -> String {
        var hasher = SHA256()
        updateFingerprint(&hasher, with: Data(method.uppercased().utf8))
        updateFingerprint(&hasher, with: Data(path.utf8))
        updateFingerprint(&hasher, with: Data(orderedQuery.utf8))
        for header in canonicalSemanticHeaders(headers) {
            updateFingerprint(&hasher, with: Data(header.name.utf8))
            updateFingerprint(&hasher, with: Data(header.value.utf8))
        }
        // CryptoKit consumes Data incrementally. Unlike concatenating the
        // complete request above, this does not allocate a second body-sized
        // buffer for large media requests.
        updateFingerprint(&hasher, with: body)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func execute(
        scope: String,
        accessPolicyRevision: String? = nil,
        key: String,
        fingerprint: String,
        now: Date = .now,
        operation: @escaping @Sendable () async -> IdempotentResponse
    ) async -> IdempotencyExecutionResult {
        guard Self.isValidKey(key) else { return .conflict }
        removeExpired(at: now)
        let identity = Identity(
            scope: scope,
            accessPolicyDigest: Self.accessPolicyDigest(accessPolicyRevision),
            key: key
        )

        if var existing = entries[identity] {
            guard existing.fingerprint == fingerprint else {
                conflicts &+= 1
                return .conflict
            }
            existing.lastAccess = now
            existing.expiresAt = now.addingTimeInterval(ttl)
            entries[identity] = existing
            if existing.task == nil {
                indexCompletedEntry(identity, entry: existing)
            }
            if let response = existing.response {
                replays &+= 1
                return .replay(response)
            }
            if let task = existing.task {
                let response = await task.value
                replays &+= 1
                return .replay(response)
            }
            if existing.responseUnavailable {
                return .responseUnavailable
            }
        }

        guard makeRoomIfNeeded() else { return .capacityExceeded }
        // The store, rather than an individual HTTP connection, owns the
        // leader. Cancelling one waiter must not trigger a second billable
        // upstream operation for remaining followers.
        let task = Task.detached(priority: nil) { await operation() }
        entries[identity] = Entry(
            fingerprint: fingerprint,
            task: task,
            response: nil,
            responseBytes: 0,
            responseUnavailable: false,
            lastAccess: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        leaders &+= 1
        let response = await task.value
        if var current = entries[identity], current.fingerprint == fingerprint {
            current.task = nil
            let bytes = Self.storedByteCount(response)
            if makeRoomForResponse(bytes, preserving: identity) {
                current.response = response
                current.responseBytes = bytes
                retainedBytes += bytes
            } else {
                current.responseUnavailable = true
                unreplayableResponses &+= 1
            }
            entries[identity] = current
            indexCompletedEntry(identity, entry: current)
        }
        return .executed(response)
    }

    public func metrics(now: Date = .now) -> IdempotencyMetrics {
        removeExpired(at: now)
        return IdempotencyMetrics(
            entries: entries.count,
            retainedBytes: retainedBytes,
            leaders: leaders,
            replays: replays,
            conflicts: conflicts,
            evictions: evictions,
            unreplayableResponses: unreplayableResponses
        )
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: false)
        expiryHeap.removeAll()
        evictionHeap.removeAll()
        responseEvictionHeap.removeAll()
        retainedBytes = 0
    }

    func debugMaintenanceStats() -> RequestCoordinationMaintenanceStats {
        RequestCoordinationMaintenanceStats(
            expiryHeapPops: expiryHeapPops,
            lruHeapPops: lruHeapPops,
            fullTableScans: 0
        )
    }

    private func removeExpired(at now: Date) {
        while let minimum = expiryHeap.minimum, minimum.priority.date <= now {
            guard let identity = expiryHeap.popMinimum()?.key else { break }
            expiryHeapPops &+= 1
            removeEntry(identity)
        }
    }

    private func makeRoomIfNeeded() -> Bool {
        guard entries.count >= capacity else { return true }
        guard let oldest = evictionHeap.popMinimum()?.key else { return false }
        lruHeapPops &+= 1
        removeEntry(oldest)
        evictions &+= 1
        return true
    }

    private func makeRoomForResponse(_ bytes: Int, preserving identity: Identity) -> Bool {
        guard bytes <= maximumResponseBytes, bytes <= maximumTotalBytes else {
            return false
        }
        while retainedBytes > maximumTotalBytes - bytes {
            guard let oldest = responseEvictionHeap.popMinimum()?.key,
                  oldest != identity
            else { return false }
            lruHeapPops &+= 1
            removeEntry(oldest)
            evictions &+= 1
        }
        return true
    }

    private func removeEntry(_ identity: Identity) {
        guard let removed = entries.removeValue(forKey: identity) else { return }
        _ = expiryHeap.remove(identity)
        _ = evictionHeap.remove(identity)
        _ = responseEvictionHeap.remove(identity)
        retainedBytes = max(0, retainedBytes - removed.responseBytes)
    }

    private func indexCompletedEntry(_ identity: Identity, entry: Entry) {
        heapSequence &+= 1
        expiryHeap.upsert(
            identity,
            priority: HeapPriority(date: entry.expiresAt, sequence: heapSequence)
        )
        heapSequence &+= 1
        let accessPriority = HeapPriority(date: entry.lastAccess, sequence: heapSequence)
        evictionHeap.upsert(identity, priority: accessPriority)
        if entry.response != nil {
            responseEvictionHeap.upsert(identity, priority: accessPriority)
        } else {
            _ = responseEvictionHeap.remove(identity)
        }
    }

    private static func accessPolicyDigest(_ revision: String?) -> String? {
        guard let revision, !revision.isEmpty else { return nil }
        return SHA256.hash(data: Data(revision.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func updateFingerprint(_ hasher: inout SHA256, with data: Data) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }

    private static func canonicalSemanticHeaders(
        _ headers: [String: String]
    ) -> [(name: String, value: String)] {
        var grouped: [String: [String]] = [:]
        for (rawName, rawValue) in headers {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, !isExcludedFingerprintHeader(name) else { continue }
            let value = name == "content-type"
                ? canonicalContentType(rawValue)
                : canonicalHeaderValue(rawValue)
            grouped[name, default: []].append(value)
        }
        return grouped.keys.sorted().map { name in
            let value = grouped[name, default: []].sorted().joined(separator: "\u{1f}")
            return (name, value)
        }
    }

    private static func isExcludedFingerprintHeader(_ name: String) -> Bool {
        if name == "authorization" || name == "proxy-authorization"
            || name == "cookie" || name == "set-cookie"
            || name == "api-key" || name == "x-api-key"
            || name == "x-auth-token" || name == "anthropic-api-key"
            || name == "x-amz-security-token" || name == "ocp-apim-subscription-key"
            || name == "idempotency-key" || name == "x-idempotency-key"
            || name == "request-id" || name == "x-request-id"
            || name.hasSuffix("-request-id") || name.hasSuffix("-requestid")
            || name == "x-correlation-id" || name == "traceparent"
            || name == "tracestate" || name == "baggage" || name == "b3"
            || name.hasPrefix("x-b3-") || name == "sentry-trace"
            || name == "x-cloud-trace-context"
            || name == "connection" || name == "keep-alive"
            || name == "proxy-authenticate" || name == "te" || name == "trailer"
            || name == "transfer-encoding" || name == "upgrade" || name == "host"
            || name == "content-length" || name == "accept-encoding"
            || name == "user-agent" || name == "date" || name == "via"
            || name == "forwarded" || name.hasPrefix("x-forwarded-")
        {
            return true
        }
        return name.hasSuffix("-api-key")
    }

    private static func canonicalContentType(_ value: String) -> String {
        let parts = value.split(separator: ";", omittingEmptySubsequences: true)
        guard let mediaType = parts.first else { return "" }
        let normalizedType = mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parameters = parts.dropFirst().map { part -> String in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard pair.count == 2 else { return name }
            var parameterValue = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "charset" { parameterValue = parameterValue.lowercased() }
            return "\(name)=\(parameterValue)"
        }.sorted()
        return ([normalizedType] + parameters).joined(separator: ";")
    }

    private static func canonicalHeaderValue(_ value: String) -> String {
        var result = ""
        var inQuotes = false
        var pendingWhitespace = false
        for character in value.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character == "\"" {
                if pendingWhitespace, !result.isEmpty { result.append(" ") }
                pendingWhitespace = false
                inQuotes.toggle()
                result.append(character)
            } else if character.isWhitespace, !inQuotes {
                pendingWhitespace = true
            } else {
                if pendingWhitespace, !result.isEmpty { result.append(" ") }
                pendingWhitespace = false
                result.append(character)
            }
        }
        return result
    }

    private static func storedByteCount(_ response: IdempotentResponse) -> Int {
        response.headers.reduce(response.body.count + 64) { total, header in
            let (partial, overflowA) = total.addingReportingOverflow(header.key.utf8.count)
            let (result, overflowB) = partial.addingReportingOverflow(header.value.utf8.count)
            return overflowA || overflowB ? Int.max : result
        }
    }
}

public struct StickySessionMetrics: Codable, Equatable, Sendable {
    public let entries: Int
    public let hits: UInt64
    public let misses: UInt64
    public let migrations: UInt64
    public let evictions: UInt64
}

/// Keeps session affinity without retaining the caller's session identifier.
/// A target identity is stable across regenerated RouteTarget UUIDs.
public actor StickySessionRouter {
    private struct SessionKey: Hashable, Sendable {
        let digest: String
    }

    private struct StableTarget: Hashable, Sendable {
        let providerID: UUID
        let model: String

        init(_ target: RouteTarget) {
            providerID = target.providerID
            model = Self.normalize(target.model)
        }

        static func normalize(_ model: String) -> String {
            model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private struct Binding: Sendable {
        var target: StableTarget
        var lastAccess: Date
        var expiresAt: Date
    }

    private let capacity: Int
    private let ttl: TimeInterval
    private var bindings: [SessionKey: Binding] = [:]
    private var expiryHeap = IndexedMinHeap<SessionKey>()
    private var evictionHeap = IndexedMinHeap<SessionKey>()
    private var heapSequence: UInt64 = 0
    private var expiryHeapPops: UInt64 = 0
    private var lruHeapPops: UInt64 = 0
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0
    private var migrations: UInt64 = 0
    private var evictions: UInt64 = 0

    public init(capacity: Int = 1_024, ttl: TimeInterval = 1_800) {
        self.capacity = min(10_000, max(1, capacity))
        self.ttl = min(86_400, max(1, ttl))
    }

    public func order(
        candidates: [RouteTarget],
        accessScope: String,
        requestedModel: String,
        sessionID: String,
        now: Date = .now
    ) -> [RouteTarget] {
        guard let key = Self.key(
            accessScope: accessScope,
            requestedModel: requestedModel,
            sessionID: sessionID
        ) else {
            misses &+= 1
            return candidates
        }
        removeExpired(at: now)
        guard var binding = bindings[key] else {
            misses &+= 1
            return candidates
        }
        guard let preferredIndex = candidates.firstIndex(where: {
            StableTarget($0) == binding.target
        }) else {
            migrations &+= 1
            return candidates
        }
        binding.lastAccess = now
        binding.expiresAt = now.addingTimeInterval(ttl)
        bindings[key] = binding
        indexBinding(key, binding: binding)
        hits &+= 1
        guard preferredIndex != candidates.startIndex else { return candidates }
        var ordered = candidates
        let preferred = ordered.remove(at: preferredIndex)
        ordered.insert(preferred, at: 0)
        return ordered
    }

    public func recordSuccess(
        accessScope: String,
        requestedModel: String,
        sessionID: String,
        target: RouteTarget,
        now: Date = .now
    ) {
        guard let key = Self.key(
            accessScope: accessScope,
            requestedModel: requestedModel,
            sessionID: sessionID
        ) else { return }
        removeExpired(at: now)
        let stable = StableTarget(target)
        if let existing = bindings[key], existing.target != stable {
            migrations &+= 1
        }
        if bindings[key] == nil, bindings.count >= capacity,
           let oldest = evictionHeap.popMinimum()?.key
        {
            lruHeapPops &+= 1
            bindings.removeValue(forKey: oldest)
            _ = expiryHeap.remove(oldest)
            evictions &+= 1
        }
        let binding = Binding(
            target: stable,
            lastAccess: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        bindings[key] = binding
        indexBinding(key, binding: binding)
    }

    public func metrics(now: Date = .now) -> StickySessionMetrics {
        removeExpired(at: now)
        return StickySessionMetrics(
            entries: bindings.count,
            hits: hits,
            misses: misses,
            migrations: migrations,
            evictions: evictions
        )
    }

    func debugMaintenanceStats() -> RequestCoordinationMaintenanceStats {
        RequestCoordinationMaintenanceStats(
            expiryHeapPops: expiryHeapPops,
            lruHeapPops: lruHeapPops,
            fullTableScans: 0
        )
    }

    private static func key(
        accessScope: String,
        requestedModel: String,
        sessionID: String
    ) -> SessionKey? {
        let bytes = Array(sessionID.utf8)
        guard !bytes.isEmpty, bytes.count <= 128, bytes.allSatisfy({ byte in
            byte >= 33 && byte <= 126
        }) else { return nil }
        var data = Data(accessScope.utf8)
        data.append(0)
        data.append(contentsOf: requestedModel.lowercased().utf8)
        data.append(0)
        data.append(contentsOf: bytes)
        return SessionKey(
            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    private func removeExpired(at now: Date) {
        while let minimum = expiryHeap.minimum, minimum.priority.date <= now {
            guard let key = expiryHeap.popMinimum()?.key else { break }
            expiryHeapPops &+= 1
            bindings.removeValue(forKey: key)
            _ = evictionHeap.remove(key)
        }
    }

    private func indexBinding(_ key: SessionKey, binding: Binding) {
        heapSequence &+= 1
        expiryHeap.upsert(
            key,
            priority: HeapPriority(date: binding.expiresAt, sequence: heapSequence)
        )
        heapSequence &+= 1
        evictionHeap.upsert(
            key,
            priority: HeapPriority(date: binding.lastAccess, sequence: heapSequence)
        )
    }
}
