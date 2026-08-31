import AppKit
import CryptoKit
import Foundation
import ModelHubCore
@preconcurrency import Network
import Security

struct OAuthTokenSecret: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var providerID: UUID
    var providerKind: ProviderKind
    var canonicalOrigin: String

    init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        providerID: UUID,
        providerKind: ProviderKind,
        canonicalOrigin: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.providerID = providerID
        self.providerKind = providerKind
        self.canonicalOrigin = canonicalOrigin
    }

    init(keychainValue: String) throws {
        let payload = try JSONDecoder.oauthTokenSecret.decode(
            KeychainPayload.self,
            from: Data(keychainValue.utf8)
        )
        self.init(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresAt,
            providerID: payload.providerID,
            providerKind: payload.providerKind,
            canonicalOrigin: payload.canonicalOrigin
        )
    }

    func keychainValue() throws -> String {
        let data = try JSONEncoder.oauthTokenSecret.encode(
            KeychainPayload(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                providerID: providerID,
                providerKind: providerKind,
                canonicalOrigin: canonicalOrigin
            )
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw OAuthTokenManagerError.secretMalformed
        }
        return value
    }

    private struct KeychainPayload: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var providerID: UUID
        var providerKind: ProviderKind
        var canonicalOrigin: String
    }
}

enum OAuthCredentialBindingPolicy {
    static func canonicalOrigin(for providerKind: ProviderKind) -> String? {
        switch providerKind {
        case .gemini:
            "https://generativelanguage.googleapis.com"
        default:
            nil
        }
    }

    static func isBound(
        _ secret: OAuthTokenSecret,
        to entry: CredentialPoolEntry,
        providerKind: ProviderKind
    ) -> Bool {
        guard let canonicalOrigin = canonicalOrigin(for: providerKind) else { return false }
        return secret.providerID == entry.providerID
            && secret.providerKind == providerKind
            && secret.canonicalOrigin == canonicalOrigin
    }
}

private extension JSONEncoder {
    static var oauthTokenSecret: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var oauthTokenSecret: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

protocol OAuthTokenSecretStoring: Sendable {
    func readValue(for credentialID: UUID) async throws -> String?
    func replaceValue(_ value: String, for credentialID: UUID) async throws
    func deleteValue(for credentialID: UUID) async throws
}

struct KeychainOAuthTokenSecretStorage: OAuthTokenSecretStoring {
    func readValue(for credentialID: UUID) async throws -> String? {
        switch await KeychainStore.readWithoutInteractionAsync(
            account: KeychainStore.credentialPoolAccount(credentialID)
        ) {
        case let .value(value):
            return value
        case .notFound:
            return nil
        case .interactionRequired, .failure:
            throw OAuthTokenSecretStorageError.unavailable
        }
    }

    func replaceValue(_ value: String, for credentialID: UUID) async throws {
        do {
            try KeychainStore.save(
                value,
                account: KeychainStore.credentialPoolAccount(credentialID)
            )
        } catch {
            throw OAuthTokenSecretStorageError.unavailable
        }
    }

    func deleteValue(for credentialID: UUID) async throws {
        let status = KeychainStore.delete(
            account: KeychainStore.credentialPoolAccount(credentialID)
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OAuthTokenSecretStorageError.unavailable
        }
    }
}

private enum OAuthTokenSecretStorageError: Error {
    case unavailable
}

struct OAuthTokenRefreshRequest: Equatable, Sendable {
    var endpoint: URL
    var method: String
    var contentType: String
    var formData: Data

