import Darwin
import Foundation
import ModelHubMobileAccess
@preconcurrency import Network
import Security

final class MobileAccessService: @unchecked Sendable {
    static let fixedPort: UInt16 = 11_470

    private let server: LocalAPIServer
    let certificateFingerprint: String

    init(router: MobileAccessRouter, identity: MobileTLSIdentityMaterial) {
        certificateFingerprint = identity.fingerprint
        server = LocalAPIServer(
            handler: { request in
                let response = await router.handle(MobileAccessHTTPRequest(
                    method: request.method,
                    path: request.path,
                    headers: request.headers,
                    body: request.body
                ))
                return HTTPResponse(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: response.body
                )
            },
            connectionPolicy: HTTPServerConnectionPolicy(
                maximumActiveConnections: 32,
                idleTimeout: 8,
                absoluteRequestDeadline: 15,
                handlerDeadline: 15,
                streamIdleTimeout: 15,
                maximumStreamDuration: 30
            ),
            maximumBodyBytes: 16 * 1_024,
            maximumHeaderBytes: 32 * 1_024,
            maximumTotalBufferedBytes: 4 * 1_024 * 1_024,
            accessControlAllowOrigin: nil
        )
        tlsIdentity = identity.identity
    }

    private let tlsIdentity: SecIdentity

    func start(
        stateChanged: @escaping @Sendable (Result<UInt16, Error>) -> Void
    ) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        guard let protocolIdentity = sec_identity_create(tlsIdentity) else {
            throw MobileTLSIdentityError.identityCreationFailed
        }
        sec_protocol_options_set_local_identity(
            tls.securityProtocolOptions,
            protocolIdentity
        )
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        try server.start(
            port: Self.fixedPort,
            host: NWEndpoint.Host("0.0.0.0"),
            parameters: parameters,
            stateChanged: stateChanged
        )
    }

    func stop() {
        server.stop()
    }
}

enum MobileAccessNetworkAddress {
    static func preferredIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var candidates: [(priority: Int, address: String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }

            var address = interface.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                &address,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            let value = String(
                decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard !value.hasPrefix("169.254.") else { continue }
            let name = string(from: interface.ifa_name)
            let priority: Int
            if name == "en0" { priority = 0 }
            else if name.hasPrefix("utun") { priority = 1 }
            else { priority = 2 }
            candidates.append((priority, value))
        }
        return candidates.sorted {
            $0.priority == $1.priority
                ? $0.address.localizedStandardCompare($1.address) == .orderedAscending
                : $0.priority < $1.priority
        }.first?.address
    }

    private static func string(from pointer: UnsafePointer<CChar>) -> String {
        var bytes: [UInt8] = []
        var index = 0
        while index < Int(IFNAMSIZ), pointer[index] != 0 {
            bytes.append(UInt8(bitPattern: pointer[index]))
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum MobileDeviceStore {
    static func load(from url: URL = defaultURL) -> [MobilePairedDevice] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= 1_048_576,
              let devices = try? JSONDecoder.mobile.decode([MobilePairedDevice].self, from: data)
        else { return [] }
        return Array(devices.prefix(256))
    }

    static func save(_ devices: [MobilePairedDevice], to url: URL = defaultURL) throws {
        let data = try JSONEncoder.mobile.encode(Array(devices.prefix(256)))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static var defaultURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "ModelHub/mobile-devices.json")
    }
}
