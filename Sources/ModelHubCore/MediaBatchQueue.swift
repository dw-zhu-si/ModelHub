import Foundation

public enum MediaBatchKind: String, CaseIterable, Codable, Equatable, Sendable {
    case image
    case music
    case video
}

public struct MediaBatchMetadata: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MediaBatchKind
    public var providerID: UUID
    public var modelID: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: MediaBatchKind,
        providerID: UUID,
        modelID: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.providerID = providerID
        self.modelID = modelID
        self.createdAt = createdAt
    }
}

public enum MediaBatchRemoteState: Equatable, Sendable {
    case pending
    case succeeded
    case failed
}

public struct MediaBatchArtifact: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var remoteURL: URL?
    public var localFileURL: URL?
    public var mimeType: String?
    public var byteCount: Int?

    public init(
        id: UUID = UUID(),
        remoteURL: URL? = nil,
        localFileURL: URL? = nil,
        mimeType: String? = nil,
        byteCount: Int? = nil
    ) {
        self.id = id
        self.remoteURL = remoteURL
        self.localFileURL = localFileURL
        self.mimeType = mimeType.map { String($0.prefix(160)) }
        self.byteCount = byteCount.map { max(0, $0) }
    }

    public var openURL: URL? { localFileURL ?? remoteURL }
}

public struct MediaBatchResult: Codable, Equatable, Sendable {
    public var artifacts: [MediaBatchArtifact]

    public init(artifacts: [MediaBatchArtifact] = []) {
        self.artifacts = Array(artifacts.prefix(16))
    }

    public static let empty = MediaBatchResult()
}

public protocol MediaBatchExecuting: Sendable {
    func create(_ metadata: MediaBatchMetadata) async throws -> String
    func poll(
        remoteTaskID: String,
        metadata: MediaBatchMetadata
    ) async throws -> MediaBatchRemoteState
    func result(for metadata: MediaBatchMetadata) async -> MediaBatchResult?
}

public extension MediaBatchExecuting {
    func result(for metadata: MediaBatchMetadata) async -> MediaBatchResult? { nil }
}

public enum MediaBatchFailure: Equatable, Sendable {
    case creationFailed
    case remoteFailed
    case pollingExhausted(attempts: Int)
}

public enum MediaBatchJobState: Equatable, Sendable {
    case queued
    case creating
    case polling(remoteTaskID: String, attempt: Int)
    case succeeded(remoteTaskID: String)
    case failed(MediaBatchFailure)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .queued, .creating, .polling:
            return false
        }
    }

    public var isSucceeded: Bool {
        if case .succeeded = self {
            return true
        }
        return false
    }
}

public struct MediaBatchJob: Equatable, Identifiable, Sendable {
    public var id: UUID { metadata.id }
    public var metadata: MediaBatchMetadata
    public var state: MediaBatchJobState
    public var updatedAt: Date
    public var result: MediaBatchResult

    public init(
        metadata: MediaBatchMetadata,
        state: MediaBatchJobState = .queued,
        updatedAt: Date = Date(),
        result: MediaBatchResult = .empty
    ) {
        self.metadata = metadata
        self.state = state
        self.updatedAt = updatedAt
        self.result = result
    }
}

public enum MediaBatchQueueError: Error, Equatable, Sendable {
    case feeConfirmationRequired
    case capacityExceeded(maximum: Int)
    case duplicateJobID
}

