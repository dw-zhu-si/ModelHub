import Foundation

/// Only non-secret metadata is persisted in the application configuration.
/// The corresponding secret is stored under the entry UUID in the macOS Keychain.
public enum CredentialSecretKind: String, Codable, CaseIterable, Sendable {
    case apiKey
    case oauthRefreshToken
    case workloadIdentity
}

public enum CredentialIntendedUse: String, Codable, CaseIterable, Sendable {
    case developerAPI
    case consumerSubscription
}

public enum CredentialPoolMode: String, Codable, CaseIterable, Sendable {
    case manualOnly
    case failoverOnly
}

public enum OAuthPKCECodeChallengeMethod: String, Codable, CaseIterable, Sendable {
    case s256 = "S256"
    case plain
}

/// Reviewable, non-secret evidence that a provider documents this OAuth use.
/// It expires deliberately so an old policy decision cannot authorize pooling
/// indefinitely after provider terms or supported scopes change.
public struct OAuthAuthorizationEvidence: Codable, Hashable, Sendable {
    public var officialDocumentationURL: URL
    public var reviewedAt: Date
    public var expiresAt: Date
    public var approvedScopes: [String]

    public init(
        officialDocumentationURL: URL,
        reviewedAt: Date,
        expiresAt: Date,
        approvedScopes: [String]
    ) {
        self.officialDocumentationURL = officialDocumentationURL
        self.reviewedAt = reviewedAt
        self.expiresAt = expiresAt
        self.approvedScopes = Array(approvedScopes.prefix(32))
    }
}

/// Public-client OAuth metadata only. Authorization codes, access tokens,
/// refresh tokens, PKCE verifiers, state values and nonces never belong here.
public struct OAuthPKCEConfiguration: Codable, Hashable, Sendable {
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var clientID: String
    /// Google Cloud project charged/attributed for developer API calls.
    /// This is project metadata, not a consumer subscription account.
    public var billingProjectID: String?
    public var redirectURI: URL
    public var scopes: [String]
    public var codeChallengeMethod: OAuthPKCECodeChallengeMethod
    public var requiresState: Bool
    public var requiresNonce: Bool
    public var evidence: OAuthAuthorizationEvidence

    public init(
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        clientID: String,
        billingProjectID: String? = nil,
        redirectURI: URL,
        scopes: [String],
        codeChallengeMethod: OAuthPKCECodeChallengeMethod = .s256,
        requiresState: Bool = true,
        requiresNonce: Bool = true,
        evidence: OAuthAuthorizationEvidence
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = String(clientID.prefix(512))
        self.billingProjectID = billingProjectID.map { String($0.prefix(128)) }
        self.redirectURI = redirectURI
        self.scopes = Array(scopes.prefix(32))
        self.codeChallengeMethod = codeChallengeMethod
        self.requiresState = requiresState
        self.requiresNonce = requiresNonce
        self.evidence = evidence
    }

    public func validationError(asOf date: Date = .now) -> OAuthPKCEValidationError? {
        guard Self.isSecureEndpoint(authorizationEndpoint) else {
            return .insecureAuthorizationEndpoint
        }
        guard Self.isSecureEndpoint(tokenEndpoint) else {
            return .insecureTokenEndpoint
        }
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .clientIDRequired
        }
        if let billingProjectID {
            let normalized = billingProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return .billingProjectIDRequired }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
            guard normalized.unicodeScalars.allSatisfy(allowed.contains),
                  normalized.first?.isLetter == true,
                  normalized.last?.isLetter == true || normalized.last?.isNumber == true
            else { return .billingProjectIDInvalid }
        }
        guard redirectURI.scheme?.isEmpty == false else {
            return .redirectURIRequired
        }
        guard Self.isLoopbackCallback(redirectURI) else {
            return .loopbackRedirectRequired
        }
        guard codeChallengeMethod == .s256 else { return .pkceS256Required }
        guard requiresState else { return .stateRequired }
        guard requiresNonce else { return .nonceRequired }

        let normalizedScopes = scopes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalizedScopes.isEmpty,
              normalizedScopes.allSatisfy({ !$0.isEmpty })
        else { return .scopeRequired }
        guard Set(normalizedScopes).count == normalizedScopes.count else {
            return .duplicateScope
        }

        let approvedScopes = Set(evidence.approvedScopes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        for scope in normalizedScopes where !approvedScopes.contains(scope) {
            return .scopeNotApproved(scope)
        }

        guard Self.isSecureEndpoint(evidence.officialDocumentationURL) else {
            return .insecureEvidenceURL
        }
        guard evidence.reviewedAt <= date else { return .evidenceReviewInFuture }
        guard evidence.expiresAt > evidence.reviewedAt else {
            return .invalidEvidenceWindow
        }
        guard evidence.expiresAt > date else { return .evidenceExpired }
        return nil
    }

    private static func isSecureEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
    }

    private static func isLoopbackCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              url.host?.lowercased() == "127.0.0.1",
              url.port == 11_469,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path == "/oauth/callback"
        else { return false }
        return true
    }
}