    init(endpoint: URL, formData: Data) {
        self.endpoint = endpoint
        self.method = "POST"
        self.contentType = "application/x-www-form-urlencoded"
        self.formData = formData
    }
}

struct OAuthTokenRefreshResponse: Equatable, Sendable {
    var statusCode: Int
    var data: Data
}

protocol OAuthTokenRefreshTransporting: Sendable {
    func send(_ request: OAuthTokenRefreshRequest) async throws -> OAuthTokenRefreshResponse
}

private final class OAuthTokenNoRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class URLSessionOAuthTokenRefreshTransport: OAuthTokenRefreshTransporting,
    @unchecked Sendable
{
    private static let defaultMaximumResponseBytes = 1_048_576
    private let session: URLSession
    private let maximumResponseBytes: Int

    init() {
        session = Self.makeSession(protocolClasses: nil)
        maximumResponseBytes = Self.defaultMaximumResponseBytes
    }

    init(protocolClasses: [AnyClass], maximumResponseBytes: Int) {
        session = Self.makeSession(protocolClasses: protocolClasses)
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }

    private static func makeSession(protocolClasses: [AnyClass]?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(
            configuration: configuration,
            delegate: OAuthTokenNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func send(_ request: OAuthTokenRefreshRequest) async throws -> OAuthTokenRefreshResponse {
        guard request.endpoint.scheme?.lowercased() == "https",
              request.endpoint.host?.lowercased() == "oauth2.googleapis.com",
              request.endpoint.port == nil || request.endpoint.port == 443,
              request.endpoint.user == nil,
              request.endpoint.password == nil,
              request.endpoint.fragment == nil,
              request.method == "POST"
        else {
            throw OAuthTokenManagerError.configurationInvalid(.insecureTokenEndpoint)
        }

        var networkRequest = URLRequest(url: request.endpoint)
        networkRequest.httpMethod = request.method
        networkRequest.setValue(request.contentType, forHTTPHeaderField: "Content-Type")
        networkRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        networkRequest.httpBody = request.formData
        networkRequest.cachePolicy = .reloadIgnoringLocalCacheData

        let (bytes, response) = try await session.bytes(for: networkRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthTokenManagerError.invalidResponse
        }
        guard httpResponse.url?.scheme?.lowercased() == "https",
              httpResponse.url?.host?.lowercased() == "oauth2.googleapis.com",
              httpResponse.url?.port == nil || httpResponse.url?.port == 443
        else {
            throw OAuthTokenManagerError.invalidResponse
        }
        if httpResponse.expectedContentLength > Int64(maximumResponseBytes) {
            throw OAuthTokenManagerError.responseTooLarge(limit: maximumResponseBytes)
        }
        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(min(
                Int(httpResponse.expectedContentLength),
                maximumResponseBytes
            ))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw OAuthTokenManagerError.responseTooLarge(limit: maximumResponseBytes)
            }
            data.append(byte)
        }
        return OAuthTokenRefreshResponse(
            statusCode: httpResponse.statusCode,
            data: data
        )
    }

}

struct OAuthPKCEProof: Equatable, Sendable {
    let verifier: String
    let state: String
    let nonce: String

    var codeChallenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func secureRandom() throws -> OAuthPKCEProof {
        OAuthPKCEProof(
            verifier: try randomURLSafeValue(byteCount: 48),
            state: try randomURLSafeValue(byteCount: 32),
            nonce: try randomURLSafeValue(byteCount: 32)
        )
    }

