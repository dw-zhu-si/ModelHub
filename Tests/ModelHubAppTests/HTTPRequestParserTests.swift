import Foundation
import Testing
@testable import ModelHub

struct HTTPRequestParserTests {
    @Test func parsesContentLengthBodyAndQuery() throws {
        let result = HTTPRequestParser().parse(Data(
            "POST /v1/chat/completions?name=a+b HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}".utf8
        ))

        let request = try request(from: result)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/chat/completions")
        #expect(request.queryItem("name") == "a+b")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func preservesOrderedDuplicateAndValuelessQueryItems() throws {
        let result = HTTPRequestParser().parse(Data(
            "GET /v1/native?provider=p&model=m&path=%2Ftasks&tag=one&flag&tag=two&plus=a+b HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8
        ))

        let request = try request(from: result)
        #expect(request.queryItem("tag") == "two")
        #expect(request.orderedQueryItems == [
            HTTPQueryItem(name: "provider", value: "p"),
            HTTPQueryItem(name: "model", value: "m"),
            HTTPQueryItem(name: "path", value: "/tasks"),
            HTTPQueryItem(name: "tag", value: "one"),
            HTTPQueryItem(name: "flag", value: nil),
            HTTPQueryItem(name: "tag", value: "two"),
            HTTPQueryItem(name: "plus", value: "a+b")
        ])
    }

    @Test func keepsIncompleteBodyPending() {
        let result = HTTPRequestParser().parse(Data(
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}".utf8
        ))
        guard case .incomplete = result else {
            Issue.record("Expected an incomplete request")
            return
        }
    }

    @Test func rejectsInvalidAndAmbiguousContentLengths() throws {
        let negative = HTTPRequestParser().parse(Data(
            "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: negative) == 400)

        let duplicate = HTTPRequestParser().parse(Data(
            "POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: duplicate) == 400)

        let conflicting = HTTPRequestParser().parse(Data(
            "POST / HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: conflicting) == 400)
    }

    @Test func enforcesBodyAndHeaderLimits() throws {
        let bodyLimit = HTTPRequestParser(maximumBodyBytes: 4).parse(Data(
            "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: bodyLimit) == 413)

        let headerLimit = HTTPRequestParser(maximumHeaderBytes: 8).parse(Data(
            "GET / HTTP/1.1\r\nLong: value\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: headerLimit) == 431)

        let chunkedBodyLimit = HTTPRequestParser(maximumBodyBytes: 4).parse(Data(
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: chunkedBodyLimit) == 413)
    }

    @Test func decodesChunkedBody() throws {
        let result = HTTPRequestParser().parse(Data(
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8
        ))
        #expect(try request(from: result).body == Data("Wikipedia".utf8))
    }

    @Test func rejectsMalformedChunkAndUnsupportedEncoding() throws {
        let malformed = HTTPRequestParser().parse(Data(
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n".utf8
        ))
        #expect(try failureStatus(from: malformed) == 400)

        let unsupported = HTTPRequestParser().parse(Data(
            "POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: unsupported) == 501)
    }

    @Test func rejectsAbsoluteURLRequestTarget() throws {
        let result = HTTPRequestParser().parse(Data(
            "GET http://example.com/health HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: result) == 400)
    }

    @Test func rejectsUnsupportedHTTPVersionAndInvalidHeaderName() throws {
        let version = HTTPRequestParser().parse(Data(
            "GET / HTTP/2.0\r\nHost: 127.0.0.1\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: version) == 400)

        let header = HTTPRequestParser().parse(Data(
            "GET / HTTP/1.1\r\nBad Header: value\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: header) == 400)
    }

    @Test func rejectsAmbiguousSecurityHeadersAndFragments() throws {
        let authorization = HTTPRequestParser().parse(Data(
            "GET / HTTP/1.1\r\nAuthorization: Bearer one\r\nauthorization: Bearer two\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: authorization) == 400)

        let requestID = HTTPRequestParser().parse(Data(
            "GET / HTTP/1.1\r\nX-Request-ID: one\r\nx-request-id: two\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: requestID) == 400)

        let competingRequestIDs = HTTPRequestParser().parse(Data(
            "GET / HTTP/1.1\r\nX-ModelHub-Request-ID: modelhub\r\nX-Request-ID: upstream\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: competingRequestIDs) == 400)

        let fragment = HTTPRequestParser().parse(Data(
            "GET /health#hidden HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: fragment) == 400)
    }

    @Test func incrementallyParsesContentLengthFragmentsWithoutReparsingHeaders() throws {
        let body = Data(repeating: 0x61, count: 4_096)
        var bytes = Data(
            "POST /incremental HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8
        )
        bytes.append(body)
        let streamParser = HTTPRequestParser().makeStreamParser()
        var result: HTTPRequestParseResult = .incomplete

        for byte in bytes {
            result = streamParser.append(Data([byte]))
        }

        #expect(try request(from: result).body == body)
        #expect(streamParser.parsedHeaderCount == 1)
    }

    @Test func reportsFragmentedParsingMicrobenchmark() throws {
        let body = Data(repeating: 0x61, count: 64 * 1_024)
        var bytes = Data(
            "POST /benchmark HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8
        )
        bytes.append(body)
        let fragmentSize = 64

        var statelessSamples: [Duration] = []
        var incrementalSamples: [Duration] = []
        for _ in 0..<5 {
            let statelessStarted = ContinuousClock.now
            for byteCount in stride(from: fragmentSize, to: bytes.count, by: fragmentSize) {
                _ = HTTPRequestParser().parse(Data(bytes.prefix(byteCount)))
            }
            _ = HTTPRequestParser().parse(bytes)
            statelessSamples.append(statelessStarted.duration(to: .now))

            let streamParser = HTTPRequestParser().makeStreamParser()
            var streamedResult: HTTPRequestParseResult = .incomplete
            let incrementalStarted = ContinuousClock.now
            for offset in stride(from: 0, to: bytes.count, by: fragmentSize) {
                let end = min(offset + fragmentSize, bytes.count)
                streamedResult = streamParser.append(Data(bytes[offset..<end]))
            }
            incrementalSamples.append(incrementalStarted.duration(to: .now))

            #expect(try request(from: streamedResult).body == body)
            #expect(streamParser.parsedHeaderCount == 1)
        }

        let statelessMedian = statelessSamples.sorted()[2]
        let incrementalMedian = incrementalSamples.sorted()[2]
        print(
            "HTTP parser 64 KiB / 64-byte fragments (5-run median): "
                + "stateless=\(statelessMedian), incremental=\(incrementalMedian)"
        )
    }

    @Test func incrementallyParsesChunkedFragmentsAndKeepsSecurityChecks() throws {
        let bytes = Data(
            "POST /chunked HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8
        )
        let streamParser = HTTPRequestParser().makeStreamParser()
        var result: HTTPRequestParseResult = .incomplete

        for byte in bytes {
            result = streamParser.append(Data([byte]))
        }

        #expect(try request(from: result).body == Data("Wikipedia".utf8))
        #expect(streamParser.parsedHeaderCount == 1)

        let ambiguous = HTTPRequestParser().makeStreamParser()
        let ambiguousResult = ambiguous.append(Data(
            "POST / HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: ambiguousResult) == 400)
    }

    @Test func appliesBoundedRequestIDPolicyAndPreservesManualInitialization() throws {
        let accepted = HTTPRequestParser().parse(Data(
            "GET / HTTP/1.1\r\nX-ModelHub-Request-ID: trace.A_1-2\r\n\r\n".utf8
        ))
        #expect(try request(from: accepted).requestID == "trace.A_1-2")

        let fallback = HTTPRequestParser().parse(Data(
            "GET / HTTP/1.1\r\nX-Request-ID: upstream_42\r\n\r\n".utf8
        ))
        #expect(try request(from: fallback).requestID == "upstream_42")

        let invalid = HTTPRequestParser().parse(Data(
            "GET / HTTP/1.1\r\nX-ModelHub-Request-ID: contains space\r\n\r\n".utf8
        ))
        let generatedID = try request(from: invalid).requestID
        #expect(generatedID != "contains space")
        #expect(isSafeRequestID(generatedID))

        let manual = HTTPRequest(
            method: "GET",
            path: "/health",
            queryItems: [:],
            orderedQueryItems: [],
            headers: [:],
            body: Data()
        )
        #expect(isSafeRequestID(manual.requestID))
    }

    @Test func rejectsOverlongRequestIDAndAddsSafeIDToResponses() throws {
        let maximumID = String(repeating: "a", count: 80)
        let accepted = HTTPRequestParser().parse(Data(
            "GET / HTTP/1.1\r\nX-Request-ID: \(maximumID)\r\n\r\n".utf8
        ))
        #expect(try request(from: accepted).requestID == maximumID)

        let overlongID = String(repeating: "b", count: 81)
        let rejected = HTTPRequestParser().parse(Data(
            "GET / HTTP/1.1\r\nX-Request-ID: \(overlongID)\r\n\r\n".utf8
        ))
        let generatedID = try request(from: rejected).requestID
        #expect(generatedID != overlongID)
        #expect(isSafeRequestID(generatedID))

        let response = HTTPResponse.json(statusCode: 200, object: [:])
            .addingRequestID(maximumID)
        #expect(response.headers["X-ModelHub-Request-ID"] == maximumID)
        let serializedResponse = String(decoding: response.serialized(), as: UTF8.self)
        #expect(serializedResponse.contains("X-Request-ID"))
        #expect(serializedResponse.contains("Access-Control-Expose-Headers: X-ModelHub-Request-ID"))

        let streamResponse = HTTPStreamResponse(
            statusCode: 200,
            headers: [:],
            body: AsyncThrowingStream { $0.finish() }
        ).addingRequestID(maximumID)
        #expect(streamResponse.headers["X-ModelHub-Request-ID"] == maximumID)
        let serializedStreamHead = String(decoding: streamResponse.serializedHead(), as: UTF8.self)
        #expect(serializedStreamHead.contains("X-Request-ID"))
        #expect(serializedStreamHead.contains("Access-Control-Expose-Headers: X-ModelHub-Request-ID"))
    }

    @Test func serverPolicyCapsConnectionsAndSeparatesIdleFromAbsoluteDeadline() {
        let policy = HTTPServerConnectionPolicy()

        #expect(policy.maximumActiveConnections == 128)
        #expect(policy.idleTimeout == 10)
        #expect(policy.absoluteRequestDeadline == 30)
        #expect(policy.handlerDeadline == 660)
        #expect(policy.streamIdleTimeout == 30)
        #expect(policy.maximumStreamDuration == 3_600)
        #expect(policy.admits(activeConnectionCount: 127))
        #expect(!policy.admits(activeConnectionCount: 128))
        #expect(policy.timeoutReason(requestAge: 29, idleAge: 9) == nil)
        #expect(policy.timeoutReason(requestAge: 5, idleAge: 10) == .idle)
        #expect(policy.timeoutReason(requestAge: 30, idleAge: 0) == .absoluteRequestDeadline)

        let independentDeadlines = HTTPServerConnectionPolicy(
            idleTimeout: 60,
            absoluteRequestDeadline: 30,
            handlerDeadline: 120,
            streamIdleTimeout: 15,
            maximumStreamDuration: 900
        )
        #expect(independentDeadlines.absoluteRequestDeadline == 30)
        #expect(independentDeadlines.handlerDeadline == 120)
        #expect(independentDeadlines.streamIdleTimeout == 15)
        #expect(independentDeadlines.maximumStreamDuration == 900)
        #expect(independentDeadlines.timeoutReason(requestAge: 30, idleAge: 0) == .absoluteRequestDeadline)
    }

    private func request(from result: HTTPRequestParseResult) throws -> HTTPRequest {
        guard case .request(let request) = result else {
            throw TestError.unexpectedResult
        }
        return request
    }

    private func failureStatus(from result: HTTPRequestParseResult) throws -> Int {
        guard case .failure(let response) = result else {
            throw TestError.unexpectedResult
        }
        return response.statusCode
    }

    private func isSafeRequestID(_ value: String) -> Bool {
        (1...80).contains(value.utf8.count) && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 46
                || $0 == 95
                || $0 == 45
        }
    }

    private enum TestError: Error {
        case unexpectedResult
    }
}