public enum OAuthPKCEValidationError: Equatable, Sendable {
    case insecureAuthorizationEndpoint
    case insecureTokenEndpoint
    case clientIDRequired
    case billingProjectIDRequired
    case billingProjectIDInvalid
    case redirectURIRequired
    case loopbackRedirectRequired
    case pkceS256Required
    case stateRequired
    case nonceRequired
    case scopeRequired
    case duplicateScope
    case scopeNotApproved(String)
    case insecureEvidenceURL
    case evidenceReviewInFuture
    case invalidEvidenceWindow
    case evidenceExpired
}

public struct CredentialPoolEntry: Codable, Hashable, Identifiable, Sendable {
    public static let maximumPriority = 999

    public var id: UUID
    public var providerID: UUID
    public var label: String
    public var secretKind: CredentialSecretKind
    public var intendedUse: CredentialIntendedUse
    public var enabled: Bool
    public var priority: Int
    public var createdAt: Date
    public var oauth: OAuthPKCEConfiguration?
    /// True after importing metadata or decoding an older unbound secret format.
    /// The credential remains unavailable until the user explicitly stores a
    /// newly endpoint-bound secret.
    public var requiresReauthorization: Bool

    public init(
        id: UUID = UUID(),
        providerID: UUID,
        label: String,
        secretKind: CredentialSecretKind,
        intendedUse: CredentialIntendedUse,
        enabled: Bool = true,
        priority: Int = 0,
        createdAt: Date = .now,
        oauth: OAuthPKCEConfiguration? = nil,
        requiresReauthorization: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.label = String(label.prefix(120))
        self.secretKind = secretKind
        self.intendedUse = intendedUse
        self.enabled = enabled
        self.priority = min(max(0, priority), Self.maximumPriority)
        self.createdAt = createdAt
        self.oauth = oauth
        self.requiresReauthorization = requiresReauthorization
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, label, secretKind, intendedUse, enabled, priority,
             createdAt, oauth, requiresReauthorization
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        guard (0...Self.maximumPriority).contains(priority) else {
            throw DecodingError.dataCorruptedError(
                forKey: .priority,
                in: container,
                debugDescription: "Credential priority is outside the supported range"
            )
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            providerID: try container.decode(UUID.self, forKey: .providerID),
            label: try container.decode(String.self, forKey: .label),
            secretKind: try container.decode(CredentialSecretKind.self, forKey: .secretKind),
            intendedUse: try container.decode(CredentialIntendedUse.self, forKey: .intendedUse),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            priority: priority,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now,
            oauth: try container.decodeIfPresent(OAuthPKCEConfiguration.self, forKey: .oauth),
            requiresReauthorization: try container.decodeIfPresent(
                Bool.self,
                forKey: .requiresReauthorization
            ) ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(label, forKey: .label)
        try container.encode(secretKind, forKey: .secretKind)
        try container.encode(intendedUse, forKey: .intendedUse)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(priority, forKey: .priority)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(oauth, forKey: .oauth)
        try container.encode(requiresReauthorization, forKey: .requiresReauthorization)
    }
}

public struct CredentialPoolConfiguration: Codable, Hashable, Identifiable, Sendable {
    public static let maximumEntries = 32

    public var providerID: UUID
    public var mode: CredentialPoolMode
    public var entries: [CredentialPoolEntry]
    public var manuallySelectedCredentialID: UUID?

    public var id: UUID { providerID }

    public init(
        providerID: UUID,
        mode: CredentialPoolMode = .manualOnly,
        entries: [CredentialPoolEntry] = [],
        manuallySelectedCredentialID: UUID? = nil
    ) {
        self.providerID = providerID
        self.mode = mode
        self.entries = entries
        self.manuallySelectedCredentialID = manuallySelectedCredentialID
    }

