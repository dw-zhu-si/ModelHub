import CryptoKit
import Foundation
import ModelHubShared
import Security

final class PinnedGatewayTransport: NSObject, @unchecked Sendable, MobileGatewayTransport, URLSessionDelegate, URLSessionTaskDelegate {
    private final class CompletionBox: @unchecked Sendable {
        let call: (MobileTransportResponse?, (any Error)?) -> Void

        init(_ call: @escaping (MobileTransportResponse?, (any Error)?) -> Void) {
            self.call = call
        }
    }

    private let baseURL: URL
    private let fingerprint: String
    private lazy var session = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: nil
    )

    init(serviceURL: String, certificateFingerprint: String) throws {
        guard let url = URL(string: serviceURL),
              url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { throw TransportError.invalidEndpoint }
        let normalized = certificateFingerprint.lowercased().replacingOccurrences(of: ":", with: "")
        guard normalized.count == 64,
              normalized.allSatisfy({ $0.isHexDigit })
        else { throw TransportError.invalidFingerprint }
        baseURL = url
        fingerprint = normalized
        super.init()
    }

    private var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        return configuration
    }

    func execute(
        request: MobileTransportRequest,
        completionHandler: @escaping (MobileTransportResponse?, (any Error)?) -> Void
    ) {
        guard request.path.hasPrefix("/mobile/v1/"),
              !request.path.contains("?"),
              !request.path.contains("#"),
              request.body.size <= 16 * 1_024,
              let url = URL(string: request.path, relativeTo: baseURL)
        else {
            completionHandler(nil, TransportError.invalidRequest)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.asData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in request.headers {
            guard !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n")
            else {
                completionHandler(nil, TransportError.invalidRequest)
                return
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let completion = CompletionBox(completionHandler)
        session.dataTask(with: urlRequest) { data, response, error in
            if let error {
                completion.call(nil, error)
                return
            }
            guard let response = response as? HTTPURLResponse,
                  let data,
                  data.count <= 1_048_576
            else {
                completion.call(nil, TransportError.invalidResponse)
                return
            }
            completion.call(
                MobileTransportResponse(
                    statusCode: Int32(response.statusCode),
                    body: KotlinByteArray(data: data)
                ),
                nil
            )
        }.resume()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificate.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard constantTimeEqual(digest, fingerprint) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        let lhs = Array(first.utf8)
        let rhs = Array(second.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    enum TransportError: LocalizedError {
        case invalidEndpoint
        case invalidFingerprint
        case invalidRequest
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "ModelHub 移动访问地址无效"
            case .invalidFingerprint: "ModelHub TLS 证书指纹无效"
            case .invalidRequest: "移动请求越出安全白名单"
            case .invalidResponse: "ModelHub 返回了超限或无效响应"
            }
        }
    }
}
