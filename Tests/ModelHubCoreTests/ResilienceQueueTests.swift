import XCTest
@testable import ModelHubCore

final class ResilienceQueueTests: XCTestCase {
    func testQueuedRequestReceivesReleasedTargetSlot() async {
        let controller = ResilienceController()
        let key = TargetRuntimeKey(providerID: UUID(), model: "model")
        let resilience = ResilienceSettings(maxConcurrentRequestsPerTarget: 1)
        let queue = TargetQueueSettings(enabled: true, capacityPerTarget: 4, maximumWaitMilliseconds: 1_000)

        let initialAdmission = await controller.beginTarget(key, settings: resilience)
        XCTAssertEqual(initialAdmission, .allowed)
        let waiting = Task {
            await controller.acquireTarget(
                key,
                accessScope: "workspace-a",
                settings: resilience,
                queue: queue
            )
        }
        await waitForQueuedCount(1, controller: controller)
        await controller.finishTarget(
            key,
            succeeded: true,
            transientFailure: false,
            settings: resilience
        )

        let waitingAdmission = await waiting.value
        let runningSnapshot = await controller.snapshot(for: key)
        XCTAssertEqual(waitingAdmission, .allowed)
        XCTAssertEqual(runningSnapshot.inFlight, 1)
        await controller.finishTarget(
            key,
            succeeded: true,
            transientFailure: false,
            settings: resilience
        )
    }

    func testQueueCapacityFailsClosed() async {
        let controller = ResilienceController()
        let key = TargetRuntimeKey(providerID: UUID(), model: "model")
        let resilience = ResilienceSettings(maxConcurrentRequestsPerTarget: 1)
        let queue = TargetQueueSettings(enabled: true, capacityPerTarget: 1, maximumWaitMilliseconds: 1_000)
        _ = await controller.beginTarget(key, settings: resilience)
        let firstWaiter = Task {
            await controller.acquireTarget(
                key,
                accessScope: "a",
                settings: resilience,
                queue: queue
            )
        }
        await waitForQueuedCount(1, controller: controller)

        let rejected = await controller.acquireTarget(
            key,
            accessScope: "b",
            settings: resilience,
            queue: queue
        )
        XCTAssertEqual(rejected, .queueFull)

        firstWaiter.cancel()
        let cancelledAdmission = await firstWaiter.value
        XCTAssertEqual(cancelledAdmission, .cancelled)
        await controller.finishTarget(
            key,
            succeeded: true,
            transientFailure: false,
            settings: resilience
        )
    }

    func testQueueRotatesAcrossScopesBeforeServingSameScopeAgain() async {
        let controller = ResilienceController()
        let key = TargetRuntimeKey(providerID: UUID(), model: "model")
        let resilience = ResilienceSettings(maxConcurrentRequestsPerTarget: 1)
        let queue = TargetQueueSettings(enabled: true, capacityPerTarget: 4, maximumWaitMilliseconds: 2_000)
        _ = await controller.beginTarget(key, settings: resilience)

        let a1 = Task { await controller.acquireTarget(key, accessScope: "a", settings: resilience, queue: queue) }
        await waitForQueuedCount(1, controller: controller)
        let a2 = Task { await controller.acquireTarget(key, accessScope: "a", settings: resilience, queue: queue) }
        await waitForQueuedCount(2, controller: controller)
        let b1 = Task { await controller.acquireTarget(key, accessScope: "b", settings: resilience, queue: queue) }
        await waitForQueuedCount(3, controller: controller)

        await controller.finishTarget(key, succeeded: true, transientFailure: false, settings: resilience)
        let firstAAdmission = await a1.value
        XCTAssertEqual(firstAAdmission, .allowed)
        await controller.finishTarget(key, succeeded: true, transientFailure: false, settings: resilience)
        let firstBAdmission = await b1.value
        XCTAssertEqual(firstBAdmission, .allowed)
        await controller.finishTarget(key, succeeded: true, transientFailure: false, settings: resilience)
        let secondAAdmission = await a2.value
        XCTAssertEqual(secondAAdmission, .allowed)
        await controller.finishTarget(key, succeeded: true, transientFailure: false, settings: resilience)
    }

    func testQueueTimeoutAndCancellationDoNotLeakWaitersOrSlots() async {
        let controller = ResilienceController()
        let key = TargetRuntimeKey(providerID: UUID(), model: "model")
        let resilience = ResilienceSettings(maxConcurrentRequestsPerTarget: 1)
        _ = await controller.beginTarget(key, settings: resilience)

        let timedOut = await controller.acquireTarget(
            key,
            accessScope: "timeout",
            settings: resilience,
            queue: .init(enabled: true, capacityPerTarget: 2, maximumWaitMilliseconds: 20)
        )
        XCTAssertEqual(timedOut, .queueTimedOut)

        let cancelled = Task {
            await controller.acquireTarget(
                key,
                accessScope: "cancel",
                settings: resilience,
                queue: .init(enabled: true, capacityPerTarget: 2, maximumWaitMilliseconds: 1_000)
            )
        }
        await waitForQueuedCount(1, controller: controller)
        cancelled.cancel()
        let cancelledAdmission = await cancelled.value
        let queueSnapshot = await controller.queueSnapshot(for: key)
        let targetSnapshot = await controller.snapshot(for: key)
        XCTAssertEqual(cancelledAdmission, .cancelled)
        XCTAssertEqual(queueSnapshot.waiting, 0)
        XCTAssertEqual(targetSnapshot.inFlight, 1)
        await controller.finishTarget(key, succeeded: true, transientFailure: false, settings: resilience)
    }

    private func waitForQueuedCount(
        _ expected: Int,
        controller: ResilienceController
    ) async {
        for _ in 0..<100 {
            if await controller.metrics().queuedWaiting == expected { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("等待队列未达到预期数量 \(expected)")
    }
}
