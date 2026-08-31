import Foundation

public struct PassiveHealthConfiguration: Equatable, Sendable {
    public static let maximumEventCount = 200
    public static let maximumTargetStateCount = 4_096
    public static let maximumTargetStateTTLSeconds: TimeInterval = 30 * 24 * 60 * 60

    public var eventLimit: Int
    public var windowSize: Int
    public var failureThreshold: Int
    public var highLatencyThreshold: Int
    public var highLatencyMilliseconds: Int
    public var cooldownSeconds: TimeInterval
    public var targetStateLimit: Int
    public var targetStateTTLSeconds: TimeInterval

    public init(
        eventLimit: Int = PassiveHealthConfiguration.maximumEventCount,
        windowSize: Int = 10,
        failureThreshold: Int = 3,
        highLatencyThreshold: Int = 3,
        highLatencyMilliseconds: Int = 2_000,
        cooldownSeconds: TimeInterval = 300,
        targetStateLimit: Int = 1_024,
        targetStateTTLSeconds: TimeInterval = 24 * 60 * 60
    ) {
        let boundedEventLimit = min(
            max(1, eventLimit),
            PassiveHealthConfiguration.maximumEventCount
        )
        let boundedWindowSize = min(max(1, windowSize), boundedEventLimit)
        self.eventLimit = boundedEventLimit
        self.windowSize = boundedWindowSize
        self.failureThreshold = min(max(1, failureThreshold), boundedWindowSize)
        self.highLatencyThreshold = min(max(1, highLatencyThreshold), boundedWindowSize)
        self.highLatencyMilliseconds = max(1, highLatencyMilliseconds)
        self.cooldownSeconds = max(0, cooldownSeconds)
        self.targetStateLimit = min(
            max(1, targetStateLimit),
            Self.maximumTargetStateCount
        )
        self.targetStateTTLSeconds = min(
            max(1, targetStateTTLSeconds),
            Self.maximumTargetStateTTLSeconds
        )
    }
}

public enum PassiveHealthTransportFailure: String, Equatable, Sendable {
    case timedOut
    case connectionLost
    case nameResolution
    case secureConnection
    case unavailable
}

public enum PassiveHealthOutcome: Equatable, Sendable {
    case http(statusCode: Int)
    case transport(PassiveHealthTransportFailure)
}

public struct PassiveHealthEvent: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var providerID: UUID
    public var targetID: String
    public var outcome: PassiveHealthOutcome
    public var latencyMilliseconds: Int
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        providerID: UUID,
        targetID: String,
        outcome: PassiveHealthOutcome,
        latencyMilliseconds: Int,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.providerID = providerID
        self.targetID = targetID
        self.outcome = outcome
        self.latencyMilliseconds = max(0, latencyMilliseconds)
        self.recordedAt = recordedAt
    }
}

public enum PassiveHealthAlertKind: String, Equatable, Sendable {
    case failureRate
    case highLatency
    case recovered
}

public struct PassiveHealthAlert: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var providerID: UUID
    public var targetID: String
    public var kind: PassiveHealthAlertKind
    public var matchingEventCount: Int
    public var emittedAt: Date

    public init(
        id: UUID = UUID(),
        providerID: UUID,
        targetID: String,
        kind: PassiveHealthAlertKind,
        matchingEventCount: Int,
        emittedAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.targetID = targetID
        self.kind = kind
        self.matchingEventCount = max(0, matchingEventCount)
        self.emittedAt = emittedAt
    }
}

struct PassiveHealthMaintenanceStats: Equatable, Sendable {
    let trackedTargets: Int
    let fullStateScans: UInt64
    let evictions: UInt64
    let droppedNewTargets: UInt64
}

