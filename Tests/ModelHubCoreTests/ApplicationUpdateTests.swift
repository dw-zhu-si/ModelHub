import Foundation
import XCTest
@testable import ModelHubCore

final class ApplicationUpdateTests: XCTestCase {
    func testVersionComparisonHandlesDifferentComponentCounts() throws {
        XCTAssertLessThan(try XCTUnwrap(ApplicationReleaseVersion("1.9.4")),
                          try XCTUnwrap(ApplicationReleaseVersion("1.10.0")))
        XCTAssertEqual(ApplicationReleaseVersion("v1.9.4+65"),
                       ApplicationReleaseVersion("1.9.4"))
        XCTAssertEqual(ApplicationReleaseVersion("1.9"),
                       ApplicationReleaseVersion("1.9.0"))
        XCTAssertNil(ApplicationReleaseVersion("1.9.beta"))
        XCTAssertNil(ApplicationReleaseVersion("1..9"))
    }

    func testReleaseChannelResolutionPrefersAppStoreReceipt() {
        XCTAssertEqual(
            ApplicationReleaseChannel.resolve(
                explicitValue: "github",
                hasAppStoreReceipt: true,
                isDebugBuild: false
            ),
            .appStore
        )
        XCTAssertEqual(
            ApplicationReleaseChannel.resolve(
                explicitValue: "github",
                hasAppStoreReceipt: false,
                isDebugBuild: false
            ),
            .github
        )
        XCTAssertEqual(
            ApplicationReleaseChannel.resolve(
                explicitValue: "app-store",
                hasAppStoreReceipt: false,
                isDebugBuild: true
            ),
            .local
        )
    }

    func testGitHubReleaseParsingRejectsDraftsAndUntrustedURLs() throws {
        let valid = Data(#"{"tag_name":"v1.9.5","html_url":"https://github.com/dw-zhu-si/ModelHub/releases/tag/v1.9.5","draft":false,"prerelease":false}"#.utf8)
        XCTAssertEqual(
            try ApplicationUpdatePolicy.parseRelease(data: valid, channel: .github),
            ApplicationUpdateRelease(
                version: "1.9.5",
                pageURL: URL(string: "https://github.com/dw-zhu-si/ModelHub/releases/tag/v1.9.5")!
            )
        )

        let draft = Data(#"{"tag_name":"v1.9.5","html_url":"https://github.com/dw-zhu-si/ModelHub/releases/tag/v1.9.5","draft":true,"prerelease":false}"#.utf8)
        XCTAssertThrowsError(
            try ApplicationUpdatePolicy.parseRelease(data: draft, channel: .github)
        )

        let untrusted = Data(#"{"tag_name":"v1.9.5","html_url":"https://example.com/ModelHub-1.9.5.dmg","draft":false,"prerelease":false}"#.utf8)
        XCTAssertThrowsError(
            try ApplicationUpdatePolicy.parseRelease(data: untrusted, channel: .github)
        ) { error in
            XCTAssertEqual(error as? ApplicationUpdateError, .unsafeReleaseURL)
        }
    }

    func testAppStoreReleaseRequiresExactAppIdentityAndTrustedPage() throws {
        let valid = Data(#"{"results":[{"trackId":6797847364,"bundleId":"com.local.modelhub","version":"1.9.5","trackViewUrl":"https://apps.apple.com/cn/app/modelhub/id6797847364"}]}"#.utf8)
        XCTAssertEqual(
            try ApplicationUpdatePolicy.parseRelease(data: valid, channel: .appStore),
            ApplicationUpdateRelease(
                version: "1.9.5",
                pageURL: URL(string: "https://apps.apple.com/cn/app/modelhub/id6797847364")!
            )
        )

        let wrongBundle = Data(#"{"results":[{"trackId":6797847364,"bundleId":"com.example.fake","version":"99.0","trackViewUrl":"https://apps.apple.com/cn/app/fake/id6797847364"}]}"#.utf8)
        XCTAssertThrowsError(
            try ApplicationUpdatePolicy.parseRelease(data: wrongBundle, channel: .appStore)
        )
    }

    func testResponseValidationBoundsSizeStatusAndFinalHost() throws {
        let url = try XCTUnwrap(
            URL(string: "https://api.github.com/repos/dw-zhu-si/ModelHub/releases/latest")
        )
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        XCTAssertNoThrow(try ApplicationUpdatePolicy.validateResponse(
            response,
            data: Data("{}".utf8),
            channel: .github
        ))
        XCTAssertThrowsError(try ApplicationUpdatePolicy.validateResponse(
            response,
            data: Data(count: ApplicationUpdatePolicy.maximumResponseBytes + 1),
            channel: .github
        )) { error in
            XCTAssertEqual(error as? ApplicationUpdateError, .responseTooLarge)
        }

        let redirected = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/releases/latest")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        XCTAssertThrowsError(try ApplicationUpdatePolicy.validateResponse(
            redirected,
            data: Data("{}".utf8),
            channel: .github
        ))
    }
}
