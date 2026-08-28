import Foundation
import ModelHubCore
import XCTest
@testable import ModelHub

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt16 = 0

    func set(_ value: UInt16) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private actor StreamingCompletionProbe {
    private(set) var observed = false
    private(set) var inFlightAtObservation: Int?

    func markObserved(inFlight: Int) {
        observed = true
        inFlightAtObservation = inFlight
    }

    func observation() -> (observed: Bool, inFlight: Int?) {
        (observed, inFlightAtObservation)
    }
}

final class StreamingServerTests: XCTestCase {
    func testTargetSlotAndProxyOutcomeFinalizeBeforeStreamEOF() async {
        let resilience = ResilienceController()
        let runtimeKey = TargetRuntimeKey(providerID: UUID(), model: "stream-model")
        let settings = ResilienceSettings(maxConcurrentRequestsPerTarget: 1)
        let probe = StreamingCompletionProbe()

        let firstAdmission = await resilience.beginTarget(runtimeKey, settings: settings)
        XCTAssertEqual(firstAdmission, .allowed)
        await GatewayStreamingTargetFinalizer.finishBeforeEOF(
            resilience: resilience,
            runtimeKey: runtimeKey,
            succeeded: true,
            transientFailure: false,
            settings: settings,
            observeProxyOutcome: {
                let snapshot = await resilience.snapshot(for: runtimeKey)
                await probe.markObserved(inFlight: snapshot.inFlight)
            }
        )

        let observation = await probe.observation()
        let finalizedSnapshot = await resilience.snapshot(for: runtimeKey)
        let nextAdmission = await resilience.beginTarget(runtimeKey, settings: settings)
        XCTAssertTrue(observation.observed)
        XCTAssertEqual(
            observation.inFlight,
            1,
            "节点结果必须在旧请求仍占有 target slot 时提交"
        )
        XCTAssertEqual(finalizedSnapshot.inFlight, 0)
        XCTAssertEqual(
            nextAdmission,
            .allowed,
            "客户端观察 EOF 后立即发起的下一请求必须拿到已释放的 target slot"
        )
    }

    func testStreamHeadUsesChunkedTransferWithoutContentLength() {
        let response = HTTPStreamResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: AsyncThrowingStream { $0.finish() }
        )
        let head = String(decoding: response.serializedHead(), as: UTF8.self)
        XCTAssertTrue(head.contains("Transfer-Encoding: chunked"))
        XCTAssertFalse(head.lowercased().contains("content-length"))
    }

    func testServerDeliversFirstSSEChunkBeforeUpstreamFinishes() async throws {
        let server = LocalAPIServer(
            handler: { _ in .json(statusCode: 500, object: [:]) },
            streamHandler: { _ in
                HTTPStreamResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    body: AsyncThrowingStream { continuation in
                        let task = Task {
                            continuation.yield(Data("data: first\n\n".utf8))
                            try? await Task.sleep(for: .milliseconds(350))
                            continuation.yield(Data("data: second\n\n".utf8))
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                )
            }
        )
        defer { server.stop() }
        let ready = expectation(description: "server ready")
        let portBox = PortBox()
        try server.start(port: 0) { result in
            if case .success(let actualPort) = result { portBox.set(actualPort) }
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 2)
        let port = portBox.get()
        XCTAssertNotEqual(port, 0)

        let started = ContinuousClock.now
        let (bytes, response) = try await URLSession.shared.bytes(
            for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream")!)
        )
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var iterator = bytes.lines.makeAsyncIterator()
        let first = try await iterator.next()
        let firstElapsed = started.duration(to: .now)

        XCTAssertEqual(first, "data: first")
        XCTAssertLessThan(firstElapsed, .milliseconds(250))
    }
}
