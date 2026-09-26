import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum MobileTLSIdentityError: LocalizedError {
    case keyGenerationFailed(String)
    case publicKeyUnavailable
    case certificateSigningFailed(String)
    case certificateCreationFailed
    case identityCreationFailed
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let message): "无法生成移动访问 TLS 密钥：\(message)"
        case .publicKeyUnavailable: "无法读取移动访问 TLS 公钥"
        case .certificateSigningFailed(let message): "无法签发移动访问 TLS 证书：\(message)"
        case .certificateCreationFailed: "无法解析移动访问 TLS 证书"
        case .identityCreationFailed: "TLS 证书与私钥不匹配"
        case .keychainFailure(let status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "移动访问钥匙串操作失败（\(status)）"
        }
    }
}

struct MobileTLSIdentityMaterial {
    let identity: SecIdentity
    let certificate: SecCertificate
    let certificateData: Data
    let fingerprint: String
}

enum MobileDER {
    static func length(_ value: Int) -> Data {
        precondition(value >= 0)
        if value < 128 { return Data([UInt8(value)]) }
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func wrap(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    static func sequence(_ values: Data...) -> Data { sequence(values) }
    static func sequence(_ values: [Data]) -> Data { wrap(0x30, values.reduce(Data(), +)) }
    static func set(_ values: Data...) -> Data { wrap(0x31, values.reduce(Data(), +)) }
    static func integer(_ bytes: Data) -> Data {
        var normalized = bytes.drop(while: { $0 == 0 })
        if normalized.isEmpty { normalized = Data.SubSequence([0]) }
        var value = Data(normalized)
        if value.first.map({ $0 & 0x80 != 0 }) == true { value.insert(0, at: 0) }
        return wrap(0x02, value)
    }
    static func integer(_ value: UInt8) -> Data { integer(Data([value])) }
    static func boolean(_ value: Bool) -> Data { wrap(0x01, Data([value ? 0xff : 0x00])) }
    static func utf8(_ value: String) -> Data { wrap(0x0c, Data(value.utf8)) }
    static func octetString(_ value: Data) -> Data { wrap(0x04, value) }
    static func bitString(_ value: Data, unusedBits: UInt8 = 0) -> Data {
        wrap(0x03, Data([unusedBits]) + value)
    }
    static func generalizedTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return wrap(0x18, Data(formatter.string(from: date).utf8))
    }
    static func context(_ number: UInt8, _ content: Data) -> Data {
        precondition(number < 31)
        return wrap(0xa0 | number, content)
    }

    static func objectIdentifier(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2)
        precondition(components[0] <= 2)
        precondition(components[0] == 2 || components[1] < 40)
        var bytes = base128(components[0] * 40 + components[1])
        for component in components.dropFirst(2) { bytes += base128(component) }
        return wrap(0x06, Data(bytes))
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        if value == 0 { return [0] }
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0x7f), at: 0)
            remaining >>= 7
        }
        for index in bytes.indices.dropLast() { bytes[index] |= 0x80 }
        return bytes
    }
}

