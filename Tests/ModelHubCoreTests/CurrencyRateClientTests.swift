import Foundation
import XCTest
@testable import ModelHubCore

final class CurrencyRateClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CurrencyRateURLProtocolStub.reset()
    }

    func testFetchReestablishesSessionAfterTransientTLSFailure() async throws {
        CurrencyRateURLProtocolStub.failuresBeforeSuccess = 1
        CurrencyRateURLProtocolStub.failureCode = .secureConnectionFailed
        let client = makeRecoveringClient()

        let snapshot = try await client.fetch(
            timeoutInterval: 5,
            retryDelayNanoseconds: 0
        )

        XCTAssertEqual(snapshot.effectiveDate, "2026-09-01")
        XCTAssertEqual(snapshot.unitsPerUSD["USD"], 1)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.unitsPerUSD["CNY"]),
            7,
            accuracy: 0.000_001
        )
        XCTAssertEqual(CurrencyRateURLProtocolStub.attemptCount, 2)
    }

    func testFetchStopsAfterOneRecoveryAttempt() async throws {
        CurrencyRateURLProtocolStub.failuresBeforeSuccess = .max
        CurrencyRateURLProtocolStub.failureCode = .secureConnectionFailed
        let client = makeRecoveringClient()

        do {
            _ = try await client.fetch(
                timeoutInterval: 5,
                retryDelayNanoseconds: 0
            )
            XCTFail("Expected persistent TLS failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .secureConnectionFailed)
        }
        XCTAssertEqual(CurrencyRateURLProtocolStub.attemptCount, 2)
    }

    func testFetchDoesNotRetryUntrustedCertificate() async throws {
        CurrencyRateURLProtocolStub.failuresBeforeSuccess = .max
        CurrencyRateURLProtocolStub.failureCode = .serverCertificateUntrusted
        let client = makeRecoveringClient()

        do {
            _ = try await client.fetch(
                timeoutInterval: 5,
                retryDelayNanoseconds: 0
            )
            XCTFail("Expected certificate trust failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .serverCertificateUntrusted)
        }
        XCTAssertEqual(CurrencyRateURLProtocolStub.attemptCount, 1)
    }

    private func makeRecoveringClient() -> CurrencyRateClient {
        let makeSession: @Sendable () -> URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CurrencyRateURLProtocolStub.self]
            return URLSession(configuration: configuration)
        }
        return CurrencyRateClient(
            session: makeSession(),
            recoverySessionFactory: makeSession
        )
    }
}

private final class CurrencyRateURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var failuresBeforeSuccess = 0
    nonisolated(unsafe) static var failureCode = URLError.Code.unknown
    nonisolated(unsafe) static var attemptCount = 0

    private static let responseBody = Data(#"""
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"
      xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
      <Cube><Cube time="2026-09-01">
        <Cube currency="USD" rate="1.2000"/>
        <Cube currency="CNY" rate="8.4000"/>
      </Cube></Cube>
    </gesmes:Envelope>
    """#.utf8)

    static func reset() {
        failuresBeforeSuccess = 0
        failureCode = .unknown
        attemptCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.attemptCount += 1
        if Self.attemptCount <= Self.failuresBeforeSuccess {
            client?.urlProtocol(self, didFailWithError: URLError(Self.failureCode))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/xml"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
