import XCTest
@testable import ModelHub

final class LocalizationTests: XCTestCase {
    func testSupportedLanguageMatrixContainsSimplifiedTraditionalAndNineAdditionalLanguages() {
        XCTAssertEqual(
            Set(AppLanguage.allCases.map(\.rawValue)),
            Set([
                "system",
                "zh-Hans",
                "zh-Hant",
                "en",
                "ja",
                "ko",
                "es",
                "fr",
                "de",
                "pt-BR",
                "ru",
                "ar",
            ])
        )
        XCTAssertEqual(AppLanguage.allCases.count - 1, 11)
    }

    func testEveryLanguageHasANativeDisplayNameAndLocale() {
        for language in AppLanguage.allCases {
            XCTAssertFalse(language.nativeName.isEmpty)
            XCTAssertFalse(language.locale.identifier.isEmpty)
        }
    }
}
