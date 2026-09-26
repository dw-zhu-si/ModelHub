import Foundation
import ModelHubShared
import Observation
import Security

extension MobileGatewayClient: @unchecked @retroactive Sendable {}
extension MobilePairingPayload: @unchecked @retroactive Sendable {}
extension MobilePairingSubmission: @unchecked @retroactive Sendable {}
extension MobilePairingStatus: @unchecked @retroactive Sendable {}
extension MobileBootstrap: @unchecked @retroactive Sendable {}

@MainActor
@Observable
final class MobileStore {
    enum State {
        case unpaired
        case awaitingApproval
        case connected(MobileBootstrap)
        case offline(MobileBootstrap?)
        case revoked
        case failed(String)
    }

    private let serviceURLKey = "modelhub.mobile.service-url"
    private let fingerprintKey = "modelhub.mobile.certificate-fingerprint"
    private let lastBootstrapKey = "modelhub.mobile.last-bootstrap"
    private let identity = IOSDeviceIdentity()
    private var transport: PinnedGatewayTransport?
    private var client: MobileGatewayClient?
    private var pendingSecret: String?
    private var pollGeneration = UUID()

    var state: State = .unpaired
    var serviceURL: String? { UserDefaults.standard.string(forKey: serviceURLKey) }

    init() {
        let cached = UserDefaults.standard.string(forKey: lastBootstrapKey)
            .flatMap { try? MobileJson.shared.decodeBootstrap(value: $0) }
        if identity.isPaired, serviceURL != nil {
            state = .offline(cached)
            refresh()
        }
    }

    func pair(rawPayload: String, deviceName: String) {
        pollGeneration = UUID()
        let generation = pollGeneration
        do {
            let payload = try MobileJson.shared.decodePairingPayload(value: rawPayload.trimmingCharacters(in: .whitespacesAndNewlines))
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(name.utf8.count) else { throw StoreError.invalidDeviceName }
            pendingSecret = payload.secret
            let client = try makeClient(serviceURL: payload.serviceUrl, fingerprint: payload.certificateFingerprint)
            client.submitPairing(payload: payload, deviceName: name) { [weak self] submission, error in
                Task { @MainActor in
                    guard let self, generation == self.pollGeneration else { return }
                    if let error {
                        self.pendingSecret = nil
                        self.state = .failed(error.localizedDescription)
                        return
                    }
                    guard let submission, submission.state == .awaitingApproval else {
                        self.pendingSecret = nil
                        self.state = .failed("桌面端未返回等待审批状态")
                        return
                    }
                    self.state = .awaitingApproval
                    self.poll(
                        client: client,
                        payload: payload,
                        requestID: submission.requestId,
                        delaySeconds: max(1, min(10, Int(submission.pollAfterSeconds))),
                        attemptsRemaining: 150,
                        generation: generation
                    )
                }
            }
        } catch {
            pendingSecret = nil
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() {
        guard let serviceURL,
              let fingerprint = UserDefaults.standard.string(forKey: fingerprintKey)
        else {
            state = .unpaired
            return
        }
        do {
            let client = try makeClient(serviceURL: serviceURL, fingerprint: fingerprint)
            client.bootstrap { [weak self] bootstrap, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let bootstrap {
                        UserDefaults.standard.set(MobileJson.shared.encodeBootstrap(value: bootstrap), forKey: self.lastBootstrapKey)
                        self.state = .connected(bootstrap)
                    } else if error?.localizedDescription.contains("HTTP 401") == true {
                        self.state = .revoked
                    } else {
                        let cached = UserDefaults.standard.string(forKey: self.lastBootstrapKey)
                            .flatMap { try? MobileJson.shared.decodeBootstrap(value: $0) }
                        self.state = .offline(cached)
                    }
                }
            }
        } catch {
            state = .offline(nil)
        }
    }

    func forgetBinding() {
        pollGeneration = UUID()
        pendingSecret = nil
        client = nil
        transport = nil
        do {
            try identity.forgetDevice()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        UserDefaults.standard.removeObject(forKey: serviceURLKey)
        UserDefaults.standard.removeObject(forKey: fingerprintKey)
        UserDefaults.standard.removeObject(forKey: lastBootstrapKey)
        state = .unpaired
    }

    private func poll(
        client: MobileGatewayClient,
        payload: MobilePairingPayload,
        requestID: String,
        delaySeconds: Int,
        attemptsRemaining: Int,
        generation: UUID
    ) {
        guard attemptsRemaining > 0 else {
            pendingSecret = nil
            state = .failed("桌面审批等待超时，请重新生成二维码")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delaySeconds)) { [weak self] in
            guard let self, generation == self.pollGeneration,
                  let secret = self.pendingSecret
            else { return }
            client.pairingStatus(requestId: requestID, secret: secret) { [weak self] status, error in
                Task { @MainActor in
                    guard let self, generation == self.pollGeneration else { return }
                    if let error {
                        self.pendingSecret = nil
                        self.state = .failed(error.localizedDescription)
                        return
                    }
                    guard let status else {
                        self.state = .failed("配对状态响应无效")
                        return
                    }
                    switch status.state {
                    case .awaitingApproval:
                        self.poll(
                            client: client,
                            payload: payload,
                            requestID: requestID,
                            delaySeconds: delaySeconds,
                            attemptsRemaining: attemptsRemaining - 1,
                            generation: generation
                        )
                    case .rejected:
                        self.pendingSecret = nil
                        self.state = .failed("桌面端已拒绝该设备")
                    case .approved:
                        do {
                            guard let credential = status.credential,
                                  credential.permissions.contains(MobilePermission.viewer)
                            else { throw StoreError.missingViewerPermission }
                            try self.identity.storeApprovedDevice(id: credential.deviceId)
                            UserDefaults.standard.set(payload.serviceUrl, forKey: self.serviceURLKey)
                            UserDefaults.standard.set(payload.certificateFingerprint, forKey: self.fingerprintKey)
                            self.pendingSecret = nil
                            self.refresh()
                        } catch {
                            self.state = .failed(error.localizedDescription)
                        }
                    default:
                        self.state = .failed("桌面端返回了未知配对状态")
                    }
                }
            }
        }
    }

    private func makeClient(serviceURL: String, fingerprint: String) throws -> MobileGatewayClient {
        let transport = try PinnedGatewayTransport(serviceURL: serviceURL, certificateFingerprint: fingerprint)
        self.transport = transport
        let client = MobileGatewayClient(
            transport: transport,
            signer: identity,
            timestampSeconds: { KotlinLong(value: Int64(Date().timeIntervalSince1970)) },
            nonce: Self.randomNonce
        )
        self.client = client
        return client
    }

    private static func randomNonce() -> String {
        var data = Data(count: 24)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { return UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    enum StoreError: LocalizedError {
        case invalidDeviceName
        case missingViewerPermission

        var errorDescription: String? {
            switch self {
            case .invalidDeviceName: "设备名称需要 1–80 个字节"
            case .missingViewerPermission: "桌面端未授予概览查看权限"
            }
        }
    }
}