    private enum CodingKeys: String, CodingKey {
        case providerID, mode, entries, manuallySelectedCredentialID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerID: try container.decode(UUID.self, forKey: .providerID),
            mode: try container.decodeIfPresent(CredentialPoolMode.self, forKey: .mode)
                ?? .manualOnly,
            entries: try container.decodeIfPresent(
                [CredentialPoolEntry].self,
                forKey: .entries
            ) ?? [],
            manuallySelectedCredentialID: try container.decodeIfPresent(
                UUID.self,
                forKey: .manuallySelectedCredentialID
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(mode, forKey: .mode)
        try container.encode(entries, forKey: .entries)
        try container.encodeIfPresent(
            manuallySelectedCredentialID,
            forKey: .manuallySelectedCredentialID
        )
    }
}

public enum CredentialPoolValidationError: Error, Equatable, Sendable {
    case duplicateProviderID(UUID)
    case unknownProviderID(UUID)
    case tooManyEntries(providerID: UUID, count: Int)
    case entryProviderMismatch(credentialID: UUID)
    case duplicateCredentialID(UUID)
    case invalidManualSelection(providerID: UUID)
    case enabledConsumerSubscription(credentialID: UUID)
}

public enum CredentialPoolValidator {
    public static func validate(
        _ pools: [CredentialPoolConfiguration],
        providers: [ProviderConfig]
    ) throws {
        let providerIDs = Set(providers.map(\.id))
        guard providerIDs.count == providers.count else {
            let duplicate = providers.map(\.id).first { id in
                providers.lazy.filter { $0.id == id }.dropFirst().first != nil
            } ?? UUID()
            throw CredentialPoolValidationError.duplicateProviderID(duplicate)
        }

        var seenPoolProviders: Set<UUID> = []
        var seenCredentialIDs: Set<UUID> = []
        for pool in pools {
            guard seenPoolProviders.insert(pool.providerID).inserted else {
                throw CredentialPoolValidationError.duplicateProviderID(pool.providerID)
            }
            guard providerIDs.contains(pool.providerID) else {
                throw CredentialPoolValidationError.unknownProviderID(pool.providerID)
            }
            guard pool.entries.count <= CredentialPoolConfiguration.maximumEntries else {
                throw CredentialPoolValidationError.tooManyEntries(
                    providerID: pool.providerID,
                    count: pool.entries.count
                )
            }
            for entry in pool.entries {
                guard entry.providerID == pool.providerID else {
                    throw CredentialPoolValidationError.entryProviderMismatch(
                        credentialID: entry.id
                    )
                }
                guard seenCredentialIDs.insert(entry.id).inserted else {
                    throw CredentialPoolValidationError.duplicateCredentialID(entry.id)
                }
                if entry.intendedUse == .consumerSubscription, entry.enabled {
                    throw CredentialPoolValidationError.enabledConsumerSubscription(
                        credentialID: entry.id
                    )
                }
            }
            if let selectedID = pool.manuallySelectedCredentialID,
               !pool.entries.contains(where: {
                   $0.id == selectedID
                       && $0.enabled
                       && $0.intendedUse == .developerAPI
               })
            {
                throw CredentialPoolValidationError.invalidManualSelection(
                    providerID: pool.providerID
                )
            }
        }
    }
}

public enum CredentialAutomationBlockReason: String, Codable, Sendable {
    case consumerSubscriptionIsNotDeveloperAPI
    case providerOAuthNotDocumented
    case oauthConfigurationMissing
    case oauthConfigurationInvalid
    case oauthEvidenceExpired
    case oauthEvidenceNotOfficial
    case oauthProviderMetadataNotOfficial
    case credentialDisabled
    case providerMismatch
    case reauthorizationRequired
}

public enum CredentialAutomationDecision: Equatable, Sendable {
    case allowed
    case blocked(CredentialAutomationBlockReason)
}

/// Provider OAuth support is deliberately an allowlist. Google documents OAuth
/// for the Gemini developer API; this does not include Gemini Apps or Gemini CLI
/// subscription credentials.
/// Source: https://ai.google.dev/gemini-api/docs/oauth
public enum CredentialCompliancePolicy {
    public static func authorizationDecision(
        for entry: CredentialPoolEntry,
        providerKind: ProviderKind,
        asOf date: Date = .now
    ) -> CredentialAutomationDecision {
        decision(
            for: entry,
            providerKind: providerKind,
            asOf: date,
            requireAuthorizedSecret: false
        )
    }

    public static func automationDecision(
        for entry: CredentialPoolEntry,
        providerKind: ProviderKind,
        asOf date: Date = .now
    ) -> CredentialAutomationDecision {
        decision(
            for: entry,
            providerKind: providerKind,
            asOf: date,
            requireAuthorizedSecret: true
        )
    }

