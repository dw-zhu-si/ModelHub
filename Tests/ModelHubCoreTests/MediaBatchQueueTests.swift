import Foundation
import XCTest
@testable import ModelHubCore

final class MediaBatchQueueTests: XCTestCase {
    func testFeeConfirmationIsRequiredBeforeEnqueueing() async {
        let executor = FakeMediaBatchExecutor()
        let queue = MediaBatchQueue(executor: executor)

        do {
            _ = try await queue.enqueue(metadata(kind: .image), feeConfirmed: false)
            XCTFail("enqueue should require explicit fee confirmation")
        } catch {
            XCTAssertEqual(error as? MediaBatchQueueError, .feeConfirmationRequired)
        }

        let jobs = await queue.jobs()
        let creationCount = await executor.creationCount()
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(creationCount, 0)
    }

    func testQueueIsBoundedWhenNoTerminalRecordCanBeEvicted() async throws {
        let executor = FakeMediaBatchExecutor()
        let queue = MediaBatchQueue(executor: executor, maximumJobs: 3)
        await queue.pause()

        for kind in [MediaBatchKind.image, .music, .video] {
            _ = try await queue.enqueue(metadata(kind: kind), feeConfirmed: true)
        }

        do {
            _ = try await queue.enqueue(metadata(kind: .image), feeConfirmed: true)
            XCTFail("queue should reject work beyond its configured bound")
        } catch {
            XCTAssertEqual(error as? MediaBatchQueueError, .capacityExceeded(maximum: 3))
        }

        let jobCount = await queue.jobs().count
        let creationCount = await executor.creationCount()
        XCTAssertEqual(jobCount, 3)
        XCTAssertEqual(creationCount, 0)
    }

    func testFIFOAndConcurrencyBoundAreEnforced() async throws {
        let executor = FakeMediaBatchExecutor(creationDelayNanoseconds: 20_000_000)
        let queue = MediaBatchQueue(
            executor: executor,
            maximumJobs: 8,
            maximumConcurrentJobs: 2
        )
        let ids = (0..<4).map { _ in UUID() }

        for id in ids {
            _ = try await queue.enqueue(
                MediaBatchMetadata(
                    id: id,
                    kind: .video,
                    providerID: UUID(),
                    modelID: "video-model"
                ),
                feeConfirmed: true
            )
        }

        await queue.awaitIdle()

        let dispatchOrder = await queue.dispatchHistory()
        let peakCreations = await executor.peakCreations()
        let completedJobs = await queue.jobs()
        XCTAssertEqual(dispatchOrder, ids)
        XCTAssertEqual(peakCreations, 2)
        XCTAssertTrue(completedJobs.allSatisfy { $0.state.isSucceeded })
        XCTAssertTrue(completedJobs.allSatisfy { !$0.result.artifacts.isEmpty })
    }

    func testCreationFailureIsNeverRetried() async throws {
        let id = UUID()
        let executor = FakeMediaBatchExecutor(failingCreationIDs: [id])
        let queue = MediaBatchQueue(executor: executor)

        _ = try await queue.enqueue(
            MediaBatchMetadata(
                id: id,
                kind: .music,
                providerID: UUID(),
                modelID: "music-model"
            ),
            feeConfirmed: true
        )
        await queue.awaitIdle()

        let creationCount = await executor.creationCount(for: id)
        let state = await queue.job(id: id)?.state
        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(state, .failed(.creationFailed))
    }

    func testSucceededRemoteStateWithoutArtifactFailsClosed() async throws {
        let id = UUID()
        let executor = FakeMediaBatchExecutor(resultlessIDs: [id])
        let queue = MediaBatchQueue(executor: executor)

        _ = try await queue.enqueue(
            metadata(id: id, kind: .image),
            feeConfirmed: true
        )
        await queue.awaitIdle()

        let state = await queue.job(id: id)?.state
        XCTAssertEqual(state, .failed(.remoteFailed))
    }

    func testPlaceholderArtifactCannotBecomeSuccess() async throws {
        let id = UUID()
        let executor = FakeMediaBatchExecutor(placeholderResultIDs: [id])
        let queue = MediaBatchQueue(executor: executor)

        _ = try await queue.enqueue(
            metadata(id: id, kind: .image),
            feeConfirmed: true
        )
        await queue.awaitIdle()

        let state = await queue.job(id: id)?.state
        XCTAssertEqual(state, .failed(.remoteFailed))
    }