    private static func randomURLSafeValue(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OAuthAuthorizationFlowError.randomGenerationFailed
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

protocol OAuthAuthorizationSessioning: Sendable {
    func authenticate(
        at authorizationURL: URL,
        callbackURL: URL,
        timeoutNanoseconds: UInt64
    ) async throws -> URL
    func cancel() async
}

protocol OAuthBrowserOpening: Sendable {
    func open(_ url: URL) async throws
}

struct SystemOAuthBrowserOpener: OAuthBrowserOpening {
    func open(_ url: URL) async throws {
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw OAuthAuthorizationFlowError.sessionFailed }
    }
}

final class LoopbackOAuthAuthorizationSession: OAuthAuthorizationSessioning,
    @unchecked Sendable
{
    static let port: UInt16 = 11_469
    static let callbackPath = "/oauth/callback"
    static let maximumHeaderBytes = 8_192

    private let queue = DispatchQueue(label: "com.local.modelhub.oauth-loopback")
    private let browserOpener: any OAuthBrowserOpening
    private let connectionHeaderTimeoutSeconds: TimeInterval
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var requestBuffer = Data()
    private var timeoutWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var completion: (@Sendable (Result<URL, Error>) -> Void)?

    init(
        browserOpener: any OAuthBrowserOpening = SystemOAuthBrowserOpener(),
        connectionHeaderTimeoutSeconds: TimeInterval = 5
    ) {
        self.browserOpener = browserOpener
        self.connectionHeaderTimeoutSeconds = max(
            0.1,
            min(connectionHeaderTimeoutSeconds, 10)
        )
    }

    func authenticate(
        at authorizationURL: URL,
        callbackURL: URL,
        timeoutNanoseconds: UInt64
    ) async throws -> URL {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(
                            throwing: OAuthAuthorizationFlowError.sessionFailed
                        )
                        return
                    }
                    self.start(
                        authorizationURL: authorizationURL,
                        callbackURL: callbackURL,
                        timeoutNanoseconds: timeoutNanoseconds,
                        completion: { continuation.resume(with: $0) }
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancel() }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.finish(.failure(OAuthAuthorizationFlowError.cancelled))
                continuation.resume()
            }
        }
    }

    private func start(
        authorizationURL: URL,
        callbackURL: URL,
        timeoutNanoseconds: UInt64,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        guard self.completion == nil else {
            completion(.failure(OAuthAuthorizationFlowError.authorizationAlreadyInProgress))
            return
        }
        guard Self.isExpectedCallbackURL(callbackURL) else {
            completion(.failure(OAuthAuthorizationFlowError.callbackMismatch))
            return
        }
        self.completion = completion

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: Self.port)!
            )
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, listener != nil else { return }
                switch state {
                case .ready:
                    self.openBrowser(authorizationURL)
                case .failed:
                    self.finish(
                        .failure(OAuthAuthorizationFlowError.loopbackListenerUnavailable)
                    )
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            let timeoutSeconds = max(
                0.001,
                min(Double(timeoutNanoseconds) / 1_000_000_000, 300)
            )
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(.failure(OAuthAuthorizationFlowError.timedOut))
            }
            timeoutWorkItem = timeout
            queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
            listener.start(queue: queue)
        } catch {
            finish(.failure(OAuthAuthorizationFlowError.loopbackListenerUnavailable))
        }
    }

    private func openBrowser(_ authorizationURL: URL) {
        let opener = browserOpener
        Task {
            do {
                try await opener.open(authorizationURL)
            } catch {
                queue.async { [weak self] in
                    self?.finish(.failure(OAuthAuthorizationFlowError.sessionFailed))
                }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard completion != nil else {
            connection.cancel()
            return
        }
        guard activeConnection == nil else {
            connection.start(queue: queue)
            sendResponse(status: 503, body: "OAuth callback busy", on: connection) {
                connection.cancel()
            }
            return
        }
        activeConnection = connection
        requestBuffer.removeAll(keepingCapacity: true)
        let connectionTimeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection,
                  self.activeConnection === connection
            else { return }
            self.connectionTimeoutWorkItem = nil
            connection.cancel()
            self.activeConnection = nil
            self.requestBuffer.removeAll(keepingCapacity: true)
        }
        connectionTimeoutWorkItem = connectionTimeout
        queue.asyncAfter(
            deadline: .now() + connectionHeaderTimeoutSeconds,
            execute: connectionTimeout
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                if self.activeConnection === connection {
                    self.connectionTimeoutWorkItem?.cancel()
                    self.connectionTimeoutWorkItem = nil
                    self.activeConnection = nil
                    self.requestBuffer.removeAll(keepingCapacity: true)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 2_048
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection,
                  self.activeConnection === connection
            else { return }
            if let data, !data.isEmpty {
                self.requestBuffer.append(data)
            }
            guard self.requestBuffer.count <= Self.maximumHeaderBytes else {
                self.reject(status: 431, on: connection)
                return
            }
            if let headerEnd = self.requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                self.connectionTimeoutWorkItem?.cancel()
                self.connectionTimeoutWorkItem = nil
                let headerData = self.requestBuffer[..<headerEnd.lowerBound]
                self.handleHeader(Data(headerData), on: connection)
                return
            }
            if error != nil || isComplete {
                self.reject(status: 400, on: connection)
                return
            }
            self.receive(on: connection)
        }
    }

    private func handleHeader(_ data: Data, on connection: NWConnection) {
        guard let header = String(data: data, encoding: .utf8),
              !header.contains("\0")
        else {
            reject(status: 400, on: connection)
            return
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            reject(status: 400, on: connection)
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1" else {
            reject(status: parts.first == "GET" ? 400 : 405, on: connection)
            return
        }
        let target = String(parts[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let components = URLComponents(string: target),
              components.percentEncodedPath == Self.callbackPath,
              components.fragment == nil
        else {
            reject(status: 404, on: connection)
            return
        }
        var hostValues: [String] = []
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                reject(status: 400, on: connection)
                return
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                reject(status: 400, on: connection)
                return
            }
            if name.caseInsensitiveCompare("host") == .orderedSame {
                hostValues.append(value.lowercased())
            }
        }
        guard hostValues == ["127.0.0.1:\(Self.port)"],
              let callback = URL(string: "http://127.0.0.1:\(Self.port)\(target)"),
              Self.isExpectedCallbackURL(callback, allowQuery: true)
        else {
            reject(status: 400, on: connection)
            return
        }

        let html = "<!doctype html><meta charset=\"utf-8\"><title>ModelHub</title><p>授权回调已收到，可以关闭此页面并返回 ModelHub。</p>"
        sendResponse(status: 200, body: html, contentType: "text/html; charset=utf-8", on: connection) {
            connection.cancel()
            self.activeConnection = nil
            self.requestBuffer.removeAll(keepingCapacity: true)
            self.finish(.success(callback))
        }
    }

    private func reject(status: Int, on connection: NWConnection) {
        sendResponse(status: status, body: "Invalid OAuth callback", on: connection) {
            connection.cancel()
            if self.activeConnection === connection {
                self.connectionTimeoutWorkItem?.cancel()
                self.connectionTimeoutWorkItem = nil
                self.activeConnection = nil
                self.requestBuffer.removeAll(keepingCapacity: true)
            }
        }
    }

    private func sendResponse(
        status: Int,
        body: String,
        contentType: String = "text/plain; charset=utf-8",
        on connection: NWConnection,
        completion: @escaping @Sendable () -> Void
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 431: reason = "Request Header Fields Too Large"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in completion() })
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let completion else { return }
        self.completion = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        activeConnection = nil
        requestBuffer.removeAll(keepingCapacity: false)
        completion(result)
    }

    private static func isExpectedCallbackURL(
        _ url: URL,
        allowQuery: Bool = false
    ) -> Bool {
        url.scheme?.lowercased() == "http"
            && url.host == "127.0.0.1"
            && url.port == Int(port)
            && url.path == callbackPath
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
            && (allowQuery || url.query == nil)
    }
}

