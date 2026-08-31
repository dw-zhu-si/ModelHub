import SwiftUI
import ModelHubCore

enum CredentialPoolOAuthAvailability: Equatable {
    case available
    case unavailable(reason: String)

    var isEnabled: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

struct CredentialPoolEntryCardState: Identifiable, Equatable {
    let entry: CredentialPoolEntry
    let isManuallySelected: Bool
    let isAutomationBlocked: Bool
    let automationStatusText: String?

    var id: UUID { entry.id }
    var label: String { entry.label }
    var enabled: Bool { entry.enabled && !isAutomationBlocked }
    var priority: Int { entry.priority }
    var secretKind: CredentialSecretKind { entry.secretKind }
    var intendedUse: CredentialIntendedUse { entry.intendedUse }
}

struct CredentialPoolProviderCardState: Identifiable, Equatable {
    let providerID: UUID
    let providerName: String
    let providerKind: ProviderKind
    let mode: CredentialPoolMode
    let entries: [CredentialPoolEntryCardState]
    let manuallySelectedCredentialID: UUID?

    var id: UUID { providerID }
}

enum CredentialPoolsViewPolicy {
    static let consumerSubscriptionNotice =
        "消费者订阅不能进入自动池，个人自用也不例外。"
    static let quotaNotice =
        "429 或配额不足时绝不换号；仅当凭证已撤销或失效时，故障转移模式才会尝试下一条合规开发者凭证。"
    static let allowedModes: [CredentialPoolMode] = [.manualOnly, .failoverOnly]

    static func oauthAvailability(
        for providerKind: ProviderKind
    ) -> CredentialPoolOAuthAvailability {
        if providerKind == .gemini {
            return .available
        }
        return .unavailable(reason: "该供应商的开发者 OAuth 官方证据未核实，暂不可用。")
    }

    static func makeDeveloperAPIKeyEntry(
        providerID: UUID,
        label: String,
        priority: Int,
        id: UUID = UUID(),
        createdAt: Date = .now
    ) -> CredentialPoolEntry {
        CredentialPoolEntry(
            id: id,
            providerID: providerID,
            label: label,
            secretKind: .apiKey,
            intendedUse: .developerAPI,
            enabled: true,
            priority: priority,
            createdAt: createdAt
        )
    }

    static func makeGeminiDeveloperOAuthEntry(
        providerID: UUID,
        clientID: String,
        billingProjectID: String,
        priority: Int,
        id: UUID = UUID(),
        reviewedAt: Date = Date(timeIntervalSince1970: 1_788_019_200)
    ) -> CredentialPoolEntry {
        let officialScope = "https://www.googleapis.com/auth/cloud-platform"
        return CredentialPoolEntry(
            id: id,
            providerID: providerID,
            label: "Gemini Developer OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            enabled: true,
            priority: priority,
            createdAt: reviewedAt,
            oauth: OAuthPKCEConfiguration(
                authorizationEndpoint: URL(
                    string: "https://accounts.google.com/o/oauth2/v2/auth"
                )!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                billingProjectID: billingProjectID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                redirectURI: URL(string: "http://127.0.0.1:11469/oauth/callback")!,
                scopes: [officialScope],
                evidence: OAuthAuthorizationEvidence(
                    officialDocumentationURL: URL(
                        string: "https://ai.google.dev/gemini-api/docs/oauth"
                    )!,
                    reviewedAt: reviewedAt,
                    expiresAt: reviewedAt.addingTimeInterval(90 * 86_400),
                    approvedScopes: [officialScope]
                )
            ),
            requiresReauthorization: true
        )
    }

