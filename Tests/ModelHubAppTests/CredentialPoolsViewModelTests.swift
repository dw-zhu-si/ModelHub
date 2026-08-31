import Foundation
import ModelHubCore
import Testing
@testable import ModelHub

@Suite("CredentialPoolsViewModelTests")
struct CredentialPoolsViewModelTests {
    @Test("卡片始终显示消费者订阅与配额轮换禁令")
    func complianceMessagesAreExplicit() {
        #expect(
            CredentialPoolsViewPolicy.consumerSubscriptionNotice ==
                "消费者订阅不能进入自动池，个人自用也不例外。"
        )
        #expect(CredentialPoolsViewPolicy.quotaNotice.contains("429"))
        #expect(CredentialPoolsViewPolicy.quotaNotice.contains("绝不换号"))
    }

    @Test("池模式仅允许手动选择与撤销失效后故障转移")
    func onlyCompliantPoolModesArePresented() {
        #expect(CredentialPoolsViewPolicy.allowedModes == [.manualOnly, .failoverOnly])
    }

    @Test("仅 Gemini 开发者 OAuth 可发起，其他供应商失败关闭")
    func oauthAvailabilityUsesAnExplicitAllowlist() {
        #expect(CredentialPoolsViewPolicy.oauthAvailability(for: .gemini) == .available)

        let unavailable = CredentialPoolsViewPolicy.oauthAvailability(for: .anthropic)
        #expect(!unavailable.isEnabled)
        #expect(unavailable.reason?.contains("未核实") == true)
    }

    @Test("新增条目只能创建开发者 API Key 元数据且不接收秘密")
    func apiKeyFactoryCreatesDeveloperMetadataOnly() throws {
        let providerID = UUID()
        let entry = CredentialPoolsViewPolicy.makeDeveloperAPIKeyEntry(
            providerID: providerID,
            label: String(repeating: "A", count: 140),
            priority: -8,
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 123)
        )

        #expect(entry.providerID == providerID)
        #expect(entry.secretKind == .apiKey)
        #expect(entry.intendedUse == .developerAPI)
        #expect(entry.oauth == nil)
        #expect(entry.priority == 0)
        #expect(entry.label.count == 120)

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
                as? [String: Any]
        )
        #expect(object["secret"] == nil)
        #expect(object["token"] == nil)
        #expect(object["accessToken"] == nil)
        #expect(object["refreshToken"] == nil)
    }

    @Test("Gemini 授权入口只生成官方端点、范围与待重新授权元数据")
    func geminiOAuthFactoryUsesOfficialMetadata() throws {
        let providerID = UUID()
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = CredentialPoolsViewPolicy.makeGeminiDeveloperOAuthEntry(
            providerID: providerID,
            clientID: "desktop-client.apps.googleusercontent.com",
            billingProjectID: "modelhub-project",
            priority: 7,
            reviewedAt: reviewedAt
        )

        #expect(entry.providerID == providerID)
        #expect(entry.secretKind == .oauthRefreshToken)
        #expect(entry.intendedUse == .developerAPI)
        #expect(entry.requiresReauthorization)
        #expect(entry.oauth?.authorizationEndpoint.absoluteString ==
                "https://accounts.google.com/o/oauth2/v2/auth")
        #expect(entry.oauth?.tokenEndpoint.absoluteString ==
                "https://oauth2.googleapis.com/token")
        #expect(entry.oauth?.redirectURI.absoluteString ==
                "http://127.0.0.1:11469/oauth/callback")
        #expect(entry.oauth?.scopes ==
                ["https://www.googleapis.com/auth/cloud-platform"])
        #expect(entry.oauth?.validationError(asOf: reviewedAt) == nil)
    }

    @Test("供应商卡片保留启用优先级类型用途和手动选中状态")
    func providerCardStateProjectsNonSecretMetadata() throws {
        let provider = ProviderConfig(
            id: UUID(),
            name: "Google Gemini",
            kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com"
        )
        let selectedID = UUID()
        let selected = CredentialPoolEntry(
            id: selectedID,
            providerID: provider.id,
            label: "主要开发 Key",
            secretKind: .apiKey,
            intendedUse: .developerAPI,
            enabled: true,
            priority: 20
        )
        let preferred = CredentialPoolEntry(
            providerID: provider.id,
            label: "优先开发 Key",
            secretKind: .apiKey,
            intendedUse: .developerAPI,
            enabled: false,
            priority: 5
        )
        let pool = CredentialPoolConfiguration(
            providerID: provider.id,
            mode: .manualOnly,
            entries: [selected, preferred],
            manuallySelectedCredentialID: selectedID
        )

        let card = try #require(
            CredentialPoolsViewPolicy.cardStates(
                providers: [provider],
                pools: [pool]
            ).first
        )

        #expect(card.providerID == provider.id)
        #expect(card.providerName == "Google Gemini")
        #expect(card.providerKind == .gemini)
        #expect(card.mode == .manualOnly)
        #expect(card.entries.map(\.priority) == [5, 20])
        #expect(card.entries.first?.enabled == false)
        #expect(card.entries.first?.secretKind == .apiKey)
        #expect(card.entries.first?.intendedUse == .developerAPI)
        #expect(card.entries.last?.isManuallySelected == true)
    }

    @Test("消费者订阅条目标记为禁止自动化，即使是个人自用")
    func consumerEntryIsMarkedAsAutomationBlocked() throws {
        let provider = ProviderConfig(
            name: "Anthropic",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com"
        )
        let consumer = CredentialPoolEntry(
            providerID: provider.id,
            label: "个人订阅",
            secretKind: .oauthRefreshToken,
            intendedUse: .consumerSubscription
        )

        let card = try #require(
            CredentialPoolsViewPolicy.cardStates(
                providers: [provider],
                pools: [CredentialPoolConfiguration(
                    providerID: provider.id,
                    mode: .failoverOnly,
                    entries: [consumer]
                )]
            ).first
        )
        let entry = try #require(card.entries.first)

        #expect(entry.isAutomationBlocked)
        #expect(entry.automationStatusText == CredentialPoolsViewPolicy.consumerSubscriptionNotice)
    }

    @Test("没有已保存池时供应商以空手动池安全呈现")
    func missingPoolDefaultsToEmptyManualMode() throws {
        let provider = ProviderConfig(
            name: "Local",
            kind: .ollama,
            baseURL: "http://127.0.0.1:11434"
        )

        let card = try #require(
            CredentialPoolsViewPolicy.cardStates(providers: [provider], pools: []).first
        )

        #expect(card.mode == .manualOnly)
        #expect(card.entries.isEmpty)
        #expect(card.manuallySelectedCredentialID == nil)
    }
}