enum MobileTLSCertificateFactory {
    static func makeEphemeralPrivateKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MobileTLSIdentityError.keyGenerationFailed(
                error?.takeRetainedValue().localizedDescription ?? "unknown error"
            )
        }
        return key
    }

    static func makeIdentity(
        privateKey: SecKey,
        now: Date = .now,
        validityDays: Int = 3_650
    ) throws -> MobileTLSIdentityMaterial {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              publicKeyData.count == 65
        else { throw MobileTLSIdentityError.publicKeyUnavailable }

        let signatureAlgorithm = MobileDER.sequence(
            MobileDER.objectIdentifier([1, 2, 840, 10045, 4, 3, 2])
        )
        let commonName = MobileDER.sequence(
            MobileDER.objectIdentifier([2, 5, 4, 3]),
            MobileDER.utf8("ModelHub Mobile Access")
        )
        let name = MobileDER.sequence(MobileDER.set(commonName))
        let validity = MobileDER.sequence(
            MobileDER.generalizedTime(now.addingTimeInterval(-3_600)),
            MobileDER.generalizedTime(
                now.addingTimeInterval(TimeInterval(max(1, validityDays)) * 86_400)
            )
        )
        let publicKeyAlgorithm = MobileDER.sequence(
            MobileDER.objectIdentifier([1, 2, 840, 10045, 2, 1]),
            MobileDER.objectIdentifier([1, 2, 840, 10045, 3, 1, 7])
        )
        let subjectPublicKeyInfo = MobileDER.sequence(
            publicKeyAlgorithm,
            MobileDER.bitString(publicKeyData)
        )
        let basicConstraints = MobileDER.sequence(
            MobileDER.objectIdentifier([2, 5, 29, 19]),
            MobileDER.boolean(true),
            MobileDER.octetString(MobileDER.sequence([]))
        )
        let keyUsage = MobileDER.sequence(
            MobileDER.objectIdentifier([2, 5, 29, 15]),
            MobileDER.boolean(true),
            MobileDER.octetString(MobileDER.bitString(Data([0x80]), unusedBits: 7))
        )
        let extendedKeyUsage = MobileDER.sequence(
            MobileDER.objectIdentifier([2, 5, 29, 37]),
            MobileDER.octetString(MobileDER.sequence(
                MobileDER.objectIdentifier([1, 3, 6, 1, 5, 5, 7, 3, 1])
            ))
        )
        var serialBytes = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        serialBytes[serialBytes.startIndex] &= 0x7f
        let toBeSigned = MobileDER.sequence(
            MobileDER.context(0, MobileDER.integer(2)),
            MobileDER.integer(serialBytes),
            signatureAlgorithm,
            name,
            validity,
            name,
            subjectPublicKeyInfo,
            MobileDER.context(3, MobileDER.sequence(
                basicConstraints,
                keyUsage,
                extendedKeyUsage
            ))
        )

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            toBeSigned as CFData,
            &signingError
        ) as Data? else {
            throw MobileTLSIdentityError.certificateSigningFailed(
                signingError?.takeRetainedValue().localizedDescription ?? "unknown error"
            )
        }
        let certificateData = MobileDER.sequence(
            toBeSigned,
            signatureAlgorithm,
            MobileDER.bitString(signature)
        )
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw MobileTLSIdentityError.certificateCreationFailed
        }
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw MobileTLSIdentityError.identityCreationFailed
        }
        let fingerprint = SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()
        return MobileTLSIdentityMaterial(
            identity: identity,
            certificate: certificate,
            certificateData: certificateData,
            fingerprint: fingerprint
        )
    }
}

enum MobileTLSIdentityStore {
    private static let privateKeyTag = Data("com.local.modelhub.mobile-access.tls-key.v1".utf8)
    private static let certificateAccount = "mobile.access.tls.certificate.v1"

    static func loadOrCreate(now: Date = .now) throws -> MobileTLSIdentityMaterial {
        let privateKey = try loadPrivateKey() ?? createPermanentPrivateKey()
        if let encodedCertificate = KeychainStore.read(account: certificateAccount),
           let certificateData = Data(base64Encoded: encodedCertificate),
           let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
           let identity = SecIdentityCreate(nil, certificate, privateKey)
        {
            return MobileTLSIdentityMaterial(
                identity: identity,
                certificate: certificate,
                certificateData: certificateData,
                fingerprint: SHA256.hash(data: certificateData)
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        }

        let material = try MobileTLSCertificateFactory.makeIdentity(
            privateKey: privateKey,
            now: now
        )
        try KeychainStore.save(
            material.certificateData.base64EncodedString(),
            account: certificateAccount
        )
        return material
    }

    private static func loadPrivateKey() throws -> SecKey? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let key = result,
              CFGetTypeID(key) == SecKeyGetTypeID()
        else {
            throw MobileTLSIdentityError.keychainFailure(status)
        }
        return unsafeDowncast(key as AnyObject, to: SecKey.self)
    }

    private static func createPermanentPrivateKey() throws -> SecKey {
        let privateKeyAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: privateKeyTag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateKeyAttributes
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MobileTLSIdentityError.keyGenerationFailed(
                error?.takeRetainedValue().localizedDescription ?? "unknown error"
            )
        }
        return key
    }
}
