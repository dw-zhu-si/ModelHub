import Foundation
import XCTest
@testable import ModelHub
import ModelHubCore

final class LocalGatewayMediaBatchExecutorTests: XCTestCase {
    override func tearDown() {
        MediaBatchURLProtocol.handler = nil
        super.tearDown()
    }

    func testSynchronousImageResponseCompletesWithoutCreatingAgain() async throws {
        let requests = LockedMediaRequests()
        MediaBatchURLProtocol.handler = { request in
            requests.append(request)
            return (200, Data(#"{"data":[{"url":"https://example.invalid/image.png"}]}"#.utf8))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .image,
            providerID: UUID(),
            modelID: "image-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        let remoteID = try await executor.create(metadata)
        let state = try await executor.poll(remoteTaskID: remoteID, metadata: metadata)
        let result = await executor.result(for: metadata)

        XCTAssertEqual(state, .succeeded)
        XCTAssertEqual(
            result?.artifacts.first?.remoteURL?.absoluteString,
            "https://example.invalid/image.png"
        )
        XCTAssertEqual(requests.values.count, 1)
        XCTAssertEqual(
            requests.values.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer local-token"
        )
    }

    func testSynchronousQianwenImageFieldCompletesWithArtifact() async throws {
        MediaBatchURLProtocol.handler = { _ in
            (200, Data(
                #"{"output":{"choices":[{"message":{"content":[{"image":"https://example.invalid/qwen.png","type":"image"}]}}]},"usage":{"output_image_count":1}}"#.utf8
            ))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .image,
            providerID: UUID(),
            modelID: "qwen-image-3.0-pro"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        let remoteID = try await executor.create(metadata)
        let state = try await executor.poll(remoteTaskID: remoteID, metadata: metadata)
        let result = await executor.result(for: metadata)

        XCTAssertTrue(remoteID.hasPrefix("immediate-"))
        XCTAssertEqual(state, .succeeded)
        XCTAssertEqual(
            result?.artifacts.first?.remoteURL?.absoluteString,
            "https://example.invalid/qwen.png"
        )
    }

    func testSynchronousArtifactWinsOverRequestMetadata() async throws {
        let requests = LockedMediaRequests()
        MediaBatchURLProtocol.handler = { request in
            requests.append(request)
            return (200, Data(
                #"{"request_id":"trace-only","data":[{"id":"asset-only","url":"https://example.invalid/synchronous.png"}]}"#.utf8
            ))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .image,
            providerID: UUID(),
            modelID: "image-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        let remoteID = try await executor.create(metadata)
        let state = try await executor.poll(remoteTaskID: remoteID, metadata: metadata)
        let result = await executor.result(for: metadata)

        XCTAssertTrue(remoteID.hasPrefix("immediate-"))
        XCTAssertEqual(state, .succeeded)
        XCTAssertEqual(
            result?.artifacts.first?.remoteURL?.absoluteString,
            "https://example.invalid/synchronous.png"
        )
        XCTAssertEqual(requests.values.count, 1)
    }

    func testSynchronousBase64ArtifactIsPersistedPrivatelyAndBounded() async throws {
        let resultDirectory = FileManager.default.temporaryDirectory.appending(
            path: "modelhub-media-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: resultDirectory) }
        MediaBatchURLProtocol.handler = { _ in
            (200, Data(
                #"{"request_id":"trace-only","data":[{"b64_json":"aGVsbG8=","mime_type":"image/png"}]}"#.utf8
            ))
        }
        let executor = makeExecutor(
            token: "local-token",
            resultDirectory: resultDirectory
        )
        let metadata = MediaBatchMetadata(
            kind: .image,
            providerID: UUID(),
            modelID: "image-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        let remoteID = try await executor.create(metadata)
        let state = try await executor.poll(remoteTaskID: remoteID, metadata: metadata)
        let result = await executor.result(for: metadata)
        let fileURL = try XCTUnwrap(result?.artifacts.first?.localFileURL)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: resultDirectory.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        XCTAssertEqual(state, .succeeded)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("hello".utf8))
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(result?.artifacts.first?.byteCount, 5)
    }

    func testNestedOrdinaryIDsCannotBecomeAsyncTaskID() async throws {
        MediaBatchURLProtocol.handler = { _ in
            (200, Data(
                #"{"status":"queued","request_id":"trace-only","data":{"id":"asset-only"}}"#.utf8
            ))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .video,
            providerID: UUID(),
            modelID: "video-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        do {
            _ = try await executor.create(metadata)
            XCTFail("ordinary id/request_id values must not become task identifiers")
        } catch {
            XCTAssertEqual(
                error as? LocalGatewayMediaBatchExecutorError,
                .invalidTaskResponse
            )
        }
    }

    func testExplicitAsyncImageTaskFailsAtCreationWhenGatewayHasNoImageQueryProtocol() async throws {
        let requests = LockedMediaRequests()
        MediaBatchURLProtocol.handler = { request in
            requests.append(request)
            return (200, Data(#"{"output":{"task_id":"image-task-1"}}"#.utf8))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .image,
            providerID: UUID(),
            modelID: "image-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        do {
            _ = try await executor.create(metadata)
            XCTFail("an async image task cannot be accepted without a real image query route")
        } catch {
            XCTAssertEqual(
                error as? LocalGatewayMediaBatchExecutorError,
                .unsupportedAsyncImageTask
            )
        }
        XCTAssertEqual(requests.values.count, 1)
    }

    func testAsyncVideoTaskUsesModelScopedPollingRoute() async throws {
        let requests = LockedMediaRequests()
        MediaBatchURLProtocol.handler = { request in
            requests.append(request)
            if request.httpMethod == "POST" {
                return (200, Data(#"{"output":{"task_id":"video-task-1"}}"#.utf8))
            }
            return (200, Data(#"{"status":"completed","data":{"url":"https://example.invalid/video.mp4"}}"#.utf8))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .video,
            providerID: UUID(),
            modelID: "provider/video-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        let remoteID = try await executor.create(metadata)
        let state = try await executor.poll(remoteTaskID: remoteID, metadata: metadata)
        let result = await executor.result(for: metadata)

        XCTAssertEqual(remoteID, "video-task-1")
        XCTAssertEqual(state, .succeeded)
        XCTAssertEqual(
            result?.artifacts.first?.remoteURL?.absoluteString,
            "https://example.invalid/video.mp4"
        )
        XCTAssertEqual(requests.values.count, 2)
        XCTAssertEqual(requests.values.last?.url?.path, "/v1/videos/video-task-1")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(requests.values.last?.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "model" })?.value,
            "provider/video-model"
        )
    }

    func testAsyncVideoArtifactIsAuthoritativeEvenWithoutStatusMetadata() async throws {
        MediaBatchURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return (200, Data(#"{"data":{"task_id":"video-task-2"}}"#.utf8))
            }
            return (200, Data(
                #"{"request_id":"trace-only","output":{"video_url":"https://example.invalid/result.mp4"}}"#.utf8
            ))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .video,
            providerID: UUID(),
            modelID: "video-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        let remoteID = try await executor.create(metadata)
        let state = try await executor.poll(remoteTaskID: remoteID, metadata: metadata)
        let result = await executor.result(for: metadata)

        XCTAssertEqual(state, .succeeded)
        XCTAssertEqual(
            result?.artifacts.first?.remoteURL?.absoluteString,
            "https://example.invalid/result.mp4"
        )
    }

    func testMissingGatewayAuthorizationFailsBeforeNetwork() async throws {
        let executor = makeExecutor(token: "")
        let metadata = MediaBatchMetadata(
            kind: .music,
            providerID: UUID(),
            modelID: "music-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        do {
            _ = try await executor.create(metadata)
            XCTFail("missing local gateway token must fail closed")
        } catch {
            XCTAssertEqual(
                error as? LocalGatewayMediaBatchExecutorError,
                .authorizationUnavailable
            )
        }
    }

    func testExecutorRejectsNonLoopbackCreateURLBeforeUsingGatewayToken() async {
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .video,
            providerID: UUID(),
            modelID: "video-model"
        )
        await executor.register(
            LocalGatewayMediaBatchPayload(
                createURL: URL(string: "https://example.com/v1/videos/generations")!,
                body: Data(#"{"model":"video-model","prompt":"hello"}"#.utf8),
                modelID: metadata.modelID
            ),
            for: metadata.id
        )

        do {
            _ = try await executor.create(metadata)
            XCTFail("external URL must fail closed")
        } catch {
            XCTAssertEqual(
                error as? LocalGatewayMediaBatchExecutorError,
                .invalidTaskResponse
            )
        }
    }

    func testMalformedSuccessfulResponseDoesNotBecomeFalseSuccess() async throws {
        MediaBatchURLProtocol.handler = { _ in
            (200, Data(#"{"status":"completed","error":{"message":"failed"}}"#.utf8))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .image,
            providerID: UUID(),
            modelID: "image-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        do {
            _ = try await executor.create(metadata)
            XCTFail("a 2xx response without a validated artifact or task ID must fail")
        } catch {
            XCTAssertEqual(
                error as? LocalGatewayMediaBatchExecutorError,
                .invalidTaskResponse
            )
        }
    }

    func testSuccessfulResponseWithoutArtifactOrExplicitTaskIDFailsClosed() async throws {
        MediaBatchURLProtocol.handler = { _ in
            (200, Data(#"{"status":"completed","data":{"message":"accepted"}}"#.utf8))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .music,
            providerID: UUID(),
            modelID: "music-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        do {
            _ = try await executor.create(metadata)
            XCTFail("2xx without a validated artifact or explicit task ID must fail")
        } catch {
            XCTAssertEqual(
                error as? LocalGatewayMediaBatchExecutorError,
                .invalidTaskResponse
            )
        }
    }

    func testBusinessFailureCannotPublishAnEmbeddedTaskID() async throws {
        MediaBatchURLProtocol.handler = { _ in
            (200, Data(#"{"code":400,"data":{"task_id":"must-not-run"}}"#.utf8))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .video,
            providerID: UUID(),
            modelID: "video-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        do {
            _ = try await executor.create(metadata)
            XCTFail("a declared business failure must not publish a task identifier")
        } catch {
            XCTAssertEqual(
                error as? LocalGatewayMediaBatchExecutorError,
                .invalidTaskResponse
            )
        }
    }

    func testResponseLimitFailsClosedBeforePublishingAResult() async throws {
        MediaBatchURLProtocol.handler = { _ in
            (200, Data(repeating: 0x41, count: 4 * 1_024 * 1_024 + 1))
        }
        let executor = makeExecutor(token: "local-token")
        let metadata = MediaBatchMetadata(
            kind: .image,
            providerID: UUID(),
            modelID: "image-model"
        )
        await executor.register(payload(for: metadata), for: metadata.id)

        do {
            _ = try await executor.create(metadata)
            XCTFail("oversized local gateway response must be cancelled")
        } catch {
            XCTAssertEqual(
                error as? LocalGatewayMediaBatchExecutorError,
                .responseTooLarge(limit: 4 * 1_024 * 1_024)
            )
        }
    }

    private func makeExecutor(
        token: String,
        resultDirectory: URL? = nil
    ) -> LocalGatewayMediaBatchExecutor {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaBatchURLProtocol.self]
        return LocalGatewayMediaBatchExecutor(
            session: URLSession(configuration: configuration),
            resultDirectory: resultDirectory,
            tokenProvider: { token }
        )
    }

    private func payload(for metadata: MediaBatchMetadata) -> LocalGatewayMediaBatchPayload {
        let path: String = switch metadata.kind {
        case .image: "images"
        case .music: "music"
        case .video: "videos"
        }
        return LocalGatewayMediaBatchPayload(
            createURL: URL(string: "http://127.0.0.1:55698/v1/\(path)/generations")!,
            body: Data(#"{"model":"test","prompt":"hello"}"#.utf8),
            modelID: metadata.modelID
        )
    }
}

private final class LockedMediaRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var values: [URLRequest] {
        lock.withLock { storage }
    }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}

private final class MediaBatchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: result.0,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