    private static func decision(
        for entry: CredentialPoolEntry,
        providerKind: ProviderKind,
        asOf date: Date,
        requireAuthorizedSecret: Bool
    ) -> CredentialAutomationDecision {
        guard entry.enabled else { return .blocked(.credentialDisabled) }
        guard !requireAuthorizedSecret || !entry.requiresReauthorization else {
            return .blocked(.reauthorizationRequired)
        }
        guard entry.intendedUse == .developerAPI else {
            return .blocked(.consumerSubscriptionIsNotDeveloperAPI)
        }
        switch entry.secretKind {
        case .apiKey, .workloadIdentity:
            return .allowed
        case .oauthRefreshToken:
            guard providerKind == .gemini else {
                return .blocked(.providerOAuthNotDocumented)
            }
            guard let oauth = entry.oauth else {
                return .blocked(.oauthConfigurationMissing)
            }
            guard isOfficialEvidence(oauth.evidence, for: providerKind) else {
                return .blocked(.oauthEvidenceNotOfficial)
            }
            guard isOfficialProviderMetadata(oauth, for: providerKind) else {
                return .blocked(.oauthProviderMetadataNotOfficial)
            }
            switch oauth.validationError(asOf: date) {
            case nil:
                return .allowed
            case .evidenceExpired:
                return .blocked(.oauthEvidenceExpired)
            default:
                return .blocked(.oauthConfigurationInvalid)
            }
        }
    }

    private static func isOfficialEvidence(
        _ evidence: OAuthAuthorizationEvidence,
        for providerKind: ProviderKind
    ) -> Bool {
        guard evidence.officialDocumentationURL.scheme?.lowercased() == "https",
              let host = evidence.officialDocumentationURL.host?.lowercased()
        else { return false }
        switch providerKind {
        case .gemini:
            return host == "ai.google.dev"
                && evidence.officialDocumentationURL.path == "/gemini-api/docs/oauth"
        default:
            return false
        }
    }

    private static func isOfficialProviderMetadata(
        _ oauth: OAuthPKCEConfiguration,
        for providerKind: ProviderKind
    ) -> Bool {
        switch providerKind {
        case .gemini:
            let officialScopes: Set<String> = [
                "https://www.googleapis.com/auth/cloud-platform"
            ]
            return oauth.authorizationEndpoint.absoluteString ==
                "https://accounts.google.com/o/oauth2/v2/auth"
                && oauth.tokenEndpoint.absoluteString ==
                    "https://oauth2.googleapis.com/token"
                && oauth.redirectURI.absoluteString ==
                    "http://127.0.0.1:11469/oauth/callback"
                && oauth.billingProjectID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty == false
                && Set(oauth.scopes) == officialScopes
                && Set(oauth.evidence.approvedScopes).isSubset(of: officialScopes)
        default:
            return false
        }
    }
}

public enum CredentialFailureReason: Sendable {
    case revokedOrInvalid
    case quotaOrRateLimited
    case transientTransport
    case upstreamService
}

/// Selects a credential only inside one provider. It never rotates on quota or
/// rate-limit failures, because doing so could combine independent allocations
/// to bypass a provider limit.
public actor CredentialPoolSelector {
    private struct Key: Hashable, Sendable {
        let providerID: UUID
        let credentialID: UUID
    }

    private var unavailable: Set<Key> = []

    public init() {}

    public func select(
        providerKind: ProviderKind,
        configuration: CredentialPoolConfiguration
    ) -> CredentialPoolEntry? {
        let eligible = configuration.entries
            .filter { entry in
                entry.providerID == configuration.providerID
                    && CredentialCompliancePolicy.automationDecision(
                        for: entry,
                        providerKind: providerKind
                    ) == .allowed
            }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }

        if configuration.mode == .manualOnly {
            guard let selectedID = configuration.manuallySelectedCredentialID else {
                return nil
            }
            guard !unavailable.contains(Key(
                providerID: configuration.providerID,
                credentialID: selectedID
            )) else { return nil }
            return eligible.first { $0.id == selectedID }
        }

        return eligible.first {
            !unavailable.contains(Key(
                providerID: configuration.providerID,
                credentialID: $0.id
            ))
        }
    }

    public func recordFailure(
        credentialID: UUID,
        providerID: UUID,
        reason: CredentialFailureReason
    ) {
        guard reason == .revokedOrInvalid else { return }
        unavailable.insert(Key(providerID: providerID, credentialID: credentialID))
    }

    public func recordSuccess(credentialID: UUID, providerID: UUID) {
        unavailable.remove(Key(providerID: providerID, credentialID: credentialID))
    }

    public func reset(providerID: UUID) {
        unavailable = unavailable.filter { $0.providerID != providerID }
    }
}