enum OAuthAuthorizationFlowError: Error, Equatable, Sendable {
    case unsupportedCredentialType
    case complianceBlocked(CredentialAutomationBlockReason)
    case configurationInvalid(OAuthPKCEValidationError)
    case randomGenerationFailed
    case authorizationAlreadyInProgress
    case cancelled
    case timedOut
    case sessionFailed
    case loopbackListenerUnavailable
    case callbackMismatch
    case stateMismatch
    case authorizationRejected(String)
    case authorizationCodeMissing
    case tokenExchangeRejected(statusCode: Int)
    case invalidTokenResponse
    case refreshTokenMissing
    case storageFailure
}

@MainActor
final class OAuthAuthorizationFlow {
    private static let maximumTokenLength = 65_536

    private let storage: any OAuthTokenSecretStoring
    private let transport: any OAuthTokenRefreshTransporting
    private let authorizationSession: any OAuthAuthorizationSessioning
    private let proofFactory: () throws -> OAuthPKCEProof
    private let authorizationTimeoutNanoseconds: UInt64

    init(
        storage: any OAuthTokenSecretStoring = KeychainOAuthTokenSecretStorage(),
        transport: any OAuthTokenRefreshTransporting = URLSessionOAuthTokenRefreshTransport(),
        authorizationSession: any OAuthAuthorizationSessioning =
            LoopbackOAuthAuthorizationSession(),
        proofFactory: @escaping () throws -> OAuthPKCEProof = OAuthPKCEProof.secureRandom,
        authorizationTimeoutNanoseconds: UInt64 = 300_000_000_000
    ) {
        self.storage = storage
        self.transport = transport
        self.authorizationSession = authorizationSession
        self.proofFactory = proofFactory
        self.authorizationTimeoutNanoseconds = max(1, authorizationTimeoutNanoseconds)
    }

