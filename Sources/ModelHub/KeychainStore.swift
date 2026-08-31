import Foundation
import LocalAuthentication
import ModelHubCore
import Security

protocol CredentialSecretDeleting: Sendable {
    func delete(account: String) async throws
}

enum CredentialSecretDeletionError: LocalizedError, Equatable, Sendable {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "钥匙串删除失败（\(status)）"
        }
    }
}

struct KeychainCredentialSecretDeleter: CredentialSecretDeleting {
    func delete(account: String) async throws {
        let status = KeychainStore.delete(account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialSecretDeletionError.status(status)
        }
    }
}

enum KeychainStore {
    private static let service = "com.local.modelhub.secrets"

    private actor NonInteractiveLookupCoordinator {
        static let shared = NonInteractiveLookupCoordinator()

        func read(account: String) -> LookupResult {
            KeychainStore.readWithoutInteraction(account: account)
        }
    }

    enum LookupResult: Equatable, Sendable {
        case value(String)
        case notFound
        case interactionRequired
        case failure(OSStatus)
    }

    enum CredentialBindingError: Error, Equatable {
        case malformed
        case mismatch
        case insecureProviderEndpoint
    }

    private struct BoundCredentialPoolAPIKey: Codable {
        let schemaVersion: Int
        let credentialID: UUID
        let providerID: UUID
        let providerKind: ProviderKind
        let endpointBinding: String
        let apiKey: String
    }

    private struct BoundProviderAPIKey: Codable {
        let schemaVersion: Int
        let providerID: UUID
        let providerKind: ProviderKind
        let endpointBinding: String
        let apiKey: String
    }

    static func boundProviderAPIKeyValue(
        _ apiKey: String,
        provider: ProviderConfig
    ) throws -> String {
        guard let endpointBinding = ProviderEndpointSecurity
            .credentialBindingIdentifier(for: provider)
        else { throw CredentialBindingError.insecureProviderEndpoint }
        let payload = BoundProviderAPIKey(
            schemaVersion: 1,
            providerID: provider.id,
            providerKind: provider.kind,
            endpointBinding: endpointBinding,
            apiKey: apiKey
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = String(data: try encoder.encode(payload), encoding: .utf8) else {
            throw CredentialBindingError.malformed
        }
        return encoded
    }

    static func apiKey(
        fromBoundProviderValue value: String,
        provider: ProviderConfig
    ) throws -> String {
        guard let data = value.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BoundProviderAPIKey.self, from: data),
              payload.schemaVersion == 1,
              !payload.apiKey.isEmpty
        else { throw CredentialBindingError.malformed }
        guard let expectedBinding = ProviderEndpointSecurity
            .credentialBindingIdentifier(for: provider)
        else { throw CredentialBindingError.insecureProviderEndpoint }
        guard payload.providerID == provider.id,
              payload.providerKind == provider.kind,
              payload.endpointBinding == expectedBinding
        else { throw CredentialBindingError.mismatch }
        return payload.apiKey
    }

    /// Converts a pre-1.10 raw Keychain value into the endpoint-bound envelope.
    /// This is deliberately separate from normal decoding: the data plane
    /// continues to fail closed and can never silently fall back to raw values.
    /// A JSON-looking value is treated as a damaged/newer envelope rather than
    /// as a legacy secret, preventing malformed metadata from being discarded.
    static func migratedBoundProviderAPIKeyValue(
        fromLegacyValue value: String,
        provider: ProviderConfig
    ) throws -> String {
        let legacy = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty,
              legacy.utf8.count <= 16_384,
              legacy.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else { throw CredentialBindingError.malformed }

        let first = legacy.first
        guard first != "{", first != "[" else {
            throw CredentialBindingError.malformed
        }
        guard ProviderCredentialPolicy.validationMessage(
            for: provider.kind,
            apiKey: legacy
        ) == nil else {
            throw CredentialBindingError.mismatch
        }
        return try boundProviderAPIKeyValue(legacy, provider: provider)
    }

    static func boundCredentialPoolAPIKeyValue(
        _ apiKey: String,
        credentialID: UUID,
        provider: ProviderConfig
    ) throws -> String {
        guard let endpointBinding = ProviderEndpointSecurity
            .credentialBindingIdentifier(for: provider)
        else { throw CredentialBindingError.insecureProviderEndpoint }
        let payload = BoundCredentialPoolAPIKey(
            schemaVersion: 1,
            credentialID: credentialID,
            providerID: provider.id,
            providerKind: provider.kind,
            endpointBinding: endpointBinding,
            apiKey: apiKey
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = String(data: try encoder.encode(payload), encoding: .utf8) else {
            throw CredentialBindingError.malformed
        }
        return encoded
    }

    static func apiKey(
        fromBoundCredentialPoolValue value: String,
        credentialID: UUID,
        provider: ProviderConfig
    ) throws -> String {
        guard let data = value.data(using: .utf8),
              let payload = try? JSONDecoder().decode(
                  BoundCredentialPoolAPIKey.self,
                  from: data
              ),
              payload.schemaVersion == 1,
              !payload.apiKey.isEmpty
        else { throw CredentialBindingError.malformed }
        guard let expectedBinding = ProviderEndpointSecurity
            .credentialBindingIdentifier(for: provider)
        else { throw CredentialBindingError.insecureProviderEndpoint }
        guard payload.credentialID == credentialID,
              payload.providerID == provider.id,
              payload.providerKind == provider.kind,
              payload.endpointBinding == expectedBinding
        else { throw CredentialBindingError.mismatch }
        return payload.apiKey
    }

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    static func read(account: String) -> String? {
        guard case .value(let value) = lookup(account: account, allowInteraction: true) else {
            return nil
        }
        return value
    }

    static func readWithoutInteraction(account: String) -> LookupResult {
        lookup(account: account, allowInteraction: false)
    }

    static func readWithoutInteractionAsync(account: String) async -> LookupResult {
        await NonInteractiveLookupCoordinator.shared.read(account: account)
    }

    static func nonInteractiveLookupQuery(account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }

    static func existsWithoutInteraction(account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }

    static func providerAccount(_ id: UUID) -> String {
        "provider.\(id.uuidString)"
    }

    static func proxySubscriptionAccount(_ id: UUID) -> String {
        "proxy.subscription.\(id.uuidString.lowercased()).url"
    }

    static func credentialPoolAccount(_ id: UUID) -> String {
        "credential.pool.\(id.uuidString.lowercased()).secret"
    }

    static let gatewayTokenAccount = "gateway.token"
    static let agentTokenAccount = "agent.token"
    static let proxyControllerSecretAccount = "proxy.controller.secret"

    private static func lookup(account: String, allowInteraction: Bool) -> LookupResult {
        let query: [String: Any] = allowInteraction ? [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] : nonInteractiveLookupQuery(account: account)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { return .failure(errSecDecode) }
            return .value(value)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .interactionRequired
        default:
            return .failure(status)
        }
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                return SecCopyErrorMessageString(status, nil) as String? ?? "钥匙串错误 \(status)"
            }
        }
    }
}