    static func cardStates(
        providers: [ProviderConfig],
        pools: [CredentialPoolConfiguration]
    ) -> [CredentialPoolProviderCardState] {
        let poolByProvider = Dictionary(
            pools.map { ($0.providerID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return providers.map { provider in
            let pool = poolByProvider[provider.id]
                ?? CredentialPoolConfiguration(providerID: provider.id)
            let providerEntries = pool.entries
                .filter { $0.providerID == provider.id }
                .sorted {
                    if $0.priority != $1.priority { return $0.priority < $1.priority }
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            let selectedID = providerEntries.contains {
                $0.id == pool.manuallySelectedCredentialID
            } ? pool.manuallySelectedCredentialID : nil
            let entries = providerEntries.map { entry in
                let consumerBlocked = entry.intendedUse == .consumerSubscription
                let reauthorizationRequired = entry.requiresReauthorization
                return CredentialPoolEntryCardState(
                    entry: entry,
                    isManuallySelected: entry.id == selectedID,
                    isAutomationBlocked: consumerBlocked || reauthorizationRequired,
                    automationStatusText: consumerBlocked
                        ? consumerSubscriptionNotice
                        : (reauthorizationRequired ? "需要完成开发者凭证授权后才能使用。" : nil)
                )
            }
            return CredentialPoolProviderCardState(
                providerID: provider.id,
                providerName: provider.name,
                providerKind: provider.kind,
                mode: pool.mode,
                entries: entries,
                manuallySelectedCredentialID: selectedID
            )
        }
    }
}

/// A presentation-only credential pool editor. It receives non-secret metadata
/// as values and hands transient secrets directly to the injected persistence
/// callback. It never talks to Keychain, OAuth endpoints, or the network.
struct CredentialPoolsView: View {
    @Environment(\.dismiss) private var dismiss

    let providers: [ProviderConfig]
    let pools: [CredentialPoolConfiguration]
    let onAddEntry: (CredentialPoolEntry) -> Void
    let saveSecret: (_ id: UUID, _ value: String) -> Void
    let beginGeminiOAuth: (_ providerID: UUID) -> Void
    let onUpdateEntry: (CredentialPoolEntry) -> Void
    let onDeleteEntry: (_ id: UUID) -> Void
    let onSetMode: (_ providerID: UUID, _ mode: CredentialPoolMode) -> Void
    let onSelectManual: (_ providerID: UUID, _ credentialID: UUID?) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 360, maximum: 560), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开发者凭证池")
                            .font(.title2.weight(.bold))
                        Text("每条秘密独立保存在 macOS 钥匙串中")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint("关闭开发者凭证池")
                }
                complianceBanner

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(cardStates) { card in
                        CredentialPoolProviderCard(
                            state: card,
                            onAddEntry: onAddEntry,
                            saveSecret: saveSecret,
                            beginGeminiOAuth: beginGeminiOAuth,
                            onUpdateEntry: onUpdateEntry,
                            onDeleteEntry: onDeleteEntry,
                            onSetMode: onSetMode,
                            onSelectManual: onSelectManual
                        )
                    }
                }

                if providers.isEmpty {
                    ContentUnavailableView(
                        "尚无供应商",
                        systemImage: "key.horizontal",
                        description: Text("请先添加供应商，再配置开发者凭证。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(MHDesign.pagePadding)
        }
        .mhPageBackground()
    }

    private var cardStates: [CredentialPoolProviderCardState] {
        CredentialPoolsViewPolicy.cardStates(providers: providers, pools: pools)
    }

    private var complianceBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("凭证池合规边界", systemImage: "checkmark.shield")
                .font(.headline)
            Text(CredentialPoolsViewPolicy.consumerSubscriptionNotice)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(CredentialPoolsViewPolicy.quotaNotice)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mhSurface(.secondary, padding: 16)
        .accessibilityElement(children: .combine)
    }
}

private struct CredentialPoolProviderCard: View {
    let state: CredentialPoolProviderCardState
    let onAddEntry: (CredentialPoolEntry) -> Void
    let saveSecret: (_ id: UUID, _ value: String) -> Void
    let beginGeminiOAuth: (_ providerID: UUID) -> Void
    let onUpdateEntry: (CredentialPoolEntry) -> Void
    let onDeleteEntry: (_ id: UUID) -> Void
    let onSetMode: (_ providerID: UUID, _ mode: CredentialPoolMode) -> Void
    let onSelectManual: (_ providerID: UUID, _ credentialID: UUID?) -> Void

    @State private var apiKeyLabel = ""
    @State private var apiKeySecret = ""
    @State private var oauthClientID = ""
    @State private var oauthBillingProjectID = ""
    @State private var oauthFormError: String?
    @State private var pendingDeleteEntry: CredentialPoolEntryCardState?

