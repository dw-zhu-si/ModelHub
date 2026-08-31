import Foundation
import LocalAuthentication
import ModelHubCore
import Security
import Testing
@testable import ModelHub

@Suite("KeychainStoreTests")
struct KeychainStoreTests {
    @Test("默认供应商 API Key 绑定供应商类型与全部上游 origin")
    func defaultProviderAPIKeyEnvelopeRejectsOriginAndKindRebinding() throws {
        let provider = ProviderConfig(
            name: "provider",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .imageGeneration): "https://media.example.com/v1/images"
            ]
        )
        let encoded = try KeychainStore.boundProviderAPIKeyValue(
            "top-secret",
            provider: provider
        )

        #expect(
            try KeychainStore.apiKey(
                fromBoundProviderValue: encoded,
                provider: provider
            ) == "top-secret"
        )

        var reboundOrigin = provider
        reboundOrigin.endpointURLs[ProviderEndpointRecord.key(for: .imageGeneration)] =
            "https://attacker.example/v1/images"
        #expect(throws: KeychainStore.CredentialBindingError.self) {
            try KeychainStore.apiKey(
                fromBoundProviderValue: encoded,
                provider: reboundOrigin
            )
        }

        var reboundKind = provider
        reboundKind.kind = .anthropic
        #expect(throws: KeychainStore.CredentialBindingError.self) {
            try KeychainStore.apiKey(
                fromBoundProviderValue: encoded,
                provider: reboundKind
            )
        }
    }

    @Test("默认供应商旧版明文 API Key 失败关闭")
    func legacyUnboundDefaultProviderAPIKeyFailsClosed() {
        let provider = ProviderConfig(
            name: "provider",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1"
        )

        #expect(throws: KeychainStore.CredentialBindingError.self) {
            try KeychainStore.apiKey(
                fromBoundProviderValue: "legacy-raw-secret",
                provider: provider
            )
        }
    }

    @Test("旧版原始 API Key 可一次性迁移为当前安全端点绑定")
    func legacyDefaultProviderAPIKeyCanBeMigratedToSecureBinding() throws {
        let provider = ProviderConfig(
            name: "legacy-provider",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1",
            endpointURLs: [
                ProviderEndpointRecord.key(for: .imageGeneration):
                    "https://media.example.com/v1/images"
            ]
        )

        let migrated = try KeychainStore.migratedBoundProviderAPIKeyValue(
            fromLegacyValue: "legacy-top-secret",
            provider: provider
        )

        #expect(migrated != "legacy-top-secret")
        #expect(
            try KeychainStore.apiKey(
                fromBoundProviderValue: migrated,
                provider: provider
            ) == "legacy-top-secret"
        )
    }

    @Test("旧版迁移拒绝伪装成封装的损坏 JSON 与不安全端点")
    func legacyDefaultProviderMigrationFailsClosedForAmbiguousOrInsecureValues() {
        let secureProvider = ProviderConfig(
            name: "secure-provider",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1"
        )
        let insecureProvider = ProviderConfig(
            name: "insecure-provider",
            kind: .unifiedCompatible,
            baseURL: "http://api.example.com/v1"
        )

        #expect(throws: KeychainStore.CredentialBindingError.self) {
            try KeychainStore.migratedBoundProviderAPIKeyValue(
                fromLegacyValue: #"{"schemaVersion":1,"apiKey":"secret"}"#,
                provider: secureProvider
            )
        }
        #expect(throws: KeychainStore.CredentialBindingError.self) {
            try KeychainStore.migratedBoundProviderAPIKeyValue(
                fromLegacyValue: "legacy-top-secret",
                provider: insecureProvider
            )
        }
    }

    @Test("旧版迁移拒绝空值、控制字符与超长凭证")
    func legacyDefaultProviderMigrationRejectsMalformedRawSecrets() {
        let provider = ProviderConfig(
            name: "provider",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1"
        )

        for value in ["", "   ", "line1\nline2", String(repeating: "x", count: 16_385)] {
            #expect(throws: KeychainStore.CredentialBindingError.self) {
                try KeychainStore.migratedBoundProviderAPIKeyValue(
                    fromLegacyValue: value,
                    provider: provider
                )
            }
        }
    }

    @Test("默认供应商与凭证池凭证都拒绝非回环 HTTP")
    func apiKeyEnvelopesRejectNonLoopbackHTTP() {
        let provider = ProviderConfig(
            name: "insecure",
            kind: .unifiedCompatible,
            baseURL: "http://api.example.com/v1"
        )

        #expect(throws: KeychainStore.CredentialBindingError.self) {
            try KeychainStore.boundProviderAPIKeyValue("secret", provider: provider)
        }
        #expect(throws: KeychainStore.CredentialBindingError.self) {
            try KeychainStore.boundCredentialPoolAPIKeyValue(
                "secret",
                credentialID: UUID(),
                provider: provider
            )
        }
    }

    @Test("凭证池 API Key 绑定供应商身份与端点 origin")
    func credentialPoolAPIKeyEnvelopeRejectsProviderRebinding() throws {
        let provider = ProviderConfig(
            name: "provider",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1"
        )
        let credentialID = UUID()
        let encoded = try KeychainStore.boundCredentialPoolAPIKeyValue(
            "top-secret",
            credentialID: credentialID,
            provider: provider
        )

        #expect(
            try KeychainStore.apiKey(
                fromBoundCredentialPoolValue: encoded,
                credentialID: credentialID,
                provider: provider
            ) == "top-secret"
        )

        var rebound = provider
        rebound.baseURL = "https://attacker.example/v1"
        #expect(throws: KeychainStore.CredentialBindingError.self) {
            try KeychainStore.apiKey(
                fromBoundCredentialPoolValue: encoded,
                credentialID: credentialID,
                provider: rebound
            )
        }
    }

    @Test("旧版无绑定凭证池值失败关闭")
    func legacyUnboundCredentialPoolAPIKeyFailsClosed() {
        let provider = ProviderConfig(
            name: "provider",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1"
        )

        #expect(throws: KeychainStore.CredentialBindingError.self) {
            try KeychainStore.apiKey(
                fromBoundCredentialPoolValue: "legacy-raw-secret",
                credentialID: UUID(),
                provider: provider
            )
        }
    }

    @Test("授权凭证池使用独立且稳定的 UUID 钥匙串账户")
    func credentialPoolEntryUsesNamespacedKeychainAccount() {
        let id = UUID(uuidString: "AEBC68CA-2D90-4634-8F9D-C4055F35C38D")!

        #expect(
            KeychainStore.credentialPoolAccount(id) ==
                "credential.pool.aebc68ca-2d90-4634-8f9d-c4055f35c38d.secret"
        )
        #expect(KeychainStore.credentialPoolAccount(id) != KeychainStore.providerAccount(id))
    }

    @Test("网关数据面禁止交互式钥匙串读取")
    func dataPlaneCredentialLookupIsNonInteractive() {
        #expect(!DataPlaneCredentialAccessPolicy.allowsInteraction)
    }

    @Test("数据面区分未配置与钥匙串暂时不可读")
    func dataPlaneCredentialLookupDoesNotCollapseInteractionFailureIntoMissingKey() throws {
        #expect(try DataPlaneCredentialAccessPolicy.apiKey(from: .value("secret")) == "secret")
        #expect(try DataPlaneCredentialAccessPolicy.apiKey(from: .notFound).isEmpty)
        #expect(throws: ProviderClientError.self) {
            try DataPlaneCredentialAccessPolicy.apiKey(from: .interactionRequired)
        }
        #expect(throws: ProviderClientError.self) {
            try DataPlaneCredentialAccessPolicy.apiKey(from: .failure(errSecNotAvailable))
        }
    }

    @Test("后台查询缺失项目时不请求交互")
    func missingItemLookupIsNonInteractive() async {
        let account = "tests.missing.\(UUID().uuidString)"

        #expect(KeychainStore.readWithoutInteraction(account: account) == .notFound)
        #expect(await KeychainStore.readWithoutInteractionAsync(account: account) == .notFound)
        #expect(!KeychainStore.existsWithoutInteraction(account: account))
    }

    @Test("后台查询使用禁止交互的 LAContext")
    func nonInteractiveQueryUsesModernAuthenticationContext() throws {
        let query = KeychainStore.nonInteractiveLookupQuery(account: "tests.query")
        let context = try #require(
            query[kSecUseAuthenticationContext as String] as? LAContext
        )

        #expect(context.interactionNotAllowed)
        #expect(query[kSecUseAuthenticationUI as String] == nil)
    }

    @Test("默认 API Key 删除失败时保留健康与供应商状态")
    @MainActor
    func failedDefaultKeyDeletionDoesNotClaimSuccessOrQuarantineModels() async {
        let provider = ProviderConfig(
            name: "deletion-provider",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1",
            models: ["model-a"]
        )
        let account = KeychainStore.providerAccount(provider.id)
        let deleter = FakeCredentialSecretDeleter(failingAccounts: [account])
        let model = AppModel(credentialSecretDeleter: deleter)
        let health = ModelHealthRecord(
            providerID: provider.id,
            model: "model-a",
            status: .available,
            detail: "verified"
        )
        model.configuration = AppConfiguration(
            providers: [provider],
            modelHealth: [health]
        )

        let deleted = await model.deleteAPIKeyAndWait(for: provider)

        #expect(!deleted)
        #expect(model.configuration.providers == [provider])
        #expect(model.configuration.modelHealth == [health])
        #expect(model.notice?.contains("保持不变") == true)
        #expect(model.notice?.contains("已删除") == false)
    }

    @Test("凭证池秘密删除失败时保留条目元数据")
    @MainActor
    func failedPoolSecretDeletionRetainsCredentialEntry() async {
        let provider = ProviderConfig(
            name: "pool-provider",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1"
        )
        let entry = CredentialPoolEntry(
            providerID: provider.id,
            label: "developer-key",
            secretKind: .apiKey,
            intendedUse: .developerAPI
        )
        let account = KeychainStore.credentialPoolAccount(entry.id)
        let deleter = FakeCredentialSecretDeleter(failingAccounts: [account])
        let model = AppModel(credentialSecretDeleter: deleter)
        model.configuration = AppConfiguration(
            providers: [provider],
            credentialPools: [CredentialPoolConfiguration(
                providerID: provider.id,
                entries: [entry],
                manuallySelectedCredentialID: entry.id
            )]
        )

        await model.deleteCredentialPoolEntryAndWait(entry.id)

        #expect(model.configuration.credentialPools.first?.entries == [entry])
        #expect(
            model.configuration.credentialPools.first?.manuallySelectedCredentialID == entry.id
        )
        #expect(model.notice?.contains("元数据已保留") == true)
        #expect(model.notice?.contains("已删除") == false)
    }

    @Test("供应商任一必要秘密删除失败时保留全部配置")
    @MainActor
    func failedProviderSecretDeletionRetainsProviderPoolHealthAndRoute() async {
        let provider = ProviderConfig(
            name: "provider-with-pool",
            kind: .unifiedCompatible,
            baseURL: "https://api.example.com/v1",
            models: ["model-a"]
        )
        let entry = CredentialPoolEntry(
            providerID: provider.id,
            label: "developer-key",
            secretKind: .apiKey,
            intendedUse: .developerAPI
        )
        let poolAccount = KeychainStore.credentialPoolAccount(entry.id)
        let deleter = FakeCredentialSecretDeleter(failingAccounts: [poolAccount])
        let model = AppModel(credentialSecretDeleter: deleter)
        let health = ModelHealthRecord(
            providerID: provider.id,
            model: "model-a",
            status: .available,
            detail: "verified"
        )
        let route = RouteConfig(
            alias: "route-a",
            targets: [RouteTarget(providerID: provider.id, model: "model-a")]
        )
        let pool = CredentialPoolConfiguration(
            providerID: provider.id,
            entries: [entry],
            manuallySelectedCredentialID: entry.id
        )
        model.configuration = AppConfiguration(
            providers: [provider],
            routes: [route],
            modelHealth: [health],
            credentialPools: [pool]
        )

        await model.deleteProviderAndWait(provider)

        #expect(model.configuration.providers == [provider])
        #expect(model.configuration.credentialPools == [pool])
        #expect(model.configuration.modelHealth == [health])
        #expect(model.configuration.routes == [route])
        #expect(model.notice?.contains("保持不变") == true)
        #expect(model.notice?.contains("已删除") == false)
    }
}

private actor FakeCredentialSecretDeleter: CredentialSecretDeleting {
    private let failingAccounts: Set<String>
    private(set) var deletedAccounts: [String] = []

    init(failingAccounts: Set<String>) {
        self.failingAccounts = failingAccounts
    }

    func delete(account: String) async throws {
        deletedAccounts.append(account)
        if failingAccounts.contains(account) {
            throw CredentialSecretDeletionError.status(errSecNotAvailable)
        }
    }
}
