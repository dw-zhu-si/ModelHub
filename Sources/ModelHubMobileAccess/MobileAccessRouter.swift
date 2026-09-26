import Foundation

public extension JSONEncoder {
    static var mobile: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var mobile: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct MobileAccessHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method.uppercased()
        self.path = path
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct MobileAccessHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum MobilePairingWireState: String, Codable, Equatable, Sendable {
    case awaitingApproval = "awaiting_approval"
    case approved
    case rejected
}

public struct MobilePairingSubmissionResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let state: MobilePairingWireState
    public let expiresAt: Date
    public let pollAfterSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case state
        case expiresAt = "expires_at"
        case pollAfterSeconds = "poll_after_seconds"
    }
}

public struct MobilePairingStatusRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let secret: String

    public init(requestID: UUID, secret: String) {
        self.requestID = requestID
        self.secret = secret
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case secret
    }
}

public struct MobilePairingStatusResponse: Codable, Equatable, Sendable {
    public let state: MobilePairingWireState
    public let credential: MobileDeviceCredential?
}

public struct MobileBootstrapResponse: Codable, Equatable, Sendable {
    public let overview: MobileGatewayOverview
    public let grantedPermissions: Set<MobilePermissionScope>

    private enum CodingKeys: String, CodingKey {
        case overview
        case grantedPermissions = "granted_permissions"
    }
}

