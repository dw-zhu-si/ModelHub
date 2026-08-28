import Foundation
import LocalAuthentication
import ModelHubCore
import Security
import Testing
@testable import ModelHub

@Suite("KeychainStoreTests")
struct KeychainStoreTests {
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
}
