import Foundation
import LocalAuthentication
import Security

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

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func providerAccount(_ id: UUID) -> String {
        "provider.\(id.uuidString)"
    }

    static func proxySubscriptionAccount(_ id: UUID) -> String {
        "proxy.subscription.\(id.uuidString.lowercased()).url"
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
