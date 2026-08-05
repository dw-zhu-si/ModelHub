import SwiftUI
import ModelHubCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
                    .accessibilityLabel(item.title)
            }
            .navigationTitle("模型枢纽")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            Group {
                switch model.selection ?? .overview {
                case .overview: OverviewView()
                case .providers: ProvidersView()
                case .routes: RoutesView()
                case .analytics: AnalyticsView()
                case .operations: OperationsView()
                case .console: ConsoleView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
            .safeAreaPadding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem {
                    ServerStatusButton()
                }
            }
        }
        .alert(
            "模型枢纽",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            )
        ) {
            Button("好") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }
}

private struct ServerStatusButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.isServerRunning ? model.stopServer() : model.startServer()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isServerRunning ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(model.isServerRunning ? .green : .secondary)
                Text(model.isServerRunning ? "API 运行中" : "启动 API")
            }
        }
        .help(model.isServerRunning ? "停止本地 API 服务" : "启动本地 API 服务")
        .accessibilityLabel(model.isServerRunning ? "API 服务正在运行，点击停止" : "API 服务已停止，点击启动")
    }
}

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "概览",
                    subtitle: "把不同模型供应商统一成一个本机 OpenAI 兼容接口。"
                )

                EndpointCard()

                LazyVGrid(columns: columns, spacing: 16) {
                    MetricCard(
                        title: "已启用供应商",
                        value: "\(model.providers.filter(\.enabled).count)",
                        icon: "server.rack",
                        color: .blue
                    )
                    MetricCard(
                        title: "可用路由",
                        value: "\(model.routes.filter(\.enabled).count)",
                        icon: "arrow.triangle.branch",
                        color: .purple
                    )
                    MetricCard(
                        title: "请求成功率",
                        value: model.successRate,
                        icon: "checkmark.circle",
                        color: .green
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("开始使用")
                        .font(.title3.weight(.semibold))
                    InstructionRow(number: 1, text: "在“模型供应商”中添加 API Key 和模型名称。")
                    InstructionRow(number: 2, text: "在“模型路由”中创建别名，例如 smart 或 fast。")
                    InstructionRow(number: 3, text: "把现有 OpenAI 客户端的 Base URL 改为上方带 /v1 的地址。")
                }
                .cardStyle()

                if model.providers.isEmpty {
                    EmptyCallout(
                        icon: "key",
                        title: "还没有模型供应商",
                        detail: "先添加一个供应商。API Key 将保存在 macOS 钥匙串，不会写入配置文件。",
                        action: "添加供应商"
                    ) {
                        model.selection = .providers
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("概览")
    }
}

private struct EndpointCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill((model.isServerRunning ? Color.green : Color.orange).opacity(0.12))
                Image(systemName: model.isServerRunning ? "bolt.horizontal.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(model.isServerRunning ? .green : .orange)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.isServerRunning ? "本地 API 已运行" : "本地 API 已停止")
                    .font(.headline)
                Text(model.endpointURL)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if let error = model.serverError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button("复制地址") { model.copyEndpoint() }
                .buttonStyle(.bordered)
            Button(model.isServerRunning ? "停止服务" : "启动服务") {
                model.isServerRunning ? model.stopServer() : model.startServer()
            }
            .buttonStyle(.borderedProminent)
        }
        .cardStyle()
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
                .background(.tint.opacity(0.14), in: Circle())
            Text(text)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProvidersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingProvider: ProviderConfig?
    @State private var showingNewProvider = false
    @State private var providerToDelete: ProviderConfig?
    @State private var selectedProviderID: UUID?
    @State private var pendingTestScope: ModelTestScope?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "模型供应商",
                subtitle: "聊天模型执行在线检测；生成类模型显示已接入的原生协议，密钥仅存储在 macOS 钥匙串。",
                trailing: AnyView(
                    HStack(spacing: 8) {
                        Button {
                            pendingTestScope = .all
                        } label: {
                            Label("一键测试", systemImage: "checkmark.arrow.trianglehead.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isTestingModels || enabledModelCount == 0)

                        Button {
                            showingNewProvider = true
                        } label: {
                            Label("添加供应商", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                )
            )
            .padding(24)

            if model.isTestingModels, let progress = model.modelTestProgress {
                ModelTestProgressBanner(progress: progress) {
                    model.cancelModelTesting()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            if model.providers.isEmpty {
                Spacer()
                EmptyCallout(
                    icon: "server.rack",
                    title: "添加第一个模型供应商",
                    detail: "支持 OpenAI、Claude、Gemini、Azure、DeepSeek、Qwen、Kimi、GLM、Grok、Groq、Mistral、Ollama 以及其他 OpenAI 兼容服务。",
                    action: "添加供应商"
                ) {
                    showingNewProvider = true
                }
                Spacer()
            } else {
                HSplitView {
                    List(selection: $selectedProviderID) {
                        ForEach(model.providers) { provider in
                            ProviderRow(
                                provider: provider,
                                summary: model.healthSummary(for: provider),
                                hasAPIKey: model.hasAPIKey(for: provider)
                            ) {
                                editingProvider = provider
                            } test: {
                                pendingTestScope = .provider(provider)
                            } delete: {
                                providerToDelete = provider
                            }
                            .tag(provider.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

                    if let provider = selectedProvider {
                        ProviderModelBrowser(
                            provider: provider,
                            edit: { editingProvider = provider },
                            testAll: { pendingTestScope = .provider(provider) }
                        )
                        .id(provider.id)
                        .frame(minWidth: 460)
                    } else {
                        ContentUnavailableView(
                            "选择供应商",
                            systemImage: "square.stack.3d.up",
                            description: Text("选择左侧供应商后查看模型状态。")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("模型供应商")
        .onAppear {
            if selectedProviderID == nil {
                selectedProviderID = model.providers.first?.id
            }
        }
        .onChange(of: model.providers.map(\.id)) { _, providerIDs in
            if let selectedProviderID {
                if !providerIDs.contains(selectedProviderID) {
                    self.selectedProviderID = providerIDs.first
                }
            } else {
                selectedProviderID = providerIDs.first
            }
        }
        .sheet(isPresented: $showingNewProvider) {
            ProviderEditorView(provider: nil)
                .environmentObject(model)
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditorView(provider: provider)
                .environmentObject(model)
        }
        .confirmationDialog(
            "删除供应商？",
            isPresented: Binding(
                get: { providerToDelete != nil },
                set: { if !$0 { providerToDelete = nil } }
            ),
            presenting: providerToDelete
        ) { provider in
            Button("删除“\(provider.name)”", role: .destructive) {
                model.deleteProvider(provider)
                providerToDelete = nil
            }
        } message: { _ in
            Text("对应钥匙串密钥及路由目标也会删除，此操作无法撤销。")
        }
        .confirmationDialog(
            "开始批量检测？",
            isPresented: Binding(
                get: { pendingTestScope != nil },
                set: { if !$0 { pendingTestScope = nil } }
            ),
            presenting: pendingTestScope
        ) { scope in
            Button("测试 \(scope.modelCount(in: model.providers)) 个模型") {
                switch scope {
                case .all:
                    model.startTestingAllModels()
                case .provider(let provider):
                    model.startTestingAllModels(providerID: provider.id)
                }
                pendingTestScope = nil
            }
            Button("取消", role: .cancel) {
                pendingTestScope = nil
            }
        } message: { scope in
            Text("将检查 \(scope.modelCount(in: model.providers)) 个模型。已隔离的聊天模型也会重新请求上游，成功后自动恢复，失败则继续隔离。图像、视频、语音、转录、向量和重排模型只验证本地原生适配，不自动发起可能计费的生成。最多并发 3 个，单次超时 30 秒。")
        }
    }

    private var selectedProvider: ProviderConfig? {
        guard let selectedProviderID else { return model.providers.first }
        return model.providers.first { $0.id == selectedProviderID }
    }

    private var enabledModelCount: Int {
        model.providers.filter(\.enabled).reduce(0) { $0 + $1.models.count }
    }
}

private enum ModelTestScope: Identifiable {
    case all
    case provider(ProviderConfig)

    var id: String {
        switch self {
        case .all: "all"
        case .provider(let provider): provider.id.uuidString
        }
    }

    func modelCount(in providers: [ProviderConfig]) -> Int {
        switch self {
        case .all:
            providers.filter(\.enabled).reduce(0) { $0 + $1.models.count }
        case .provider(let provider):
            provider.models.count
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderConfig
    let summary: ModelHealthSummary
    let hasAPIKey: Bool
    let edit: () -> Void
    let test: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.kind == .ollama ? "desktopcomputer" : "cloud")
                .font(.title3)
                .foregroundStyle(provider.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(provider.name)
                        .font(.headline)
                    StatusBadge(text: mhLocalized(provider.enabled ? "已启用" : "已停用"), active: provider.enabled)
                }
                Text(mhLocalized(provider.kind.displayName))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(
                    provider.kind.needsAPIKey
                        ? (hasAPIKey ? "密钥已保存" : "缺少密钥")
                        : "无需密钥",
                    systemImage: hasAPIKey || !provider.kind.needsAPIKey
                        ? "key.fill"
                        : "key.slash"
                )
                .font(.caption)
                .foregroundStyle(hasAPIKey || !provider.kind.needsAPIKey ? .green : .orange)
                HStack(spacing: 6) {
                    AvailabilityCountBadge(
                        value: summary.available,
                        label: "可用",
                        status: .available
                    )
                    AvailabilityCountBadge(
                        value: summary.unavailable,
                        label: "已隔离",
                        status: .unavailable
                    )
                    if summary.unknown > 0 {
                        AvailabilityCountBadge(
                            value: summary.unknown,
                            label: "待验证 · 已隔离",
                            status: .unknown
                        )
                    }
                }
                if summary.configurationRequired > 0 || summary.unsupported > 0 {
                    HStack(spacing: 6) {
                        AvailabilityCountBadge(
                            value: summary.configurationRequired,
                            label: "需密钥",
                            status: .configurationRequired
                        )
                        AvailabilityCountBadge(
                            value: summary.unsupported,
                            label: "待适配",
                            status: .unsupported
                        )
                    }
                }
            }

            Spacer()

            Menu {
                Button("编辑供应商与密钥", action: edit)
                Button("测试全部模型", action: test)
                Button("删除", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("\(provider.name) 操作")
        }
        .padding(.vertical, 6)
    }
}

private struct ModelTestProgressBanner: View {
    let progress: ModelTestProgress
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ProgressView(value: progress.fractionCompleted)
                .frame(maxWidth: 240)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在检测 \(progress.currentProvider)")
                    .font(.headline)
                Text("\(progress.completed)/\(progress.total) · 可用 \(progress.available) · 失败/隔离 \(progress.unavailable) · 需配置/待处理 \(progress.skipped)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("停止", role: .cancel, action: cancel)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private enum ModelAvailabilityFilter: String, CaseIterable, Identifiable {
    case all
    case available
    case unavailable
    case unknown
    case configurationRequired
    case unsupported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "全部", locale: AppLanguage.saved.locale)
        case .available: String(localized: "可用", locale: AppLanguage.saved.locale)
        case .unavailable: String(localized: "已隔离", locale: AppLanguage.saved.locale)
        case .unknown: String(localized: "待验证 · 已隔离", locale: AppLanguage.saved.locale)
        case .configurationRequired: String(localized: "需密钥", locale: AppLanguage.saved.locale)
        case .unsupported: String(localized: "待适配", locale: AppLanguage.saved.locale)
        }
    }
}

private struct ProviderModelBrowser: View {
    @EnvironmentObject private var model: AppModel
    let provider: ProviderConfig
    let edit: () -> Void
    let testAll: () -> Void
    @State private var query = ""
    @State private var filter: ModelAvailabilityFilter = .all

    private var summary: ModelHealthSummary {
        model.healthSummary(for: provider)
    }

    private var filteredModels: [String] {
        model.orderedModels(for: provider).filter { modelName in
            let matchesQuery = query.isEmpty
                || modelName.localizedCaseInsensitiveContains(query)
            let status = model.healthRecord(providerID: provider.id, model: modelName)?.status
                ?? .unknown
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .available: matchesFilter = status == .available
            case .unavailable: matchesFilter = status == .unavailable
            case .unknown: matchesFilter = status == .unknown
            case .configurationRequired: matchesFilter = status == .configurationRequired
            case .unsupported: matchesFilter = status == .unsupported
            }
            return matchesQuery && matchesFilter
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.name)
                            .font(.title2.weight(.semibold))
                        Text("\(summary.total) 个模型 · 聊天模型在线检测；生成模型未通过原生验证时保持隔离")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("编辑与密钥", action: edit)
                    Button {
                        testAll()
                    } label: {
                        Label("测试全部", systemImage: "checkmark.arrow.trianglehead.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isTestingModels || provider.models.isEmpty)
                }

                HStack(spacing: 12) {
                    TextField("搜索模型", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180, maxWidth: 320)
                    Picker("状态", selection: $filter) {
                        ForEach(ModelAvailabilityFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }

                HStack(spacing: 8) {
                    AvailabilityCountBadge(value: summary.available, label: "可用", status: .available)
                    AvailabilityCountBadge(value: summary.unavailable, label: "已隔离", status: .unavailable)
                    if summary.unknown > 0 {
                        AvailabilityCountBadge(
                            value: summary.unknown,
                            label: "待验证 · 已隔离",
                            status: .unknown
                        )
                    }
                    if summary.configurationRequired > 0 {
                        AvailabilityCountBadge(
                            value: summary.configurationRequired,
                            label: "需密钥",
                            status: .configurationRequired
                        )
                    }
                    if summary.unsupported > 0 {
                        AvailabilityCountBadge(
                            value: summary.unsupported,
                            label: "待适配",
                            status: .unsupported
                        )
                    }
                    Spacer()
                    Text("显示 \(filteredModels.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            if filteredModels.isEmpty {
                ContentUnavailableView(
                    "没有匹配的模型",
                    systemImage: "magnifyingglass",
                    description: Text("调整搜索文字或状态筛选。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredModels, id: \.self) { modelName in
                            ModelHealthRow(
                                providerID: provider.id,
                                modelName: modelName,
                                nativeProtocol: ModelProbePolicy.nativeProtocol(
                                    provider: provider,
                                    model: modelName
                                ),
                                record: model.healthRecord(
                                    providerID: provider.id,
                                    model: modelName
                                ),
                                isTesting: model.isTesting(
                                    providerID: provider.id,
                                    model: modelName
                                )
                            ) {
                                Task {
                                    _ = await model.testModel(
                                        providerID: provider.id,
                                        model: modelName
                                    )
                                }
                            }
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
            }
        }
    }
}

private struct ModelHealthRow: View {
    @EnvironmentObject private var appModel: AppModel
    let providerID: UUID
    let modelName: String
    let nativeProtocol: ModelNativeProtocol?
    let record: ModelHealthRecord?
    let isTesting: Bool
    let test: () -> Void

    private var status: ModelAvailability {
        record?.status ?? .unknown
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: status.icon)
                        .foregroundStyle(status.color)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(modelName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
                if let nativeProtocol {
                    Label(
                        L10n.format("%@原生入口", mhLocalized(nativeProtocol.displayName)),
                        systemImage: nativeProtocol.icon
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.indigo.opacity(0.1), in: Capsule())
                }
                HStack(spacing: 8) {
                    Text(isTesting ? "测试中" : status.title)
                    if let record {
                        if let latency = record.latencyMilliseconds {
                            Text("\(latency) ms")
                        }
                        Text(record.checkedAt, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let detail = record?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .trailing)
            }

            if status.isQuarantined {
                if nativeProtocol == nil {
                    Button(action: test) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isTesting || appModel.isTestingModels)
                    .help("重新测试已隔离模型 \(modelName)")
                    .accessibilityLabel("重新测试已隔离模型 \(modelName)")
                }
                Button {
                    appModel.markModelAvailable(providerID: providerID, model: modelName)
                } label: {
                    Image(systemName: "checkmark.shield")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(isTesting || appModel.isTestingModels)
                .help("解除隔离并标记 \(modelName) 为可用")
                .accessibilityLabel("解除隔离并标记模型 \(modelName) 为可用")
            } else {
                Button(action: test) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(isTesting || appModel.isTestingModels)
                .help("测试 \(modelName)")
                .accessibilityLabel("测试模型 \(modelName)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(modelName)，\(isTesting ? "测试中" : status.title)")
    }
}

private struct AvailabilityCountBadge: View {
    let value: Int
    let label: String
    let status: ModelAvailability

    var body: some View {
        Label("\(value) \(label)", systemImage: status.icon)
            .font(.caption2)
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.1), in: Capsule())
            .accessibilityLabel("\(label) \(value) 个")
    }
}

private extension ModelAvailability {
    var title: String {
        switch self {
        case .available: String(localized: "可用", locale: AppLanguage.saved.locale)
        case .unavailable: String(localized: "已隔离", locale: AppLanguage.saved.locale)
        case .unknown: String(localized: "待验证 · 已隔离", locale: AppLanguage.saved.locale)
        case .configurationRequired: String(localized: "需配置密钥 · 已隔离", locale: AppLanguage.saved.locale)
        case .unsupported: String(localized: "待适配 · 已隔离", locale: AppLanguage.saved.locale)
        }
    }

    var icon: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .unavailable: "xmark.circle.fill"
        case .unknown: "exclamationmark.shield.fill"
        case .configurationRequired: "key.slash.fill"
        case .unsupported: "point.3.connected.trianglepath.dotted"
        }
    }

    var color: Color {
        switch self {
        case .available: .green
        case .unavailable: .red
        case .unknown: .orange
        case .configurationRequired: .orange
        case .unsupported: .indigo
        }
    }
}

private extension ModelNativeProtocol {
    var icon: String {
        switch self {
        case .imageGeneration: "photo"
        case .videoGeneration: "video"
        case .speech: "waveform"
        case .transcription: "captions.bubble"
        case .embeddings: "point.3.filled.connected.trianglepath.dotted"
        case .reranking: "arrow.up.arrow.down"
        case .providerNative: "arrow.triangle.branch"
        }
    }
}

struct ProviderEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ProviderConfig
    @State private var apiKey: String
    @State private var modelsText: String
    @State private var testResult = ""
    @State private var isTesting = false
    @State private var showingDeleteKeyConfirmation = false

    init(provider: ProviderConfig?) {
        let initial = provider ?? ProviderConfig(
            name: "OpenAI",
            kind: .openAI,
            baseURL: ProviderKind.openAI.defaultBaseURL
        )
        _provider = State(initialValue: initial)
        _apiKey = State(initialValue: "")
        _modelsText = State(initialValue: initial.models.joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(provider.name.isEmpty ? "添加供应商" : provider.name)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    provider.models = parsedModels
                    if model.saveProvider(provider, apiKey: apiKey) {
                        apiKey = ""
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(20)

            Divider()

            Form {
                Section("基本信息") {
                    TextField("名称", text: $provider.name)
                    Picker("供应商类型", selection: $provider.kind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(mhLocalized(kind.displayName)).tag(kind)
                        }
                    }
                    .onChange(of: provider.kind) { oldValue, newValue in
                        if provider.baseURL == oldValue.defaultBaseURL || provider.baseURL.isEmpty {
                            provider.baseURL = newValue.defaultBaseURL
                        }
                        if provider.name == oldValue.displayName || provider.name.isEmpty {
                            provider.name = newValue.displayName
                        }
                    }
                    TextField("Base URL", text: $provider.baseURL)
                        .font(.system(.body, design: .monospaced))
                    Toggle("启用此供应商", isOn: $provider.enabled)
                }

                Section("凭证") {
                    HStack {
                        Label(
                            credentialStatusText,
                            systemImage: hasStoredAPIKey ? "key.fill" : "key.slash"
                        )
                        .foregroundStyle(hasStoredAPIKey ? .green : .orange)
                        Spacer()
                        if hasStoredAPIKey {
                            Button("删除已保存密钥", role: .destructive) {
                                showingDeleteKeyConfirmation = true
                            }
                        }
                    }
                    SecureField(
                        hasStoredAPIKey ? "输入新的 API Key 以替换" : "输入 API Key",
                        text: $apiKey
                    )
                    .textContentType(.password)
                    Text(
                        hasStoredAPIKey
                            ? "当前密钥不会显示。输入新密钥并保存即可覆盖；留空会保留原密钥。"
                            : "尚未保存密钥。密钥只写入 macOS 钥匙串；Ollama 可留空。"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if provider.kind == .anthropic || provider.kind == .azureOpenAI {
                        TextField("API 版本（可选）", text: $provider.apiVersion)
                    }
                }

                Section("模型名称") {
                    TextEditor(text: $modelsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                    Text("共 \(parsedModels.count) 个模型；每行一个名称。Azure OpenAI 这里填写部署名称。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("连接测试") {
                    HStack {
                        Button {
                            Task {
                                isTesting = true
                                provider.models = parsedModels
                                if model.saveProvider(provider, apiKey: apiKey) {
                                    apiKey = ""
                                    testResult = await model.testProvider(provider)
                                } else {
                                    testResult = "API Key 保存失败，请查看提示。"
                                }
                                isTesting = false
                            }
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("测试第一个模型", systemImage: "waveform.path.ecg")
                            }
                        }
                        .disabled(isTesting || parsedModels.isEmpty)
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 680)
        .confirmationDialog(
            "删除已保存的 API Key？",
            isPresented: $showingDeleteKeyConfirmation
        ) {
            Button("删除 API Key", role: .destructive) {
                model.deleteAPIKey(for: provider)
                apiKey = ""
                testResult = "API Key 已删除；后续检测不会发起上游请求。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，需要重新输入才能调用此供应商。")
        }
    }

    private var hasStoredAPIKey: Bool {
        model.hasAPIKey(for: provider)
    }

    private var credentialStatusText: String {
        if !provider.kind.needsAPIKey { return String(localized: "此供应商无需 API Key", locale: AppLanguage.saved.locale) }
        return mhLocalized(hasStoredAPIKey ? "钥匙串中已保存 API Key" : "尚未保存 API Key")
    }

    private var parsedModels: [String] {
        modelsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var isValid: Bool {
        !provider.name.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: provider.baseURL)?.scheme != nil
            && !parsedModels.isEmpty
    }
}

struct RoutesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingRoute: RouteConfig?
    @State private var showingNewRoute = false
    @State private var routeToDelete: RouteConfig?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "模型路由",
                subtitle: "用稳定别名隔离业务与具体模型，并在限流或故障时自动切换。",
                trailing: AnyView(
                    Button {
                        showingNewRoute = true
                    } label: {
                        Label("新建路由", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.providers.isEmpty)
                )
            )
            .padding(24)

            if model.routes.isEmpty {
                Spacer()
                EmptyCallout(
                    icon: "arrow.triangle.branch",
                    title: model.providers.isEmpty ? "请先添加供应商" : "创建第一个模型路由",
                    detail: "客户端只需要请求路由别名，模型枢纽会按优先级、轮询或权重选择上游。",
                    action: model.providers.isEmpty ? "前往供应商" : "新建路由"
                ) {
                    if model.providers.isEmpty {
                        model.selection = .providers
                    } else {
                        showingNewRoute = true
                    }
                }
                Spacer()
            } else {
                List {
                    ForEach(model.routes) { route in
                        RouteRow(route: route) {
                            editingRoute = route
                        } delete: {
                            routeToDelete = route
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("模型路由")
        .sheet(isPresented: $showingNewRoute) {
            RouteEditorView(route: nil)
                .environmentObject(model)
        }
        .sheet(item: $editingRoute) { route in
            RouteEditorView(route: route)
                .environmentObject(model)
        }
        .confirmationDialog(
            "删除路由？",
            isPresented: Binding(
                get: { routeToDelete != nil },
                set: { if !$0 { routeToDelete = nil } }
            ),
            presenting: routeToDelete
        ) { route in
            Button("删除“\(route.alias)”", role: .destructive) {
                model.deleteRoute(route)
                routeToDelete = nil
            }
        }
    }
}

private struct RouteRow: View {
    let route: RouteConfig
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title2)
                .foregroundStyle(route.enabled ? Color.purple : Color.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(route.alias)
                        .font(.system(.headline, design: .monospaced))
                    StatusBadge(text: mhLocalized(route.enabled ? "已启用" : "已停用"), active: route.enabled)
                }
                Text(mhLocalized(route.strategy.displayName))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(route.targets.count) 个目标")
                .foregroundStyle(.secondary)
            Menu {
                Button("编辑", action: edit)
                Button("删除", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("\(route.alias) 路由操作")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
    }
}

struct RouteEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var route: RouteConfig

    init(route: RouteConfig?) {
        _route = State(initialValue: route ?? RouteConfig(alias: "smart"))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("模型路由")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    model.saveRoute(route)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(20)
            Divider()

            Form {
                Section("路由规则") {
                    TextField("客户端模型别名", text: $route.alias)
                        .font(.system(.body, design: .monospaced))
                    Picker("选择策略", selection: $route.strategy) {
                        ForEach(RouteStrategy.allCases) { strategy in
                            Text(mhLocalized(strategy.displayName)).tag(strategy)
                        }
                    }
                    Toggle("启用此路由", isOn: $route.enabled)
                }

                Section {
                    ForEach($route.targets) { $target in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Picker("供应商", selection: $target.providerID) {
                                    ForEach(model.providers) { provider in
                                        Text(provider.name).tag(provider.id)
                                    }
                                }
                                Button(role: .destructive) {
                                    route.targets.removeAll { $0.id == target.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("删除目标")
                            }
                            TextField("上游模型名称", text: $target.model)
                                .font(.system(.body, design: .monospaced))
                            HStack {
                                Stepper("优先级 \(target.priority)", value: $target.priority, in: 0...100)
                                Spacer()
                                Stepper("权重 \(target.weight)", value: $target.weight, in: 1...100)
                            }
                            .font(.caption)
                            Toggle(
                                "配置能力、上下文、价格与配额",
                                isOn: Binding(
                                    get: { target.profile != nil },
                                    set: { enabled in
                                        target.profile = enabled ? (target.profile ?? TargetProfile()) : nil
                                    }
                                )
                            )
                            if target.profile != nil {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                    GridRow {
                                        Text("上下文窗口")
                                        TextField(
                                            "未知",
                                            value: Binding(
                                                get: { target.profile?.contextWindow ?? 0 },
                                                set: { target.profile?.contextWindow = $0 > 0 ? $0 : nil }
                                            ),
                                            format: .number
                                        )
                                        Text("月 Token 上限")
                                        TextField(
                                            "不限",
                                            value: Binding(
                                                get: { target.profile?.monthlyTokenLimit ?? 0 },
                                                set: { target.profile?.monthlyTokenLimit = $0 > 0 ? $0 : nil }
                                            ),
                                            format: .number
                                        )
                                    }
                                    GridRow {
                                        Text("输入 $/百万 Token")
                                        TextField(
                                            "未知",
                                            value: Binding(
                                                get: { target.profile?.inputCostPerMillionTokens ?? 0 },
                                                set: {
                                                    target.profile?.inputCostPerMillionTokens = $0 >= 0 ? $0 : nil
                                                    target.profile?.pricingUpdatedAt = .now
                                                }
                                            ),
                                            format: .number
                                        )
                                        Text("输出 $/百万 Token")
                                        TextField(
                                            "未知",
                                            value: Binding(
                                                get: { target.profile?.outputCostPerMillionTokens ?? 0 },
                                                set: {
                                                    target.profile?.outputCostPerMillionTokens = $0 >= 0 ? $0 : nil
                                                    target.profile?.pricingUpdatedAt = .now
                                                }
                                            ),
                                            format: .number
                                        )
                                    }
                                    GridRow {
                                        Text("价格来源")
                                        TextField(
                                            "例如：供应商定价页 / 手工",
                                            text: Binding(
                                                get: { target.profile?.pricingSource ?? "" },
                                                set: {
                                                    target.profile?.pricingSource = $0
                                                    target.profile?.pricingUpdatedAt = .now
                                                }
                                            )
                                        )
                                        .gridCellColumns(3)
                                    }
                                }
                                Text("能力标签")
                                    .font(.caption.weight(.semibold))
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), alignment: .leading, spacing: 6) {
                                    ForEach(ModelCapability.allCases) { capability in
                                        Toggle(
                                            capability.displayName,
                                            isOn: Binding(
                                                get: { target.profile?.capabilities.contains(capability) == true },
                                                set: { enabled in
                                                    if enabled {
                                                        target.profile?.capabilities.insert(capability)
                                                    } else {
                                                        target.profile?.capabilities.remove(capability)
                                                    }
                                                }
                                            )
                                        )
                                        .toggleStyle(.checkbox)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    Button {
                        if let provider = model.providers.first {
                            route.targets.append(
                                RouteTarget(
                                    providerID: provider.id,
                                    model: provider.models.first ?? ""
                                )
                            )
                        }
                    } label: {
                        Label("添加路由目标", systemImage: "plus")
                    }
                    .disabled(model.providers.isEmpty)
                } header: {
                    Text("上游目标")
                } footer: {
                    Text("优先级数值越小越先尝试；权重仅用于权重随机策略。5xx、429 或网络错误会触发故障转移。")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 780, height: 820)
    }

    private var isValid: Bool {
        !route.alias.trimmingCharacters(in: .whitespaces).isEmpty
            && !route.targets.isEmpty
            && route.targets.allSatisfy { !$0.model.trimmingCharacters(in: .whitespaces).isEmpty }
            && !model.routes.contains {
                $0.id != route.id && $0.alias.caseInsensitiveCompare(route.alias) == .orderedSame
            }
    }
}

struct ConsoleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedModel = ""
    @State private var prompt = "请用一句话介绍你自己。"

    private var availableModels: [String] {
        let aliases = model.routes.filter(\.enabled).map(\.alias)
        let direct = model.providers.filter(\.enabled).flatMap { provider in
            model.orderedModels(for: provider).map { "\(provider.name)/\($0)" }
        }
        return aliases + direct
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "API 调试", subtitle: "从应用内部调用同一个本地 HTTP 接口，验证完整路由链路。")

            HStack {
                Picker("模型", selection: $selectedModel) {
                    Text("请选择").tag("")
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .frame(maxWidth: 420)
                Spacer()
                Button {
                    Task { await model.runConsole(model: selectedModel, prompt: prompt) }
                } label: {
                    if model.consoleIsRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("发送请求", systemImage: "paperplane")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedModel.isEmpty || prompt.isEmpty || model.consoleIsRunning)
            }

            GroupBox("用户消息") {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 110)
                    .padding(8)
            }

            GroupBox("响应") {
                ScrollView {
                    Text(model.consoleOutput.isEmpty ? "响应将在这里显示。" : model.consoleOutput)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(model.consoleOutput.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(24)
        .navigationTitle("API 调试")
        .onAppear {
            if selectedModel.isEmpty { selectedModel = availableModels.first ?? "" }
        }
        .onChange(of: availableModels) { _, models in
            if !models.contains(selectedModel) { selectedModel = models.first ?? "" }
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "请求日志",
                subtitle: "只记录路由结果、状态和耗时，不记录提示词、响应正文或密钥。",
                trailing: AnyView(
                    Button("清空") { model.logs.removeAll() }
                        .disabled(model.logs.isEmpty)
                )
            )
            .padding(24)

            if model.logs.isEmpty {
                Spacer()
                EmptyCallout(
                    icon: "list.bullet.rectangle",
                    title: "暂无请求",
                    detail: "通过 API 调试台或外部客户端发送请求后，路由日志会出现在这里。",
                    action: "打开调试台"
                ) {
                    model.selection = .console
                }
                Spacer()
            } else {
                Table(model.logs) {
                    TableColumn("时间") { entry in
                        Text(entry.timestamp, style: .time)
                    }
                    .width(80)
                    TableColumn("模型") { entry in
                        Text(entry.model)
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("上游") { entry in
                        Text(entry.provider)
                    }
                    TableColumn("状态") { entry in
                        Text("\(entry.statusCode)")
                            .foregroundStyle((200..<300).contains(entry.statusCode) ? .green : .orange)
                    }
                    .width(60)
                    TableColumn("耗时") { entry in
                        Text("\(entry.latencyMilliseconds) ms")
                    }
                    .width(90)
                    TableColumn("结果") { entry in
                        Text(entry.detail)
                    }
                }
            }
        }
        .navigationTitle("请求日志")
    }
}

struct AnalyticsView: View {
    @EnvironmentObject private var model: AppModel

    private var month: String { UsageAccounting.monthKey() }
    private var rows: [UsageAggregate] {
        model.configuration.usage.filter { $0.month == month }
    }
    private var totalCost: Double { rows.reduce(0) { $0 + $1.estimatedCostUSD } }
    private var totalTokens: Int { rows.reduce(0) { $0 + $1.inputTokens + $1.outputTokens } }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "用量分析",
                subtitle: "按模型与供应商聚合成功率、延迟、Token 和已知价格估算；不保存提示词或响应正文。"
            )
            .padding(24)

            HStack(spacing: 16) {
                MetricCard(title: "本月请求", value: "\(rows.reduce(0) { $0 + $1.requests })", icon: "arrow.up.arrow.down", color: .blue)
                MetricCard(title: "Token", value: "\(totalTokens)", icon: "number", color: .purple)
                MetricCard(title: "已知价格估算", value: String(format: "$%.4f", totalCost), icon: "dollarsign.circle", color: .green)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            if let warning = model.budgetStatusText {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            if rows.isEmpty {
                Spacer()
                Text("本月暂无聚合用量。未知价格不会被伪算为已知费用。")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Table(rows) {
                    TableColumn("请求模型") { Text($0.requestedModel).font(.system(.body, design: .monospaced)) }
                    TableColumn("供应商 / 模型") { Text("\($0.providerName) / \($0.model)") }
                    TableColumn("成功") { row in
                        Text(row.requests > 0 ? "\(Int(Double(row.successfulRequests) / Double(row.requests) * 100))%" : "—")
                    }.width(60)
                    TableColumn("平均耗时") { Text("\($0.averageLatencyMilliseconds) ms") }.width(90)
                    TableColumn("Token") { Text("\($0.inputTokens + $0.outputTokens)") }.width(80)
                    TableColumn("估算费用") { row in
                        Text(row.pricedRequests > 0 ? String(format: "$%.4f", row.estimatedCostUSD) : "未知")
                    }.width(90)
                }
            }
        }
        .navigationTitle("用量分析")
    }
}

struct OperationsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var settings = OperationalSettings()
    @State private var monthlyBudget = ""
    @State private var showAgentToken = false

    var body: some View {
        Form {
            Section("韧性控制") {
                Stepper("每分钟请求上限：\(settings.resilience.requestsPerMinute)", value: $settings.resilience.requestsPerMinute, in: 10...10_000, step: 10)
                Stepper("单目标并发上限：\(settings.resilience.maxConcurrentRequestsPerTarget)", value: $settings.resilience.maxConcurrentRequestsPerTarget, in: 1...64)
                Stepper("连续失败熔断阈值：\(settings.resilience.failureThreshold)", value: $settings.resilience.failureThreshold, in: 1...10)
                Stepper("熔断冷却：\(settings.resilience.cooldownSeconds) 秒", value: $settings.resilience.cooldownSeconds, in: 5...600, step: 5)
                Stepper("最多回退目标：\(settings.resilience.maxFallbackAttempts)", value: $settings.resilience.maxFallbackAttempts, in: 1...10)
                Stepper("退避基数：\(settings.resilience.backoffBaseMilliseconds) ms", value: $settings.resilience.backoffBaseMilliseconds, in: 0...2_000, step: 50)
                Text("只在不同目标之间回退，同一目标不会自动重复计费调用。429、5xx 与网络错误计入熔断。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("预算与上下文") {
                TextField("月度费用上限（USD，留空表示不设）", text: $monthlyBudget)
                Toggle("达到上限时阻止上游调用", isOn: $settings.budget.hardLimitEnabled)
                Picker("上下文优化", selection: $settings.contextOptimization.mode) {
                    ForEach(ContextOptimizationMode.allCases) { Text(mhLocalized($0.displayName)).tag($0) }
                }
                Stepper("启用整理的最小字符数：\(settings.contextOptimization.minimumCharacters)", value: $settings.contextOptimization.minimumCharacters, in: 0...100_000, step: 500)
                Text("保守整理默认关闭；只移除行尾空白和多余空行，跳过代码块、结构化多模态内容与工具参数。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("本机 Agent 协议") {
                Toggle("启用 MCP（/mcp）", isOn: $settings.agentProtocols.mcpEnabled)
                Toggle("启用 A2A（/a2a 与 Agent Card）", isOn: $settings.agentProtocols.a2aEnabled)
                Toggle("启用 ACP stdio 清单", isOn: $settings.agentProtocols.acpManifestEnabled)
                HStack {
                    Text(showAgentToken ? model.agentToken : String(repeating: "•", count: 28))
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button(showAgentToken ? "隐藏" : "显示") { showAgentToken.toggle() }
                    Button("复制") { model.copyAgentToken() }
                }
                Button("重新生成独立 Agent 令牌", role: .destructive) { model.regenerateAgentToken() }
                Text("仅监听 127.0.0.1；校验本机 Origin；工具全部只读，并且模型目录只返回未隔离目标。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("保存路由与协议设置") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("路由与协议")
        .onAppear {
            settings = model.configuration.operational
            monthlyBudget = settings.budget.monthlyLimitUSD.map { String($0) } ?? ""
        }
    }

    private func save() {
        settings.budget.monthlyLimitUSD = Double(monthlyBudget)
        model.persistOperationalSettings(settings)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var requireAuthentication = true
    @State private var startAutomatically = true
    @State private var showToken = false

    var body: some View {
        Form {
            Section("界面语言") {
                Picker(
                    "语言",
                    selection: Binding(
                        get: { model.preferredLanguage },
                        set: { model.setPreferredLanguage($0) }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                Text("应用界面会立即切换；Widget 默认跟随 macOS 系统语言。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本地 API 服务") {
                LabeledContent("OpenAI Base URL") {
                    Text("http://127.0.0.1:\(ServerSettings.fixedPort)/v1")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("端口由 ModelHub 与 ProjectDock 固定管理，仅监听本机回环地址；请保留末尾 /v1。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("应用启动时自动开启服务", isOn: $startAutomatically)
                Toggle("要求 Bearer 访问令牌", isOn: $requireAuthentication)
            }

            Section("系统启动") {
                Toggle(
                    "登录时自动启动 ModelHub",
                    isOn: Binding(
                        get: { model.launchAtLoginRequested },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    )
                )
                Text(model.launchAtLoginStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("刷新登录项状态") { model.refreshLaunchAtLoginStatus() }
            }

            Section("访问令牌") {
                HStack {
                    Text(showToken ? model.gatewayToken : String(repeating: "•", count: 28))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(showToken ? "隐藏" : "显示") { showToken.toggle() }
                    Button("复制") { model.copyGatewayToken() }
                }
                Button("重新生成令牌", role: .destructive) {
                    model.regenerateGatewayToken()
                }
            }

            Section("本地备份与回滚") {
                HStack {
                    Button("导出备份") { model.exportConfigurationBackup() }
                    Button("预览并导入") { model.importConfigurationBackup() }
                    Button("恢复上次导入前配置") { model.restoreLastRollbackBackup() }
                }
                Text("备份包含供应商配置、路由、健康记录和聚合用量；始终排除 Keychain 密钥与令牌。导入前会创建回滚副本。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("CLI 配置预览") {
                Text(model.cliConfigurationPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("复制无密钥配置预览") { model.copyCLIConfigurationPreview() }
                Text("ModelHub 不自动修改任何 CLI 配置文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(model.isServerRunning ? "停止服务" : "启动服务") {
                        save(restart: false)
                        model.isServerRunning ? model.stopServer() : model.startServer()
                    }
                    Spacer()
                    Button("保存设置") { save(restart: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("服务设置")
        .onAppear {
            requireAuthentication = model.configuration.server.requireAuthentication
            startAutomatically = model.configuration.server.startAutomatically
            model.refreshLaunchAtLoginStatus()
        }
    }

    private func save(restart: Bool) {
        model.persistServerSettings(
            ServerSettings(
                requireAuthentication: requireAuthentication,
                startAutomatically: startAutomatically
            ),
            restart: restart
        )
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusBadge: View {
    let text: String
    let active: Bool

    var body: some View {
        Label(text, systemImage: active ? "checkmark.circle.fill" : "pause.circle")
            .font(.caption)
            .foregroundStyle(active ? Color.green : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((active ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
    }
}

private struct EmptyCallout: View {
    let icon: String
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button(action, action: perform)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.6), lineWidth: 1)
            }
    }
}