    func testOnlyRemoteStatusPollingUsesBoundedRetry() async throws {
        let id = UUID()
        let executor = FakeMediaBatchExecutor(failingPollIDs: [id])
        let queue = MediaBatchQueue(executor: executor, maximumPollAttempts: 3)

        _ = try await queue.enqueue(
            MediaBatchMetadata(
                id: id,
                kind: .image,
                providerID: UUID(),
                modelID: "image-model"
            ),
            feeConfirmed: true
        )
        await queue.awaitIdle()

        let creationCount = await executor.creationCount(for: id)
        let pollCount = await executor.pollCount(for: id)
        let state = await queue.job(id: id)?.state
        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(pollCount, 3)
        XCTAssertEqual(state, .failed(.pollingExhausted(attempts: 3)))
    }

    func testPauseResumeAndCancellationAffectQueuedWork() async throws {
        let cancelledID = UUID()
        let resumedID = UUID()
        let executor = FakeMediaBatchExecutor()
        let queue = MediaBatchQueue(executor: executor, maximumConcurrentJobs: 1)
        await queue.pause()

        _ = try await queue.enqueue(
            metadata(id: cancelledID, kind: .image),
            feeConfirmed: true
        )
        _ = try await queue.enqueue(
            metadata(id: resumedID, kind: .video),
            feeConfirmed: true
        )
        let creationsWhilePaused = await executor.creationCount()
        XCTAssertEqual(creationsWhilePaused, 0)

        await queue.cancel(id: cancelledID)
        await queue.resume()
        await queue.awaitIdle()

        let cancelledState = await queue.job(id: cancelledID)?.state
        let cancelledCreations = await executor.creationCount(for: cancelledID)
        let resumedCreations = await executor.creationCount(for: resumedID)
        let resumedState = await queue.job(id: resumedID)?.state
        XCTAssertEqual(cancelledState, .cancelled)
        XCTAssertEqual(cancelledCreations, 0)
        XCTAssertEqual(resumedCreations, 1)
        XCTAssertEqual(resumedState?.isSucceeded, true)
    }

    private func metadata(
        id: UUID = UUID(),
        kind: MediaBatchKind
    ) -> MediaBatchMetadata {
        MediaBatchMetadata(
            id: id,
            kind: kind,
            providerID: UUID(),
            modelID: "media-model"
        )
    }
}

private enum FakeMediaBatchError: Error {
    case creation
    case polling
}

private actor FakeMediaBatchExecutor: MediaBatchExecuting {
    private let failingCreationIDs: Set<UUID>
    private let failingPollIDs: Set<UUID>
    private let resultlessIDs: Set<UUID>
    private let placeholderResultIDs: Set<UUID>
    private let creationDelayNanoseconds: UInt64
    private var creationCalls: [UUID] = []
    private var pollCalls: [UUID] = []
    private var activeCreations = 0
    private var peakActiveCreations = 0

    init(
        failingCreationIDs: Set<UUID> = [],
        failingPollIDs: Set<UUID> = [],
        resultlessIDs: Set<UUID> = [],
        placeholderResultIDs: Set<UUID> = [],
        creationDelayNanoseconds: UInt64 = 0
    ) {
        self.failingCreationIDs = failingCreationIDs
        self.failingPollIDs = failingPollIDs
        self.resultlessIDs = resultlessIDs
        self.placeholderResultIDs = placeholderResultIDs
        self.creationDelayNanoseconds = creationDelayNanoseconds
    }

    func create(_ metadata: MediaBatchMetadata) async throws -> String {
        creationCalls.append(metadata.id)
        activeCreations += 1
        peakActiveCreations = max(peakActiveCreations, activeCreations)
        defer { activeCreations -= 1 }

        if creationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: creationDelayNanoseconds)
        }
        if failingCreationIDs.contains(metadata.id) {
            throw FakeMediaBatchError.creation
        }
        return "remote-\(metadata.id.uuidString)"
    }

    func poll(
        remoteTaskID: String,
        metadata: MediaBatchMetadata
    ) async throws -> MediaBatchRemoteState {
        pollCalls.append(metadata.id)
        if failingPollIDs.contains(metadata.id) {
            throw FakeMediaBatchError.polling
        }
        return .succeeded
    }

    func result(for metadata: MediaBatchMetadata) async -> MediaBatchResult? {
        if resultlessIDs.contains(metadata.id) { return nil }
        if placeholderResultIDs.contains(metadata.id) {
            return MediaBatchResult(artifacts: [MediaBatchArtifact()])
        }
        return MediaBatchResult(artifacts: [MediaBatchArtifact(
            remoteURL: URL(string: "https://example.invalid/\(metadata.id.uuidString).bin")!,
            mimeType: "application/octet-stream"
        )])
    }

    func creationCount() -> Int {
        creationCalls.count
    }

    func creationCount(for id: UUID) -> Int {
        creationCalls.filter { $0 == id }.count
    }

    func pollCount(for id: UUID) -> Int {
        pollCalls.filter { $0 == id }.count
    }

    func peakCreations() -> Int {
        peakActiveCreations
    }
}
