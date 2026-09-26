import Foundation
import ModelHubShared
import Security

final class IOSDeviceIdentity: NSObject, MobileDeviceSigner {
    private let deviceIDKey = "modelhub.mobile.approved-device-id"
    private let keyTag = Data("com.local.modelhub.mobile.device-signing.v1".utf8)

    var deviceId: String {
        UserDefaults.standard.string(forKey: deviceIDKey)
            ?? "00000000-0000-4000-8000-000000000000"
    }

    var isPaired: Bool { UserDefaults.standard.string(forKey: deviceIDKey) != nil }

    var publicKeyX963Base64: String {
        do {
            let key = try privateKey()
            guard let publicKey = SecKeyCopyPublicKey(key),
                  let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
                  data.count == 65
            else { return "" }
            return data.base64EncodedString()
        } catch {
            return ""
        }
    }

    func sign(data: KotlinByteArray) -> String {
        do {
            let input = data.asData
            let key = try privateKey()
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                key,
                .ecdsaSignatureMessageX962SHA256,
                input as CFData,
                &error
            ) as Data? else {
                throw error?.takeRetainedValue() ?? NSError(domain: NSOSStatusErrorDomain, code: -1)
            }
            return signature.base64EncodedString()
        } catch {
            return ""
        }
    }

    func storeApprovedDevice(id: String) throws {
        guard UUID(uuidString: id) != nil else { throw IdentityError.invalidDeviceID }
        UserDefaults.standard.set(id.lowercased(), forKey: deviceIDKey)
    }

    func forgetDevice() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychain(status)
        }
        UserDefaults.standard.removeObject(forKey: deviceIDKey)
    }

    private func privateKey() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let key = result,
           CFGetTypeID(key) == SecKeyGetTypeID()
        {
            return unsafeDowncast(key as AnyObject, to: SecKey.self)
        }
        guard status == errSecItemNotFound else { throw IdentityError.keychain(status) }

        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            nil
        )
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: access as Any,
            ],
        ]
#if !targetEnvironment(simulator)
        attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
#endif
        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) else {
            throw creationError?.takeRetainedValue() ?? IdentityError.creationFailed
        }
        return key
    }

    enum IdentityError: LocalizedError {
        case invalidDeviceID
        case keychain(OSStatus)
        case creationFailed

        var errorDescription: String? {
            switch self {
            case .invalidDeviceID: "桌面端返回了无效设备 ID"
            case .keychain(let status): "钥匙串操作失败（\(status)）"
            case .creationFailed: "无法生成设备签名密钥"
            }
        }
    }
}

extension KotlinByteArray {
    convenience init(data: Data) {
        self.init(size: Int32(data.count))
        for (index, byte) in data.enumerated() {
            set(index: Int32(index), value: Int8(bitPattern: byte))
        }
    }

    var asData: Data {
        Data((0..<Int(size)).map { UInt8(bitPattern: get(index: Int32($0))) })
    }
}