    func authorize(
        entry: CredentialPoolEntry,
        providerKind: ProviderKind,
        asOf date: Date = .now
    ) async throws {
        guard entry.secretKind == .oauthRefreshToken else {
            throw OAuthAuthorizationFlowError.unsupportedCredentialType
        }
        guard let configuration = entry.oauth else {
            throw OAuthAuthorizationFlowError.configurationInvalid(.clientIDRequired)
        }
        if let error = configuration.validationError(asOf: date) {
            throw OAuthAuthorizationFlowError.configurationInvalid(error)
        }
        switch CredentialCompliancePolicy.authorizationDecision(
            for: entry,
            providerKind: providerKind,
            asOf: date
        ) {
        case .allowed:
            break
        case .blocked(let reason):
            throw OAuthAuthorizationFlowError.complianceBlocked(reason)
        }

        let proof = try proofFactory()
        let authorizationURL = try makeAuthorizationURL(
            configuration: configuration,
            proof: proof
        )
        let callbackURL = try await authorizationSession.authenticate(
            at: authorizationURL,
            callbackURL: configuration.redirectURI,
            timeoutNanoseconds: authorizationTimeoutNanoseconds
        )
        let code = try authorizationCode(
            from: callbackURL,
            configuration: configuration,
            expectedState: proof.state
        )
        let response: OAuthTokenRefreshResponse
        do {
            response = try await transport.send(OAuthTokenRefreshRequest(
                endpoint: configuration.tokenEndpoint,
                formData: OAuthTokenManager.formEncoded([
                    ("grant_type", "authorization_code"),
                    ("code", code),
                    ("client_id", configuration.clientID),
                    ("redirect_uri", configuration.redirectURI.absoluteString),
                    ("code_verifier", proof.verifier)
                ])
            ))
        } catch let error as OAuthAuthorizationFlowError {
            throw error
        } catch {
            throw OAuthAuthorizationFlowError.sessionFailed
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OAuthAuthorizationFlowError.tokenExchangeRejected(
                statusCode: response.statusCode
            )
        }
        let payload: AuthorizationTokenPayload
        do {
            payload = try JSONDecoder().decode(AuthorizationTokenPayload.self, from: response.data)
        } catch {
            throw OAuthAuthorizationFlowError.invalidTokenResponse
        }
        guard Self.isValidToken(payload.accessToken),
              payload.expiresIn.isFinite,
              payload.expiresIn > 0
        else { throw OAuthAuthorizationFlowError.invalidTokenResponse }
        let grantedScopes = Set(
            payload.scope.split(whereSeparator: \.isWhitespace).map(String.init)
        )
        guard Set(configuration.scopes).isSubset(of: grantedScopes) else {
            throw OAuthAuthorizationFlowError.invalidTokenResponse
        }
        guard let refreshToken = payload.refreshToken,
              Self.isValidToken(refreshToken)
        else { throw OAuthAuthorizationFlowError.refreshTokenMissing }
        guard let canonicalOrigin = OAuthCredentialBindingPolicy
            .canonicalOrigin(for: providerKind)
        else { throw OAuthAuthorizationFlowError.callbackMismatch }

        let secret = OAuthTokenSecret(
            accessToken: payload.accessToken,
            refreshToken: refreshToken,
            expiresAt: date.addingTimeInterval(payload.expiresIn),
            providerID: entry.providerID,
            providerKind: providerKind,
            canonicalOrigin: canonicalOrigin
        )
        do {
            try await storage.replaceValue(try secret.keychainValue(), for: entry.id)
        } catch {
            throw OAuthAuthorizationFlowError.storageFailure
        }
    }

