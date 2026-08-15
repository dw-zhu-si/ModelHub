import Foundation
import LocalAuthentication
import Security
import Testing
@testable import ModelHub

@Suite("KeychainStoreTests")
struct KeychainStoreTests {
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
