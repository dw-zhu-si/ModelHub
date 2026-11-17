import Foundation
import ModelHubCore
import XCTest
@testable import ModelHub

@MainActor
final class ProviderCatalogRefreshNoticeTests: XCTestCase {
    nonisolated(unsafe) private var previousLanguageRawValue: String?

    override func setUp() {
        super.setUp()
        previousLanguageRawValue = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
        AppLanguage.simplifiedChinese.save()
    }

    override func tearDown() {
        if let previousLanguageRawValue {
            UserDefaults.standard.set(previousLanguageRawValue, forKey: AppLanguage.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        }
        super.tearDown()
    }

    func testTransientFailureKeepsSavedCatalogAvailable() {
        let notice = AppModel.providerCatalogRefreshFailureNotice(
            savedModelCount: 64,
            error: ProviderModelCatalogError.timedOut
        )

        XCTAssertTrue(notice.contains("继续使用本地已保存的 64 个模型"))
        XCTAssertTrue(notice.contains("现有目录和检测状态未修改"))
        XCTAssertFalse(notice.contains("模型热更新失败"))
    }

    func testTransientFailureWithoutSavedCatalogRemainsBlocking() {
        let notice = AppModel.providerCatalogRefreshFailureNotice(
            savedModelCount: 0,
            error: ProviderModelCatalogError.timedOut
        )

        XCTAssertTrue(notice.contains("模型热更新失败"))
        XCTAssertFalse(notice.contains("继续使用本地已保存"))
    }

    func testSecurityFailureIsNotDowngradedToLocalFallback() {
        let notice = AppModel.providerCatalogRefreshFailureNotice(
            savedModelCount: 64,
            error: ProviderModelCatalogError.secureConnectionFailed
        )

        XCTAssertTrue(notice.contains("模型热更新失败"))
        XCTAssertFalse(notice.contains("继续使用本地已保存"))
    }
}