public actor MediaBatchQueue {
    public static let hardMaximumJobs = 200
    public static let hardMaximumConcurrentJobs = 8
    public static let hardMaximumPollAttempts = 10

    private let executor: any MediaBatchExecuting
    private let maximumJobs: Int
    private let maximumConcurrentJobs: Int
    private let maximumPollAttempts: Int
    private let pollIntervalMilliseconds: Int
    private var paused = false
    private var orderedIDs: [UUID] = []
    private var pendingIDs: [UUID] = []
    private var dispatchedIDs: [UUID] = []
    private var storedJobs: [UUID: MediaBatchJob] = [:]
    private var activeIDs: Set<UUID> = []
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        executor: any MediaBatchExecuting,
        maximumJobs: Int = 100,
        maximumConcurrentJobs: Int = 2,
        maximumPollAttempts: Int = 4,
        pollIntervalMilliseconds: Int = 0
    ) {
        self.executor = executor
        self.maximumJobs = min(max(1, maximumJobs), Self.hardMaximumJobs)
        self.maximumConcurrentJobs = min(
            max(1, maximumConcurrentJobs),
            Self.hardMaximumConcurrentJobs
        )
        self.maximumPollAttempts = min(
            max(1, maximumPollAttempts),
            Self.hardMaximumPollAttempts
        )
        self.pollIntervalMilliseconds = min(max(0, pollIntervalMilliseconds), 30_000)
        orderedIDs.reserveCapacity(self.maximumJobs)
        pendingIDs.reserveCapacity(self.maximumJobs)
    }

    @discardableResult
    public func enqueue(
        _ metadata: MediaBatchMetadata,
        feeConfirmed: Bool
    ) throws -> MediaBatchJob {
        guard feeConfirmed else {
            throw MediaBatchQueueError.feeConfirmationRequired
        }
        guard storedJobs[metadata.id] == nil else {
            throw MediaBatchQueueError.duplicateJobID
        }
        try makeRoomIfPossible()

        let job = MediaBatchJob(
            metadata: metadata,
            state: .queued,
            updatedAt: metadata.createdAt
        )
        storedJobs[metadata.id] = job
        orderedIDs.append(metadata.id)
        pendingIDs.append(metadata.id)
        scheduleAvailableWork()
        return job
    }

    public func pause() {
        paused = true
        resumeIdleWaitersIfNeeded()
    }

    public func resume() {
        paused = false
        scheduleAvailableWork()
    }

    public func cancel(id: UUID) {
        guard var job = storedJobs[id], !job.state.isTerminal else {
            return
        }
        job.state = .cancelled
        job.updatedAt = Date()
        storedJobs[id] = job
        pendingIDs.removeAll { $0 == id }
        runningTasks[id]?.cancel()

        if !activeIDs.contains(id) {
            runningTasks.removeValue(forKey: id)
            scheduleAvailableWork()
            resumeIdleWaitersIfNeeded()
        }
    }

    public func jobs() -> [MediaBatchJob] {
        orderedIDs.compactMap { storedJobs[$0] }
    }

    public func job(id: UUID) -> MediaBatchJob? {
        storedJobs[id]
    }

    public func dispatchHistory() -> [UUID] {
        dispatchedIDs
    }

    public func awaitIdle() async {
        guard !isIdle else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func makeRoomIfPossible() throws {
        guard storedJobs.count >= maximumJobs else {
            return
        }
        if let evictableID = orderedIDs.first(where: { storedJobs[$0]?.state.isTerminal == true }) {
            orderedIDs.removeAll { $0 == evictableID }
            dispatchedIDs.removeAll { $0 == evictableID }
            storedJobs.removeValue(forKey: evictableID)
            return
        }
        throw MediaBatchQueueError.capacityExceeded(maximum: maximumJobs)
    }

    private func scheduleAvailableWork() {
        guard !paused else {
            return
        }

        while activeIDs.count < maximumConcurrentJobs, !pendingIDs.isEmpty {
            let id = pendingIDs.removeFirst()
            guard var job = storedJobs[id], job.state == .queued else {
                continue
            }
            job.state = .creating
            job.updatedAt = Date()
            storedJobs[id] = job
            activeIDs.insert(id)
            dispatchedIDs.append(id)
            runningTasks[id] = Task { await self.execute(id: id) }
        }
    }

    private func execute(id: UUID) async {
        guard let metadata = storedJobs[id]?.metadata else {
            finishExecution(id: id, state: nil)
            return
        }

        let remoteTaskID: String
        do {
            remoteTaskID = try await executor.create(metadata)
        } catch {
            finishExecution(
                id: id,
                state: Task.isCancelled ? .cancelled : .failed(.creationFailed)
            )
            return
        }

        if Task.isCancelled || storedJobs[id]?.state == .cancelled {
            finishExecution(id: id, state: .cancelled)
            return
        }

        for attempt in 1...maximumPollAttempts {
            if Task.isCancelled || storedJobs[id]?.state == .cancelled {
                finishExecution(id: id, state: .cancelled)
                return
            }

            updateState(
                id: id,
                state: .polling(remoteTaskID: remoteTaskID, attempt: attempt)
            )
            do {
                switch try await executor.poll(remoteTaskID: remoteTaskID, metadata: metadata) {
                case .pending:
                    if attempt == maximumPollAttempts {
                        finishExecution(
                            id: id,
                            state: .failed(.pollingExhausted(attempts: maximumPollAttempts))
                        )
                        return
                    }
                    await waitBeforeNextPoll()
                case .succeeded:
                    let result = await executor.result(for: metadata) ?? .empty
                    let usableResult = Self.usableResult(from: result)
                    guard !usableResult.artifacts.isEmpty else {
                        finishExecution(id: id, state: .failed(.remoteFailed))
                        return
                    }
                    finishExecution(
                        id: id,
                        state: .succeeded(remoteTaskID: remoteTaskID),
                        result: usableResult
                    )
                    return
                case .failed:
                    finishExecution(id: id, state: .failed(.remoteFailed))
                    return
                }
            } catch {
                if attempt == maximumPollAttempts {
                    finishExecution(
                        id: id,
                        state: Task.isCancelled
                            ? .cancelled
                            : .failed(.pollingExhausted(attempts: maximumPollAttempts))
                    )
                    return
                }
                await waitBeforeNextPoll()
            }
        }
    }

    private static func usableResult(from result: MediaBatchResult) -> MediaBatchResult {
        MediaBatchResult(artifacts: result.artifacts.filter { artifact in
            if let localFileURL = artifact.localFileURL {
                return localFileURL.isFileURL
            }
            guard let remoteURL = artifact.remoteURL else { return false }
            return remoteURL.scheme?.lowercased() == "https"
                && remoteURL.user == nil
                && remoteURL.password == nil
                && remoteURL.fragment == nil
        })
    }

    private func waitBeforeNextPoll() async {
        guard pollIntervalMilliseconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(pollIntervalMilliseconds))
    }

    private func updateState(id: UUID, state: MediaBatchJobState) {
        guard var job = storedJobs[id], job.state != .cancelled else {
            return
        }
        job.state = state
        job.updatedAt = Date()
        storedJobs[id] = job
    }

    private func finishExecution(
        id: UUID,
        state: MediaBatchJobState?,
        result: MediaBatchResult? = nil
    ) {
        if let state, var job = storedJobs[id], job.state != .cancelled {
            job.state = state
            job.updatedAt = Date()
            if let result { job.result = result }
            storedJobs[id] = job
        }
        activeIDs.remove(id)
        runningTasks.removeValue(forKey: id)
        scheduleAvailableWork()
        resumeIdleWaitersIfNeeded()
    }

    private var isIdle: Bool {
        activeIDs.isEmpty && (paused || pendingIDs.isEmpty)
    }

    private func resumeIdleWaitersIfNeeded() {
        guard isIdle, !idleWaiters.isEmpty else {
            return
        }
        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }
}