    private var oauthAvailability: CredentialPoolOAuthAvailability {
        CredentialPoolsViewPolicy.oauthAvailability(for: state.providerKind)
    }

    private var existingOAuthEntry: CredentialPoolEntryCardState? {
        state.entries.first { $0.secretKind == .oauthRefreshToken }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            modePicker
            policySummary

            if state.entries.isEmpty {
                Text("尚未添加开发者凭证")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                VStack(spacing: 10) {
                    ForEach(state.entries) { entry in
                        entryRow(entry)
                    }
                }
            }

            Divider()
            developerAPIKeyForm
            oauthAction
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mhSurface(.elevated, padding: 18)
        .alert(
            "删除开发者凭证？",
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            ),
            presenting: pendingDeleteEntry
        ) { entry in
            Button("删除“\(entry.label)”", role: .destructive) {
                onDeleteEntry(entry.id)
                pendingDeleteEntry = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: { entry in
            Text("这会同时删除“\(entry.label)”在 macOS 钥匙串中的秘密，无法从配置备份恢复。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MHIconTile(symbol: "key.horizontal", size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.providerName)
                    .font(.headline)
                Text(state.providerKind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("\(state.entries.count) 条")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("池模式")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("池模式", selection: Binding(
                get: { state.mode },
                set: { onSetMode(state.providerID, $0) }
            )) {
                ForEach(CredentialPoolsViewPolicy.allowedModes, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("\(state.providerName)凭证池模式")
        }
    }

    private var policySummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                CredentialPoolsViewPolicy.consumerSubscriptionNotice,
                systemImage: "person.crop.circle.badge.xmark"
            )
            Label(
                CredentialPoolsViewPolicy.quotaNotice,
                systemImage: "gauge.with.dots.needle.33percent"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func entryRow(_ item: CredentialPoolEntryCardState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    onSelectManual(state.providerID, item.id)
                } label: {
                    Image(systemName: item.isManuallySelected
                          ? "checkmark.circle.fill"
                          : "circle")
                        .font(.title3)
                        .foregroundStyle(item.isManuallySelected ? MHDesign.accent : .secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(
                    state.mode != .manualOnly || !item.enabled || item.isAutomationBlocked
                )
                .accessibilityLabel(item.isManuallySelected ? "已手动选中" : "手动选择")
                .accessibilityHint(item.isAutomationBlocked
                                   ? CredentialPoolsViewPolicy.consumerSubscriptionNotice
                                   : "将这条凭证设为当前手动使用项")

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        metadataBadge(item.secretKind.displayName, color: .blue)
                        metadataBadge(item.intendedUse.displayName, color: item.isAutomationBlocked ? .orange : .green)
                    }
                }

                Spacer(minLength: 4)

                Toggle("启用", isOn: Binding(
                    get: { item.enabled },
                    set: { enabled in
                        var updated = item.entry
                        updated.enabled = enabled
                        onUpdateEntry(updated)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(item.isAutomationBlocked)
                .accessibilityLabel("启用\(item.label)")

                Button(role: .destructive) {
                    pendingDeleteEntry = item
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除\(item.label)")
            }

            HStack {
                Stepper(
                    "优先级 \(item.priority)",
                    value: Binding(
                        get: { item.priority },
                        set: { priority in
                            var updated = item.entry
                            updated.priority = max(0, priority)
                            onUpdateEntry(updated)
                        }
                    ),
                    in: 0...999
                )
                .font(.caption)

                Spacer()
                if item.isManuallySelected {
                    Label("手动选中", systemImage: "hand.tap")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MHDesign.accent)
                }
            }

            if let status = item.automationStatusText {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(MHDesign.insetSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(MHDesign.border, lineWidth: 1)
        }
    }

    private var developerAPIKeyForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("添加开发者 API Key", systemImage: "plus.circle")
                .font(.subheadline.weight(.semibold))

            TextField("标签（例如：主开发 Key）", text: $apiKeyLabel)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("API Key 标签")

            HStack(spacing: 8) {
                SecureField("开发者 API Key", text: $apiKeySecret)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("开发者 API Key 秘密")

                Button("保存") {
                    submitDeveloperAPIKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint("秘密会立即交给安全存储回调，提交后从输入框清空")
            }

            Text("这里只能新增 Developer API Key；输入值不会进入配置模型或日志。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var oauthAction: some View {
        VStack(alignment: .leading, spacing: 6) {
            if oauthAvailability.isEnabled, existingOAuthEntry == nil {
                TextField("Google Desktop OAuth Client ID", text: $oauthClientID)
                    .textFieldStyle(.roundedBorder)
                TextField("Google Cloud 项目 ID", text: $oauthBillingProjectID)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                submitGeminiOAuth()
            } label: {
                Label(
                    existingOAuthEntry == nil
                        ? "授权 Gemini Developer OAuth"
                        : "重新授权 Gemini Developer OAuth",
                    systemImage: "person.badge.key"
                )
                    .frame(minHeight: 28)
            }
            .buttonStyle(.bordered)
            .disabled(
                !oauthAvailability.isEnabled
                    || (existingOAuthEntry == nil
                        && (oauthClientID.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                            || oauthBillingProjectID.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty))
            )
            .accessibilityHint(
                oauthAvailability.reason ?? "查看经官方证据核实的 Gemini 开发者 OAuth 前置条件"
            )

            if let reason = oauthAvailability.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let oauthFormError {
                Text(oauthFormError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("使用你自己的 Google Cloud Desktop OAuth Client 与项目，应用会打开 Google 官方授权页；消费者订阅账号不会进入凭证池。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submitGeminiOAuth() {
        guard oauthAvailability.isEnabled else { return }
        if existingOAuthEntry != nil {
            oauthFormError = nil
            beginGeminiOAuth(state.providerID)
            return
        }
        guard state.entries.count < CredentialPoolConfiguration.maximumEntries else {
            oauthFormError = "每个供应商最多保存 32 个开发者凭证。"
            return
        }
        let entry = CredentialPoolsViewPolicy.makeGeminiDeveloperOAuthEntry(
            providerID: state.providerID,
            clientID: oauthClientID,
            billingProjectID: oauthBillingProjectID,
            priority: nextPriority
        )
        guard CredentialCompliancePolicy.authorizationDecision(
            for: entry,
            providerKind: state.providerKind
        ) == .allowed else {
            oauthFormError = "Client ID 或 Google Cloud 项目 ID 格式无效，未发起授权。"
            return
        }
        oauthFormError = nil
        onAddEntry(entry)
        beginGeminiOAuth(state.providerID)
        oauthClientID = ""
        oauthBillingProjectID = ""
    }

    private func metadataBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.10), in: Capsule())
    }

    private func submitDeveloperAPIKey() {
        let transientSecret = apiKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transientSecret.isEmpty else { return }
        let trimmedLabel = apiKeyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = CredentialPoolsViewPolicy.makeDeveloperAPIKeyEntry(
            providerID: state.providerID,
            label: trimmedLabel.isEmpty ? "开发者 API Key" : trimmedLabel,
            priority: nextPriority
        )

        onAddEntry(entry)
        saveSecret(entry.id, transientSecret)
        apiKeySecret.removeAll(keepingCapacity: false)
        apiKeyLabel = ""
    }

    private var nextPriority: Int {
        let current = min(
            CredentialPoolEntry.maximumPriority,
            state.entries.map(\.priority).max() ?? -1
        )
        return min(CredentialPoolEntry.maximumPriority, current + 1)
    }
}

private extension CredentialPoolMode {
    var displayName: String {
        switch self {
        case .manualOnly: "仅手动选择"
        case .failoverOnly: "仅失效后故障转移"
        }
    }
}

private extension CredentialSecretKind {
    var displayName: String {
        switch self {
        case .apiKey: "开发者 API Key"
        case .oauthRefreshToken: "开发者 OAuth"
        case .workloadIdentity: "工作负载身份"
        }
    }
}

private extension CredentialIntendedUse {
    var displayName: String {
        switch self {
        case .developerAPI: "开发者 API"
        case .consumerSubscription: "消费者订阅（禁止自动化）"
        }
    }
}