    func cancel() async {
        await authorizationSession.cancel()
    }

    func revokeLocalAuthorization(for credentialID: UUID) async throws {
        await authorizationSession.cancel()
        do {
            try await storage.deleteValue(for: credentialID)
        } catch {
            throw OAuthAuthorizationFlowError.storageFailure
        }
    }

    private func makeAuthorizationURL(
        configuration: OAuthPKCEConfiguration,
        proof: OAuthPKCEProof
    ) throws -> URL {
        guard var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else { throw OAuthAuthorizationFlowError.callbackMismatch }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: proof.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: proof.state),
            URLQueryItem(name: "nonce", value: proof.nonce),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = components.url else {
            throw OAuthAuthorizationFlowError.callbackMismatch
        }
        return url
    }

    private func authorizationCode(
        from callback: URL,
        configuration: OAuthPKCEConfiguration,
        expectedState: String
    ) throws -> String {
        guard callback.scheme?.lowercased() == configuration.redirectURI.scheme?.lowercased(),
              callback.host?.lowercased() == configuration.redirectURI.host?.lowercased(),
              callback.port == configuration.redirectURI.port,
              callback.path == configuration.redirectURI.path,
              callback.user == nil,
              callback.password == nil,
              callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        else { throw OAuthAuthorizationFlowError.callbackMismatch }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let safeError = String(error.prefix(80))
            throw safeError == "access_denied"
                ? OAuthAuthorizationFlowError.cancelled
                : OAuthAuthorizationFlowError.authorizationRejected(safeError)
        }
        guard let returnedState = items.first(where: { $0.name == "state" })?.value,
              Self.constantTimeEqual(returnedState, expectedState)
        else { throw OAuthAuthorizationFlowError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty,
              code.utf8.count <= Self.maximumTokenLength
        else { throw OAuthAuthorizationFlowError.authorizationCodeMissing }
        return code
    }

    private static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumTokenLength
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }

    private struct AuthorizationTokenPayload: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
        let scope: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }
}

enum OAuthTokenManagerError: Error, Equatable, Sendable {
    case unsupportedCredentialType
    case configurationMissing
    case configurationInvalid(OAuthPKCEValidationError)
    case complianceBlocked(CredentialAutomationBlockReason)
    case secretMissing
    case secretMalformed
    case secretBindingMismatch
    case storageFailure
    case transportFailure
    case serverRejected(statusCode: Int)
    case authorizationIrrecoverable(errorCode: String)
    case responseTooLarge(limit: Int)
    case invalidResponse
}