public actor PassiveHealthMonitor {
    private struct TargetKey: Hashable, Sendable {
        var providerID: UUID
        var targetID: String
    }

    private struct TargetState: Sendable {
        var activeKind: PassiveHealthAlertKind?
        var activeSince: Date?
        var activeCount = 0
        var notificationDelivered = false
        var lastDegradedNotificationAt: Date?
        var healthEvents: [PassiveHealthEvent] = []
        var lastUsedAt = Date.distantPast
    }

    private enum Classification: Equatable {
        case healthy
        case highLatency
        case failure
        case saturation
        case ignored
    }

    private let configuration: PassiveHealthConfiguration
    private var events: [PassiveHealthEvent] = []
    private var states: [TargetKey: TargetState] = [:]
    private var fullStateScans: UInt64 = 0
    private var stateEvictions: UInt64 = 0
    private var droppedNewTargets: UInt64 = 0

    public init(configuration: PassiveHealthConfiguration = .init()) {
        self.configuration = configuration
        events.reserveCapacity(configuration.eventLimit)
    }

    @discardableResult
    public func record(_ event: PassiveHealthEvent) -> PassiveHealthAlert? {
        events.append(event)
        if events.count > configuration.eventLimit {
            events.removeFirst(events.count - configuration.eventLimit)
        }

        let classification = classify(event)
        let key = TargetKey(providerID: event.providerID, targetID: event.targetID)
        guard classification != .ignored, classification != .saturation else {
            // Saturation and ordinary client errors are not health evidence, but
            // they are still recent use of an already-tracked target. Touching
            // only an existing state protects a live alert from TTL eviction
            // without letting noise allocate new state or enter the window.
            if var state = states[key] {
                state.lastUsedAt = max(state.lastUsedAt, event.recordedAt)
                states[key] = state
            }
            return nil
        }

        var state = states[key] ?? TargetState()
        state.lastUsedAt = max(state.lastUsedAt, event.recordedAt)
        state.healthEvents.append(event)
        if state.healthEvents.count > configuration.windowSize {
            state.healthEvents.removeFirst(
                state.healthEvents.count - configuration.windowSize
            )
        }

        if let activeKind = state.activeKind {
            if classification == .healthy {
                let shouldNotifyRecovery = state.notificationDelivered
                state.activeKind = nil
                state.activeSince = nil
                state.activeCount = 0
                state.notificationDelivered = false
                state.healthEvents = [event]
                _ = storeState(state, for: key, at: event.recordedAt)
                guard shouldNotifyRecovery else {
                    return nil
                }
                return PassiveHealthAlert(
                    providerID: event.providerID,
                    targetID: event.targetID,
                    kind: .recovered,
                    matchingEventCount: 1,
                    emittedAt: event.recordedAt
                )
            }

            if !state.notificationDelivered,
               cooldownHasElapsed(state: state, at: event.recordedAt) {
                state.notificationDelivered = true
                state.lastDegradedNotificationAt = event.recordedAt
                _ = storeState(state, for: key, at: event.recordedAt)
                return PassiveHealthAlert(
                    providerID: event.providerID,
                    targetID: event.targetID,
                    kind: activeKind,
                    matchingEventCount: state.activeCount,
                    emittedAt: event.recordedAt
                )
            }
            _ = storeState(state, for: key, at: event.recordedAt)
            return nil
        }

        let targetWindow = healthWindow(state: state)
        let failures = targetWindow.reduce(into: 0) { count, sample in
            if classify(sample) == .failure {
                count += 1
            }
        }
        let slowSamples = targetWindow.reduce(into: 0) { count, sample in
            if classify(sample) == .highLatency {
                count += 1
            }
        }

        let newKind: PassiveHealthAlertKind?
        let matchingCount: Int
        if failures >= configuration.failureThreshold {
            newKind = .failureRate
            matchingCount = failures
        } else if slowSamples >= configuration.highLatencyThreshold {
            newKind = .highLatency
            matchingCount = slowSamples
        } else {
            newKind = nil
            matchingCount = 0
        }

        guard let newKind else {
            _ = storeState(state, for: key, at: event.recordedAt)
            return nil
        }

        state.activeKind = newKind
        state.activeSince = event.recordedAt
        state.activeCount = matchingCount
        let shouldNotify = cooldownHasElapsed(state: state, at: event.recordedAt)
        state.notificationDelivered = shouldNotify
        if shouldNotify {
            state.lastDegradedNotificationAt = event.recordedAt
        }
        guard storeState(state, for: key, at: event.recordedAt) else {
            return nil
        }

        guard shouldNotify else {
            return nil
        }
        return PassiveHealthAlert(
            providerID: event.providerID,
            targetID: event.targetID,
            kind: newKind,
            matchingEventCount: matchingCount,
            emittedAt: event.recordedAt
        )
    }

    public func history() -> [PassiveHealthEvent] {
        events
    }

    public func activeAlerts() -> [PassiveHealthAlert] {
        states.compactMap { key, state in
            guard let kind = state.activeKind,
                  let activeSince = state.activeSince else {
                return nil
            }
            return PassiveHealthAlert(
                providerID: key.providerID,
                targetID: key.targetID,
                kind: kind,
                matchingEventCount: state.activeCount,
                emittedAt: activeSince
            )
        }
        .sorted {
            if $0.emittedAt != $1.emittedAt {
                return $0.emittedAt < $1.emittedAt
            }
            if $0.providerID != $1.providerID {
                return $0.providerID.uuidString < $1.providerID.uuidString
            }
            return $0.targetID < $1.targetID
        }
    }

    func debugTrackedTargetIDs() -> [String] {
        states.keys.map(\.targetID).sorted()
    }

    func debugMaintenanceStats() -> PassiveHealthMaintenanceStats {
        PassiveHealthMaintenanceStats(
            trackedTargets: states.count,
            fullStateScans: fullStateScans,
            evictions: stateEvictions,
            droppedNewTargets: droppedNewTargets
        )
    }

    private func classify(_ event: PassiveHealthEvent) -> Classification {
        switch event.outcome {
        case let .http(statusCode):
            if (200..<400).contains(statusCode) {
                return event.latencyMilliseconds >= configuration.highLatencyMilliseconds
                    ? .highLatency
                    : .healthy
            }
            if statusCode == 429 {
                return .saturation
            }
            if (400..<500).contains(statusCode), statusCode != 408 {
                return .ignored
            }
            return .failure
        case .transport:
            return .failure
        }
    }

    private func healthWindow(state: TargetState) -> [PassiveHealthEvent] {
        state.healthEvents.filter { sample in
            let classification = classify(sample)
            return classification != .ignored && classification != .saturation
        }
    }

    @discardableResult
    private func storeState(
        _ state: TargetState,
        for key: TargetKey,
        at date: Date
    ) -> Bool {
        if states[key] != nil {
            states[key] = state
            return true
        }
        guard makeRoomForNewState(at: date) else {
            droppedNewTargets &+= 1
            return false
        }
        states[key] = state
        return true
    }

    /// Existing targets never scan the table. A bounded deterministic scan is
    /// performed only when a new target arrives at capacity: expired state is
    /// evicted first (including a stale alert), then the oldest inactive state.
    /// Recently active alerts are never displaced to admit a new target.
    private func makeRoomForNewState(at date: Date) -> Bool {
        guard states.count >= configuration.targetStateLimit else { return true }
        fullStateScans &+= 1

        let expired = states.filter { _, state in
            date.timeIntervalSince(state.lastUsedAt)
                >= configuration.targetStateTTLSeconds
        }
        let candidates = expired.isEmpty
            ? states.filter { _, state in state.activeKind == nil }
            : expired
        guard let victim = candidates.min(by: { lhs, rhs in
            if lhs.value.lastUsedAt != rhs.value.lastUsedAt {
                return lhs.value.lastUsedAt < rhs.value.lastUsedAt
            }
            if lhs.key.providerID != rhs.key.providerID {
                return lhs.key.providerID.uuidString < rhs.key.providerID.uuidString
            }
            return lhs.key.targetID < rhs.key.targetID
        })?.key else {
            return false
        }
        states.removeValue(forKey: victim)
        stateEvictions &+= 1
        return true
    }

    private func cooldownHasElapsed(state: TargetState, at date: Date) -> Bool {
        guard let lastNotificationAt = state.lastDegradedNotificationAt else {
            return true
        }
        return date.timeIntervalSince(lastNotificationAt) >= configuration.cooldownSeconds
    }
}

