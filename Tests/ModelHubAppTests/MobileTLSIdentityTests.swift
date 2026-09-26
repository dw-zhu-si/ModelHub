import CryptoKit
import Security
import XCTest
@testable import ModelHub

final class MobileTLSIdentityTests: XCTestCase {
    func testGeneratedIdentityUsesMatchingP256KeyAndStableFingerprint() throws {
        let key = try MobileTLSCertificateFactory.makeEphemeralPrivateKey()
        let material = try MobileTLSCertificateFactory.makeIdentity(
            privateKey: key,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            validityDays: 365
        )

        XCTAssertEqual(material.fingerprint.count, 64)
        XCTAssertTrue(material.fingerprint.allSatisfy(\.isHexDigit))
        XCTAssertFalse(material.certificateData.isEmpty)
        XCTAssertNotNil(SecIdentityCreate(nil, material.certificate, key))
        XCTAssertEqual(
            material.fingerprint,
            SHA256.hash(data: material.certificateData)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    func testDERLengthEncodingHandlesCertificateSizedPayloads() {
        XCTAssertEqual(MobileDER.length(127), Data([0x7f]))
        XCTAssertEqual(MobileDER.length(128), Data([0x81, 0x80]))
        XCTAssertEqual(MobileDER.length(512), Data([0x82, 0x02, 0x00]))
    }
}
