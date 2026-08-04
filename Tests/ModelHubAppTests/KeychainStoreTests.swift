import Foundation
import Testing
@testable import ModelHub

@Suite("KeychainStoreTests")
struct KeychainStoreTests {
    @Test("后台查询缺失项目时不请求交互")
    func missingItemLookupIsNonInteractive() {
        let account = "tests.missing.\(UUID().uuidString)"

        #expect(KeychainStore.readWithoutInteraction(account: account) == .notFound)
        #expect(!KeychainStore.existsWithoutInteraction(account: account))
    }
}
