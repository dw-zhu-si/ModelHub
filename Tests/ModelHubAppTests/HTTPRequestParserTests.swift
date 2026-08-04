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

        let fragment = HTTPRequestParser().parse(Data(
            "GET /health#hidden HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8
        ))
        #expect(try failureStatus(from: fragment) == 400)
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

    private enum TestError: Error {
        case unexpectedResult
    }
}