actor OAuthTokenManager {
    private static let refreshLeadTime: TimeInterval = 60
    private static let maximumSecretLength = 65_536

    private let storage: any OAuthTokenSecretStoring
    private let transport: any OAuthTokenRefreshTransporting
    private struct InFlightResolution {
        var id: UUID
        var isUnauthorizedRefresh: Bool
        var task: Task<OAuthTokenSecret, Error>
    }

    private var inFlight: [UUID: InFlightResolution] = [:]

    init(
        storage: any OAuthTokenSecretStoring = KeychainOAuthTokenSecretStorage(),
        transport: any OAuthTokenRefreshTransporting = URLSessionOAuthTokenRefreshTransport()
    ) {
        self.storage = storage
        self.transport = transport
    }

    func accessToken(
        for entry: CredentialPoolEntry,
        providerKind: ProviderKind,
        asOf date: Date = .now,
        forceRefresh: Bool = false
    ) async throws -> String {
        try await accessToken(
            for: entry,
            providerKind: providerKind,
            asOf: date,
            intent: forceRefresh ? .force : .normal
        )
    }

    func accessTokenAfterUnauthorized(
        rejectedAccessToken: String,
        for entry: CredentialPoolEntry,
        providerKind: ProviderKind,
        asOf date: Date = .now
    ) async throws -> String {
        try await accessToken(
            for: entry,
            providerKind: providerKind,
            asOf: date,
            intent: .afterUnauthorized(rejectedAccessToken)
        )
    }

    private enum RefreshIntent: Sendable {
        case normal
        case force
        case afterUnauthorized(String)

        var forcesRefresh: Bool {
            switch self {
            case .normal: false
            case .force, .afterUnauthorized: true
            }
        }

        var rejectedAccessToken: String? {
            if case .afterUnauthorized(let value) = self { return value }
            return nil
        }
    }

    private func accessToken(
        for entry: CredentialPoolEntry,
        providerKind: ProviderKind,
        asOf date: Date,
        intent: RefreshIntent
    ) async throws -> String {
        guard entry.secretKind == .oauthRefreshToken else {
            throw OAuthTokenManagerError.unsupportedCredentialType
        }
        guard let configuration = entry.oauth else {
            throw OAuthTokenManagerError.configurationMissing
        }
        if let validationError = configuration.validationError(asOf: date) {
            throw OAuthTokenManagerError.configurationInvalid(validationError)
        }
        switch CredentialCompliancePolicy.automationDecision(
            for: entry,
            providerKind: providerKind,
            asOf: date
        ) {
        case .allowed:
            break
        case let .blocked(reason):
            throw OAuthTokenManagerError.complianceBlocked(reason)
        }

        if let existing = inFlight[entry.id] {
            if !intent.forcesRefresh || existing.isUnauthorizedRefresh {
                return try await awaitFlight(existing, credentialID: entry.id).accessToken
            }

            // A 401-triggered refresh must not join a normal lookup that could
            // simply return the same still-valid token. Wait for that lookup,
            // then compare against the rejected token before deciding whether
            // another network refresh is necessary.
            _ = try await awaitFlight(existing, credentialID: entry.id)
            return try await accessToken(
                for: entry,
                providerKind: providerKind,
                asOf: date,
                intent: intent
            )
        }

        let storage = self.storage
        let transport = self.transport
        let flightID = UUID()
        let task = Task<OAuthTokenSecret, Error> {
            try await Self.resolveSecret(
                entry: entry,
                configuration: configuration,
                providerKind: providerKind,
                asOf: date,
                forceRefresh: intent.forcesRefresh,
                rejectedAccessToken: intent.rejectedAccessToken,
                storage: storage,
                transport: transport
            )
        }
        let flight = InFlightResolution(
            id: flightID,
            isUnauthorizedRefresh: intent.forcesRefresh,
            task: task
        )
        inFlight[entry.id] = flight
        return try await awaitFlight(flight, credentialID: entry.id).accessToken
    }

    private func awaitFlight(
        _ flight: InFlightResolution,
        credentialID: UUID
    ) async throws -> OAuthTokenSecret {
        do {
            let secret = try await flight.task.value
            removeFlightIfCurrent(flight.id, credentialID: credentialID)
            return secret
        } catch {
            removeFlightIfCurrent(flight.id, credentialID: credentialID)
            throw error
        }
    }

    private func removeFlightIfCurrent(_ flightID: UUID, credentialID: UUID) {
        guard inFlight[credentialID]?.id == flightID else { return }
        inFlight.removeValue(forKey: credentialID)
    }

    private static func resolveSecret(
        entry: CredentialPoolEntry,
        configuration: OAuthPKCEConfiguration,
        providerKind: ProviderKind,
        asOf date: Date,
        forceRefresh: Bool,
        rejectedAccessToken: String?,
        storage: any OAuthTokenSecretStoring,
        transport: any OAuthTokenRefreshTransporting
    ) async throws -> OAuthTokenSecret {
        let storedValue: String?
        do {
            storedValue = try await storage.readValue(for: entry.id)
        } catch {
            throw OAuthTokenManagerError.storageFailure
        }
        guard let storedValue else {
            throw OAuthTokenManagerError.secretMissing
        }

        let current: OAuthTokenSecret
        do {
            current = try OAuthTokenSecret(keychainValue: storedValue)
        } catch {
            throw OAuthTokenManagerError.secretMalformed
        }
        guard OAuthCredentialBindingPolicy.isBound(
            current,
            to: entry,
            providerKind: providerKind
        ) else {
            throw OAuthTokenManagerError.secretBindingMismatch
        }
        guard isValidSecretValue(current.accessToken),
              isValidSecretValue(current.refreshToken)
        else {
            throw OAuthTokenManagerError.secretMalformed
        }

        if let rejectedAccessToken,
           current.accessToken != rejectedAccessToken,
           current.expiresAt.timeIntervalSince(date) > refreshLeadTime
        {
            return current
        }
        if !forceRefresh,
           current.expiresAt.timeIntervalSince(date) > refreshLeadTime
        {
            return current
        }

        let request = OAuthTokenRefreshRequest(
            endpoint: configuration.tokenEndpoint,
            formData: formEncoded([
                ("grant_type", "refresh_token"),
                ("client_id", configuration.clientID),
                ("refresh_token", current.refreshToken)
            ])
        )
        let response: OAuthTokenRefreshResponse
        do {
            response = try await transport.send(request)
        } catch let error as OAuthTokenManagerError {
            throw error
        } catch {
            throw OAuthTokenManagerError.transportFailure
        }

        guard (200..<300).contains(response.statusCode) else {
            if irrecoverableErrorCode(in: response) == "invalid_grant" {
                throw OAuthTokenManagerError.authorizationIrrecoverable(
                    errorCode: "invalid_grant"
                )
            }
            throw OAuthTokenManagerError.serverRejected(statusCode: response.statusCode)
        }

        let payload: RefreshPayload
        do {
            payload = try JSONDecoder().decode(RefreshPayload.self, from: response.data)
        } catch {
            throw OAuthTokenManagerError.invalidResponse
        }
        guard isValidSecretValue(payload.accessToken),
              payload.expiresIn.isFinite,
              payload.expiresIn > 0
        else {
            throw OAuthTokenManagerError.invalidResponse
        }

        let replacementRefreshToken: String
        if let supplied = payload.refreshToken {
            guard isValidSecretValue(supplied) else {
                throw OAuthTokenManagerError.invalidResponse
            }
            replacementRefreshToken = supplied
        } else {
            replacementRefreshToken = current.refreshToken
        }
        let refreshed = OAuthTokenSecret(
            accessToken: payload.accessToken,
            refreshToken: replacementRefreshToken,
            expiresAt: date.addingTimeInterval(payload.expiresIn),
            providerID: current.providerID,
            providerKind: current.providerKind,
            canonicalOrigin: current.canonicalOrigin
        )

        let replacementValue: String
        do {
            replacementValue = try refreshed.keychainValue()
            try await storage.replaceValue(replacementValue, for: entry.id)
        } catch {
            throw OAuthTokenManagerError.storageFailure
        }
        return refreshed
    }

    private static func irrecoverableErrorCode(
        in response: OAuthTokenRefreshResponse
    ) -> String? {
        guard response.data.count <= 65_536,
              let payload = try? JSONDecoder().decode(
                RefreshErrorPayload.self,
                from: response.data
              )
        else { return nil }
        let code = payload.error.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return code == "invalid_grant" ? code : nil
    }

    private static func isValidSecretValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumSecretLength
    }

    fileprivate static func formEncoded(_ fields: [(String, String)]) -> Data {
        let string = fields.map { key, value in
            "\(formComponent(key))=\(formComponent(value))"
        }.joined(separator: "&")
        return Data(string.utf8)
    }

    private static func formComponent(_ value: String) -> String {
        value.utf8.map { byte -> String in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                return String(UnicodeScalar(byte))
            case 0x20:
                return "+"
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private struct RefreshPayload: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct RefreshErrorPayload: Decodable {
        var error: String
    }
}