public actor MobileAccessRouter {
    public typealias OverviewProvider = @Sendable () async -> MobileGatewayOverview
    public typealias PairingSubmittedHandler = @Sendable () async -> Void
    public typealias DeviceActivityObservedHandler = @Sendable () async -> Void

    private let coordinator: MobilePairingCoordinator
    private let overviewProvider: OverviewProvider
    private let pairingSubmitted: PairingSubmittedHandler?
    private let deviceActivityObserved: DeviceActivityObservedHandler?
    private let maximumPairingBodyBytes = 16_384

    public init(
        coordinator: MobilePairingCoordinator,
        overviewProvider: @escaping OverviewProvider,
        pairingSubmitted: PairingSubmittedHandler? = nil,
        deviceActivityObserved: DeviceActivityObservedHandler? = nil
    ) {
        self.coordinator = coordinator
        self.overviewProvider = overviewProvider
        self.pairingSubmitted = pairingSubmitted
        self.deviceActivityObserved = deviceActivityObserved
    }

    public func handle(
        _ request: MobileAccessHTTPRequest,
        now: Date = .now
    ) async -> MobileAccessHTTPResponse {
        guard request.body.count <= maximumPairingBodyBytes else {
            return error(statusCode: 413, code: "request_too_large", message: "请求体超过 16 KiB")
        }

        switch (request.method, request.path) {
        case ("POST", "/mobile/v1/pairing/complete"):
            return await submitPairing(request, now: now)
        case ("POST", "/mobile/v1/pairing/status"):
            return await pairingStatus(request, now: now)
        case ("GET", "/mobile/v1/bootstrap"):
            return await bootstrap(request, now: now)
        default:
            return error(statusCode: 404, code: "not_found", message: "移动接口不存在")
        }
    }

    private func submitPairing(
        _ request: MobileAccessHTTPRequest,
        now: Date
    ) async -> MobileAccessHTTPResponse {
        guard isJSON(request),
              let completion = try? JSONDecoder.mobile.decode(
                  MobilePairingCompletionRequest.self,
                  from: request.body
              )
        else {
            return error(statusCode: 400, code: "invalid_pairing_request", message: "配对请求无效")
        }
        do {
            let pending = try await coordinator.submitPairing(completion, now: now)
            await pairingSubmitted?()
            return json(
                statusCode: 202,
                MobilePairingSubmissionResponse(
                    requestID: pending.id,
                    state: .awaitingApproval,
                    expiresAt: pending.expiresAt,
                    pollAfterSeconds: 2
                )
            )
        } catch {
            return pairingError(error)
        }
    }

    private func pairingStatus(
        _ request: MobileAccessHTTPRequest,
        now: Date
    ) async -> MobileAccessHTTPResponse {
        guard isJSON(request),
              let statusRequest = try? JSONDecoder.mobile.decode(
                  MobilePairingStatusRequest.self,
                  from: request.body
              )
        else {
            return error(statusCode: 400, code: "invalid_pairing_status", message: "配对状态请求无效")
        }
        do {
            let status = try await coordinator.pairingStatus(
                requestID: statusRequest.requestID,
                secret: statusRequest.secret,
                now: now
            )
            switch status {
            case .awaitingApproval:
                return json(
                    statusCode: 200,
                    MobilePairingStatusResponse(state: .awaitingApproval, credential: nil)
                )
            case .approved(let credential):
                return json(
                    statusCode: 200,
                    MobilePairingStatusResponse(state: .approved, credential: credential)
                )
            case .rejected:
                return json(
                    statusCode: 200,
                    MobilePairingStatusResponse(state: .rejected, credential: nil)
                )
            }
        } catch {
            return pairingError(error)
        }
    }

    private func bootstrap(
        _ request: MobileAccessHTTPRequest,
        now: Date
    ) async -> MobileAccessHTTPResponse {
        guard request.body.isEmpty,
              let proof = signedProof(from: request)
        else {
            return error(statusCode: 401, code: "invalid_device_proof", message: "缺少或无效的设备证明")
        }
        do {
            let device = try await coordinator.authorize(
                proof,
                request: MobileRequestDescriptor(
                    method: request.method,
                    path: request.path,
                    body: request.body
                ),
                requiring: .viewer,
                now: now
            )
            await deviceActivityObserved?()
            let overview = await overviewProvider()
            return json(
                statusCode: 200,
                MobileBootstrapResponse(
                    overview: overview,
                    grantedPermissions: device.permissions
                )
            )
        } catch let error as MobileAccessError {
            switch error {
            case .insufficientPermission:
                return self.error(statusCode: 403, code: "insufficient_permission", message: "设备没有查看概览的权限")
            case .requestRateLimited:
                return self.error(statusCode: 429, code: "device_rate_limited", message: "设备请求过于频繁")
            default:
                return self.error(statusCode: 401, code: "invalid_device_proof", message: "设备证明无效或已失效")
            }
        } catch {
            return self.error(statusCode: 401, code: "invalid_device_proof", message: "设备证明无效或已失效")
        }
    }

    private func signedProof(from request: MobileAccessHTTPRequest) -> MobileSignedRequestProof? {
        guard let rawDeviceID = request.header("X-ModelHub-Device-ID"),
              let deviceID = UUID(uuidString: rawDeviceID),
              let rawTimestamp = request.header("X-ModelHub-Timestamp"),
              let timestamp = Int64(rawTimestamp),
              let nonce = request.header("X-ModelHub-Nonce"),
              let signature = request.header("X-ModelHub-Signature")
        else { return nil }
        return MobileSignedRequestProof(
            deviceID: deviceID,
            timestamp: timestamp,
            nonce: nonce,
            signature: signature
        )
    }

    private func isJSON(_ request: MobileAccessHTTPRequest) -> Bool {
        request.header("Content-Type")?.lowercased().split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "application/json"
    }

    private func pairingError(_ rawError: Error) -> MobileAccessHTTPResponse {
        guard let error = rawError as? MobileAccessError else {
            return self.error(statusCode: 400, code: "pairing_failed", message: "配对失败")
        }
        switch error {
        case .pairingUnavailable, .pairingExpired:
            return self.error(statusCode: 410, code: "pairing_unavailable", message: "配对已过期或不可用")
        case .invalidPairingSecret:
            return self.error(statusCode: 401, code: "invalid_pairing_secret", message: "配对凭据无效")
        case .invalidDeviceName, .invalidPublicKey, .invalidRequest:
            return self.error(statusCode: 400, code: "invalid_pairing_request", message: "设备信息无效")
        case .deviceAlreadyPaired:
            return self.error(statusCode: 409, code: "device_already_paired", message: "设备已经配对")
        case .deviceCapacityExceeded, .pairingCapacityExceeded:
            return self.error(statusCode: 503, code: "pairing_capacity_exceeded", message: "当前无法接受更多配对")
        default:
            return self.error(statusCode: 400, code: "pairing_failed", message: "配对失败")
        }
    }

    private func json<Value: Encodable>(
        statusCode: Int,
        _ value: Value
    ) -> MobileAccessHTTPResponse {
        guard let data = try? JSONEncoder.mobile.encode(value) else {
            return error(statusCode: 500, code: "encoding_failed", message: "响应编码失败")
        }
        return MobileAccessHTTPResponse(
            statusCode: statusCode,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store"
            ],
            body: data
        )
    }

    private func error(
        statusCode: Int,
        code: String,
        message: String
    ) -> MobileAccessHTTPResponse {
        struct ErrorEnvelope: Encodable {
            struct Detail: Encodable {
                let code: String
                let message: String
            }
            let error: Detail
        }
        return json(
            statusCode: statusCode,
            ErrorEnvelope(error: .init(code: code, message: message))
        )
    }
}
