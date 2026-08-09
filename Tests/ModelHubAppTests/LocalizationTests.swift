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

    func testEveryCatalogEntryHasElevenNonEmptyTranslationsAndMatchingPlaceholders() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appending(path: "packaging/Localization/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let languages = [
            "zh-Hans", "zh-Hant", "en", "ja", "ko", "es", "fr", "de",
            "pt-BR", "ru", "ar",
        ]

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any], key
            )
            let expectedPlaceholderCount = placeholderCount(in: key)
            for language in languages {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any], "\(key) [\(language)]"
                )
                let unit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any], "\(key) [\(language)]"
                )
                let value = try XCTUnwrap(
                    unit["value"] as? String, "\(key) [\(language)]"
                )
                XCTAssertFalse(value.isEmpty, "\(key) [\(language)]")
                XCTAssertEqual(
                    placeholderCount(in: value),
                    expectedPlaceholderCount,
                    "\(key) [\(language)]"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(strings.count, 602)
    }

    private func placeholderCount(in value: String) -> Int {
        let expression = try! NSRegularExpression(
            pattern: #"%(?:[0-9]+\$)?(?:arg|@|lld|ld|d|f)"#
        )
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.numberOfMatches(in: value, range: range)
    }
}