/// Serializes passive-health processing behind a fixed queue bound. A traffic
/// burst creates at most one drain task instead of one untracked task per
/// gateway response. When the queue is full, health telemetry is dropped while
/// the user request remains unaffected.
public actor BoundedPassiveHealthEventBuffer {
    public typealias Processor = @Sendable (PassiveHealthEvent) async -> Void

    private let capacity: Int
    private let processor: Processor
    private var events: [PassiveHealthEvent] = []
    private var head = 0
    private var isDraining = false
    private var dropped: UInt64 = 0

    public init(capacity: Int = 1_024, processor: @escaping Processor) {
        self.capacity = min(max(1, capacity), 16_384)
        self.processor = processor
    }

    @discardableResult
    public func enqueue(_ event: PassiveHealthEvent) -> Bool {
        guard events.count - head < capacity else {
            dropped &+= 1
            return false
        }
        events.append(event)
        guard !isDraining else { return true }
        isDraining = true
        Task { await drain() }
        return true
    }

    public func pendingCount() -> Int {
        events.count - head
    }

    public func droppedCount() -> UInt64 {
        dropped
    }

    private func drain() async {
        while head < events.count {
            let event = events[head]
            head += 1
            await processor(event)
            if head >= 256, head * 2 >= events.count {
                events.removeFirst(head)
                head = 0
            }
        }
        events.removeAll(keepingCapacity: true)
        head = 0
        isDraining = false
    }
}
