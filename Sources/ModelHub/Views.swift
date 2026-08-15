import SwiftUI
import AppKit
import ModelHubCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isReviewDemoMode && !model.isProviderLayoutStressDemo {
                ReviewDemoBanner()
            }
            NavigationSplitView {
                VStack(spacing: 0) {
                    SidebarBrandHeader()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            SidebarSection("工作台", items: [.overview, .providers, .routes, .analytics])
                            SidebarSection("开发与治理", items: [.operations, .governance, .console, .logs])
                            SidebarSection("系统", items: [.proxy, .settings])
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                    }

                    SidebarServiceSummary()
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .background(MHDesign.sidebarSurface)
                .safeAreaPadding(.top, 28)
                .navigationSplitViewColumnWidth(
                    min: 208,
                    ideal: MHDesign.sidebarWidth,
                    max: 268
                )
            } detail: {
                Group {
                    switch model.selection ?? .overview {
                    case .overview: OverviewView()
                    case .providers: ProvidersView()
                    case .routes: RoutesView()
                    case .analytics: AnalyticsView()
                    case .operations: OperationsView()
                    case .governance: GovernanceView()
                    case .console: ConsoleView()
                    case .logs: LogsView()
                    case .proxy: ProxySubscriptionsView()
                    case .settings: SettingsView()
                    }
                }
                .safeAreaPadding(.top, 18)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .mhPageBackground()
                .groupBoxStyle(MHGroupBoxStyle())
                .toolbar {
                    ToolbarItem {
                        ServerStatusButton()
                    }
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
        .tint(MHDesign.accent)
    }
}

private struct SidebarSection: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let items: [SidebarItem]

    init(_ title: String, items: [SidebarItem]) {
        self.title = title
        self.items = items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(mhLocalized(title))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.leading, 9)

            ForEach(items) { item in
                Button {
                    model.selection = item
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(
                                model.selection == item ? Color.white : Color.primary.opacity(0.78)
                            )
                            .frame(width: 20, height: 20)
                        Text(item.title)
                            .font(.system(size: 13.5, weight: model.selection == item ? .semibold : .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(model.selection == item ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(model.selection == item ? MHDesign.accent : Color.clear)
                            .shadow(
                                color: model.selection == item ? MHDesign.accent.opacity(0.22) : .clear,
                                radius: 6,
                                y: 3
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(model.selection == item ? .isSelected : [])
            }
        }
    }
}

private struct SidebarBrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            MHIconTile(
                symbol: "point.3.connected.trianglepath.dotted",
                size: 40,
                emphasized: true
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("ModelHub")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("本机 AI 路由中枢")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarServiceSummary: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isServerRunning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                    .overlay {
                        if model.isServerRunning {
                            Circle().stroke(Color.green.opacity(0.24), lineWidth: 5)
                        }
                    }
                Text(model.isServerRunning ? "API 服务运行中" : "API 服务已停止")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text("\(model.providers.filter(\.enabled).count) 个供应商 · \(availableModelCount) 个可用模型")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(MHDesign.elevatedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(MHDesign.border)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private var availableModelCount: Int {
        model.providers.reduce(0) { total, provider in
            total + model.healthSummary(for: provider).available
        }
    }
}

private struct ReviewDemoBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.blue)
            Text("审核演示模式")
                .font(.headline)
            Text("仅使用合成数据，不读取凭证、不访问模型供应商，也不会产生费用。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("退出演示") { model.exitReviewDemoMode() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(MHDesign.accent.opacity(0.09))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
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
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(MHDesign.elevatedSurface.opacity(0.86), in: Capsule())
            .overlay { Capsule().stroke(MHDesign.border) }
        }
        .buttonStyle(.plain)
        .help(model.isServerRunning ? "停止本地 API 服务" : "启动本地 API 服务")
        .accessibilityLabel(model.isServerRunning ? "API 服务正在运行，点击停止" : "API 服务已停止，点击启动")
    }
}

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MHDesign.sectionSpacing) {
                PageHeader(
                    title: "概览",
                    subtitle: "把不同模型供应商统一成一个本机兼容接口。"
                )

                if model.providers.isEmpty && !model.isReviewDemoMode {
                    ReviewDemoEntryCard()
                }

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

                VStack(alignment: .leading, spacing: 16) {
                    MHSectionHeading(
                        title: "三步开始使用",
                        detail: "凭证留在本机，客户端只需记住一个统一入口。"
                    )
                    InstructionRow(number: 1, text: "在“模型供应商”中添加 API Key 和模型名称。")
                    Divider().opacity(0.55)
                    InstructionRow(number: 2, text: "在“模型路由”中创建别名，例如 smart 或 fast。")
                    Divider().opacity(0.55)
                    InstructionRow(number: 3, text: "把兼容客户端的 Base URL 改为上方带 /v1 的地址。")
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
            .padding(MHDesign.pagePadding)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct ReviewDemoEntryCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            MHIconTile(symbol: "play.rectangle.on.rectangle.fill", size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text("无需账号即可完整体验")
                    .font(.headline)
                Text("进入审核演示模式，查看多供应商、模型分类、三种默认路由规则、故障转移、用量分析、请求日志和本机 API 调试。所有内容均为合成数据。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button("进入审核演示") { model.enterReviewDemoMode() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .mhSurface(.secondary, padding: 20)
        .accessibilityElement(children: .contain)
    }
}

private struct EndpointCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isServerRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.isServerRunning ? "LOCAL GATEWAY ONLINE" : "LOCAL GATEWAY PAUSED")
                        .font(.caption2.weight(.bold))
                        .tracking(0.9)
                        .foregroundStyle(.white.opacity(0.72))
                }

                Text(mhLocalized(model.isServerRunning ? "本地 API 已运行" : "本地 API 已停止"))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.white.opacity(0.65))
                    Text(model.endpointURL)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))

                if let error = model.serverError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    model.copyEndpoint()
                } label: {
                    Label("复制地址", systemImage: "doc.on.doc")
                        .frame(minWidth: 94)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.20))

                Button(mhLocalized(model.isServerRunning ? "停止服务" : "启动服务")) {
                    model.isServerRunning ? model.stopServer() : model.startServer()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(26)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [MHDesign.heroStart, MHDesign.heroEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: MHDesign.accent.opacity(0.16), radius: 22, y: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        }
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
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(MHDesign.accent)
                    .frame(width: 32, height: 32)
                    .background(MHDesign.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                Text(mhLocalized(title))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
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
                .foregroundStyle(MHDesign.accent)
                .frame(width: 28, height: 28)
                .background(MHDesign.accent.opacity(0.11), in: Circle())
            Text(mhLocalized(text))
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
            .padding(MHDesign.pagePadding)

            if model.isTestingModels, let progress = model.modelTestProgress {
                ModelTestProgressBanner(progress: progress) {
                    model.cancelModelTesting()
                }
                .padding(.horizontal, MHDesign.pagePadding)
                .padding(.bottom, 16)
            }

            if model.providers.isEmpty {
                Spacer()
                EmptyCallout(
                    icon: "server.rack",
                    title: "添加第一个模型供应商",
                    detail: "支持 Claude、Gemini、DeepSeek、Qwen、Kimi、GLM、Grok、Groq、Mistral、Ollama 以及其他兼容服务。",
                    action: "添加供应商"
                ) {
                    showingNewProvider = true
                }
                Spacer()
            } else {
                GeometryReader { splitProxy in
                    HSplitView {
                        ScrollViewReader { providerListProxy in
                            List(selection: $selectedProviderID) {
                                ForEach(model.providers) { provider in
                                    ProviderRow(
                                        provider: provider,
                                        summary: model.healthSummary(for: provider),
                                        hasAPIKey: model.hasAPIKey(for: provider),
                                        credentialIssue: model.providerCredentialValidationMessage(
                                            for: provider,
                                            enteredAPIKey: ""
                                        ),
                                        isSelected: selectedProviderID == provider.id,
                                        isHotRefreshing: model.isHotRefreshingProviderCatalog(provider.id)
                                    ) {
                                        editingProvider = provider
                                    } refresh: {
                                        Task {
                                            await model.hotRefreshProviderCatalog(providerID: provider.id)
                                        }
                                    } test: {
                                        pendingTestScope = .provider(provider)
                                    } delete: {
                                        providerToDelete = provider
                                    }
                                    .tag(provider.id)
                                    .id(provider.id)
                                }
                            }
                            .listStyle(.sidebar)
                            .scrollContentBackground(.hidden)
                            .contentMargins(.bottom, 16, for: .scrollContent)
                            .background(MHDesign.surface.opacity(0.72))
                            .task(id: selectedProviderID) {
                                guard let selectedProviderID else { return }
                                try? await Task.sleep(for: .milliseconds(60))
                                providerListProxy.scrollTo(selectedProviderID, anchor: .center)
                            }
                        }
                        .frame(minWidth: 300, idealWidth: 336, maxWidth: 390)
                        .frame(maxHeight: .infinity, alignment: .top)

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
                    .frame(
                        width: splitProxy.size.width,
                        height: splitProxy.size.height,
                        alignment: .top
                    )
                    .background(MHDesign.elevatedSurface.opacity(0.96))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(MHDesign.border)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.065), radius: 18, y: 7)
                }
                .padding(.horizontal, MHDesign.pagePadding)
                .padding(.bottom, MHDesign.pagePadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if selectedProviderID == nil {
                #if DEBUG
                if ProcessInfo.processInfo.environment["MODELHUB_VISUAL_STRESS"] == "1" {
                    selectedProviderID = model.providers.last?.id
                    return
                }
                #endif
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
            Button(
                L10n.format(
                    "检测 %lld 个模型（文字请求可能计费）",
                    Int64(scope.modelCount(in: model.providers))
                )
            ) {
                switch scope {
                case .all:
                    model.startTestingAllModels()
                case .provider(let provider):
                    model.startTestingAllModels(providerID: provider.id)
                }
                pendingTestScope = nil
            }
            if scope.nativeModelCount(in: model.providers) > 0 {
                Button(
                    L10n.format(
                        "包含 %lld 个原生验证（可能计费）",
                        Int64(scope.nativeModelCount(in: model.providers))
                    )
                ) {
                    switch scope {
                    case .all:
                        model.startTestingAllModels(allowNativeProbe: true)
                    case .provider(let provider):
                        model.startTestingAllModels(
                            providerID: provider.id,
                            allowNativeProbe: true
                        )
                    }
                    pendingTestScope = nil
                }
            }
            Button("取消", role: .cancel) {
                pendingTestScope = nil
            }
        } message: { scope in
            Text(
                L10n.format(
                    "将检查 %lld 个模型。文字模型会各发送一次最多 1 token 的真实请求，供应商可能收费；此选项不会创建生成任务。选择包含原生验证后，还会对 %lld 个生成类模型各发送一次最小真实请求，可能逐模型计费。若供应商金丝雀遇到瞬态网络故障，系统会熔断并跳过其余模型，避免批量误隔离。成功且响应有效后才会解封。最多并发 3 个。",
                    Int64(scope.modelCount(in: model.providers)),
                    Int64(scope.nativeModelCount(in: model.providers))
                )
            )
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

    func nativeModelCount(in providers: [ProviderConfig]) -> Int {
        let selected: [ProviderConfig] = switch self {
        case .all: providers.filter(\.enabled)
        case .provider(let provider): [provider]
        }
        return selected.reduce(0) { count, provider in
            count + provider.models.filter {
                guard let nativeProtocol = ModelProbePolicy.nativeProtocol(
                    provider: provider,
                    model: $0
                ) else { return false }
                return nativeProtocol != .providerNative
            }.count
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderConfig
    let summary: ModelHealthSummary
    let hasAPIKey: Bool
    let credentialIssue: String?
    let isSelected: Bool
    let isHotRefreshing: Bool
    let edit: () -> Void
    let refresh: () -> Void
    let test: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            MHIconTile(
                symbol: provider.kind == .ollama ? "desktopcomputer" : "cloud",
                size: 38
            )
            .opacity(provider.enabled ? 1 : 0.56)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(provider.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    StatusBadge(
                        text: mhLocalized(provider.enabled ? "已启用" : "已停用"),
                        active: provider.enabled,
                        onAccent: isSelected
                    )
                }
                Text(mhLocalized(provider.kind.displayName))
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.76) : Color.secondary)
                Label(
                    provider.kind.needsAPIKey
                        ? (credentialIssue == nil
                            ? (hasAPIKey ? "密钥已保存" : "缺少密钥")
                            : "凭证类型不匹配")
                        : "无需密钥",
                    systemImage: credentialIssue == nil
                        ? (hasAPIKey || !provider.kind.needsAPIKey
                            ? "key.fill"
                            : "key.slash")
                        : "exclamationmark.key.fill"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(
                    isSelected
                        ? Color.white.opacity(0.84)
                        : (credentialIssue == nil
                            && (hasAPIKey || !provider.kind.needsAPIKey)
                                ? Color.green
                                : Color.orange)
                )
                HStack(spacing: 6) {
                    AvailabilityCountBadge(
                        value: summary.available,
                        label: "可用",
                        status: .available,
                        onAccent: isSelected
                    )
                    AvailabilityCountBadge(
                        value: summary.unavailable,
                        label: "已隔离",
                        status: .unavailable,
                        onAccent: isSelected
                    )
                    if summary.unknown > 0 {
                        AvailabilityCountBadge(
                            value: summary.unknown,
                            label: "待验证 · 已隔离",
                            status: .unknown,
                            onAccent: isSelected
                        )
                    }
                }
                if summary.configurationRequired > 0 || summary.unsupported > 0 {
                    HStack(spacing: 6) {
                        AvailabilityCountBadge(
                            value: summary.configurationRequired,
                            label: "需密钥",
                            status: .configurationRequired,
                            onAccent: isSelected
                        )
                        AvailabilityCountBadge(
                            value: summary.unsupported,
                            label: "待适配",
                            status: .unsupported,
                            onAccent: isSelected
                        )
                    }
                }
            }

            Spacer()

            Menu {
                Button("编辑供应商与密钥", action: edit)
                Button(action: refresh) {
                    Label("热更新模型", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isHotRefreshing || credentialIssue != nil)
                Button("测试全部模型", action: test)
                    .disabled(credentialIssue != nil)
                Button("删除", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("\(provider.name) 操作")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
        .background(MHDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(MHDesign.accent.opacity(0.16))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TransientHealthRecoveryBanner: View {
    let count: Int
    let recover: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("发现 %d 条可恢复的瞬态网络故障记录", count))
                    .font(.subheadline.weight(.semibold))
                Text("恢复后仅变为待验证并继续隔离；不会调用供应商，也不会直接标记为可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("恢复为待验证", action: recover)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.orange.opacity(0.2))
        }
    }
}

private struct ProviderVerificationBlockerBanner: View {
    let pendingCount: Int
    let proxyGuidance: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format(
                    "本轮未完成真实可用性验证：%d 个模型仍为待验证",
                    pendingCount
                ))
                .font(.subheadline.weight(.semibold))
                Text("供应商金丝雀在重试后仍遇到瞬态 TLS/网络故障，系统已熔断并跳过后续请求，避免把整批模型误判为不可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(proxyGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.orange.opacity(0.2))
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ModelHealthActivityPanel: View {
    let activities: [ModelHealthActivity]
    let providers: [ProviderConfig]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("最近健康活动", systemImage: "waveform.path.ecg.rectangle")
                .font(.subheadline.weight(.semibold))

            ForEach(activities) { activity in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: activity.kind == .probe
                        ? "checkmark.arrow.trianglehead.counterclockwise"
                        : "arrow.uturn.backward.circle")
                        .foregroundStyle(activity.kind == .probe ? MHDesign.accent : .orange)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary(for: activity))
                            .font(.caption.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(activity.completedAt, style: .relative)
                            Text("·")
                            Text(L10n.format("关联 ID %@", String(activity.id.uuidString.prefix(8))))
                            if let circuitProviders = circuitProviderNames(for: activity) {
                                Text("·")
                                Text(L10n.format("熔断：%@", circuitProviders))
                            }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .background(MHDesign.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(MHDesign.border)
        }
    }

    private func summary(for activity: ModelHealthActivity) -> String {
        if activity.kind == .transientRecovery {
            return L10n.format(
                "恢复 %d 条为待验证，仍保持隔离",
                activity.recoveredToUnknown
            )
        }
        let state = activity.cancelled ? mhLocalized("已停止") : mhLocalized("已完成")
        return L10n.format(
            "%@ %d/%d · 可用 %d · 失败/隔离 %d · 未探测/需处理 %d · 重试 %d · 保留可用 %d · 瞬态故障 %d · 熔断跳过 %d",
            state,
            activity.completed,
            activity.total,
            activity.available,
            activity.unavailable,
            activity.skipped,
            activity.retryAttempts,
            activity.preservedAvailable,
            activity.transientFailures,
            activity.circuitSkipped
        )
    }

    private func circuitProviderNames(for activity: ModelHealthActivity) -> String? {
        let names = activity.circuitOpenedProviderIDs.compactMap { providerID in
            providers.first { $0.id == providerID }?.name
        }
        return names.isEmpty ? nil : names.joined(separator: "、")
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
    @State private var pendingNativeTest: NativeTestRequest?
    @State private var showingTransientRecoveryConfirmation = false
    @State private var proxyAssignmentContext: ProxyAssignmentContext?

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

    private var recoverableTransientHealthCount: Int {
        model.recoverableTransientHealthCount(providerID: provider.id)
    }

    private var recentHealthActivities: [ModelHealthActivity] {
        model.recentModelHealthActivities(providerID: provider.id, limit: 3)
    }

    private var circuitBlockingActivity: ModelHealthActivity? {
        ModelTestCircuitDiagnostics.latestBlockingActivity(
            providerID: provider.id,
            activities: model.recentModelHealthActivities(providerID: provider.id, limit: 50)
        )
    }

    private var pendingModelIDs: [String] {
        provider.models.filter {
            model.healthRecord(providerID: provider.id, model: $0)?.status == .unknown
        }
    }

    private var pendingProxyAssignmentCount: Int {
        pendingModelIDs.lazy.filter {
            model.assignedProxyNodeID(providerID: provider.id, model: $0) != nil
        }.count
    }

    private var proxyRecoveryGuidance: String {
        if model.proxySubscriptionNodes.isEmpty {
            return mhLocalized("当前没有可用订阅节点；请先进入“代理订阅”更新节点。")
        }
        if !model.modelProxyEnabled {
            return mhLocalized("当前模型专用代理未启用。选择节点并应用后会同时启用，仅影响明确分配的模型。")
        }
        if pendingProxyAssignmentCount == 0 {
            return mhLocalized("当前待验证模型未分配订阅节点，仍会走直连；请选择节点后再复验。")
        }
        if pendingProxyAssignmentCount < pendingModelIDs.count {
            return L10n.format(
                "已有 %d/%d 个待验证模型分配节点；可继续补充分配后分批复验。",
                pendingProxyAssignmentCount,
                pendingModelIDs.count
            )
        }
        return mhLocalized("待验证模型已分配订阅节点；确认代理运行后可分批发起真实复验。")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        providerIdentity
                            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                        providerActions
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        providerIdentity
                        providerActions
                    }
                }

                if recoverableTransientHealthCount > 0 {
                    TransientHealthRecoveryBanner(
                        count: recoverableTransientHealthCount
                    ) {
                        showingTransientRecoveryConfirmation = true
                    }
                }

                if summary.unknown > 0, circuitBlockingActivity != nil {
                    ProviderVerificationBlockerBanner(
                        pendingCount: summary.unknown,
                        proxyGuidance: proxyRecoveryGuidance,
                        actionTitle: model.proxySubscriptionNodes.isEmpty
                            ? mhLocalized("前往代理订阅")
                            : mhLocalized("选择节点并复验")
                    ) {
                        if model.proxySubscriptionNodes.isEmpty {
                            model.selection = .proxy
                        } else {
                            proxyAssignmentContext = ProxyAssignmentContext(
                                providerID: provider.id,
                                scope: .pending
                            )
                        }
                    }
                }

                if !recentHealthActivities.isEmpty {
                    ModelHealthActivityPanel(
                        activities: recentHealthActivities,
                        providers: model.providers
                    )
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
            .padding(22)
            .background {
                LinearGradient(
                    colors: [MHDesign.accent.opacity(0.055), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

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
                                categories: ModelCategory.infer(
                                    model: modelName,
                                    capabilities: provider.modelProfiles?[modelName]?.capabilities ?? []
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
                                beginTest(modelName: modelName)
                            }
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "测试原生协议？",
            isPresented: Binding(
                get: { pendingNativeTest != nil },
                set: { if !$0 { pendingNativeTest = nil } }
            )
        ) {
            Button("继续测试（可能产生费用）") {
                guard let request = pendingNativeTest else { return }
                pendingNativeTest = nil
                Task {
                    _ = await model.testModel(
                        providerID: request.providerID,
                        model: request.model,
                        allowNativeProbe: true
                    )
                }
            }
            Button("取消", role: .cancel) { pendingNativeTest = nil }
        } message: {
            if let request = pendingNativeTest {
                Text("将向 \(provider.name) 的 \(request.protocol.displayName) 原生接口发送一次最小真实请求。视频、图像、音乐或语音供应商可能按请求计费。")
            }
        }
        .confirmationDialog(
            "恢复瞬态网络故障记录？",
            isPresented: $showingTransientRecoveryConfirmation
        ) {
            Button(L10n.format("恢复 %d 条为待验证", recoverableTransientHealthCount)) {
                model.recoverTransientNetworkHealth(providerID: provider.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会撤销由明确 URL 瞬态错误造成的旧隔离记录。恢复后的模型仍处于待验证和隔离状态；不会调用供应商，不会产生费用，也不会恢复路由。")
        }
        .sheet(item: $proxyAssignmentContext) { context in
            ProxyNodeAssignmentView(context: context)
                .environmentObject(model)
        }
    }

    private var providerIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.name)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(provider.name)
            Text("\(summary.total) 个模型 · 聊天模型在线检测；生成模型未通过原生验证时保持隔离")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerActions: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await model.hotRefreshProviderCatalog(providerID: provider.id)
                }
            } label: {
                if model.isHotRefreshingProviderCatalog(provider.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 16)
                } else {
                    Label("热更新模型", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.bordered)
            .disabled(
                model.isHotRefreshingProviderCatalog(provider.id)
                    || model.isTestingModels
            )
            .help("从已保存的精确模型目录增量合并，不重启服务；新增模型保持隔离，现有状态不变。")

            Button("编辑与密钥", action: edit)
                .buttonStyle(.bordered)

            Button {
                proxyAssignmentContext = ProxyAssignmentContext(
                    providerID: provider.id,
                    scope: .pending
                )
            } label: {
                Label("代理复验待验证", systemImage: "network.badge.shield.half.filled")
            }
            .buttonStyle(.bordered)
            .disabled(
                summary.unknown == 0
                    || model.proxySubscriptionNodes.isEmpty
                    || model.isTestingModels
            )
            .help(model.proxySubscriptionNodes.isEmpty
                ? "请先在“代理订阅”中成功读取节点。"
                : "选择订阅节点，批量分配给待验证模型；只会批量复验文字模型。")

            Button {
                testAll()
            } label: {
                Label("测试全部", systemImage: "checkmark.arrow.trianglehead.counterclockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isTestingModels || provider.models.isEmpty)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func beginTest(modelName: String) {
        guard let nativeProtocol = ModelProbePolicy.nativeProtocol(
            provider: provider,
            model: modelName
        ), nativeProtocol != .providerNative else {
            Task {
                _ = await model.testModel(providerID: provider.id, model: modelName)
            }
            return
        }
        pendingNativeTest = NativeTestRequest(
            providerID: provider.id,
            model: modelName,
            protocol: nativeProtocol
        )
    }
}

private struct NativeTestRequest {
    let providerID: UUID
    let model: String
    let `protocol`: ModelNativeProtocol
}

private struct ModelHealthRow: View {
    @EnvironmentObject private var appModel: AppModel
    let providerID: UUID
    let modelName: String
    let nativeProtocol: ModelNativeProtocol?
    let categories: Set<ModelCategory>
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
                HStack(spacing: 5) {
                    ForEach(ModelCategory.allCases.filter { categories.contains($0) }) { category in
                        Label(category.displayName, systemImage: category.icon)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(category.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(category.color.opacity(0.1), in: Capsule())
                    }
                }
                HStack(spacing: 8) {
                    Text(isTesting ? "测试中" : status.title)
                    if status == .available {
                        Label(
                            record?.statusCode.map { (200..<300).contains($0) } == true
                                ? "在线验真" : "本地信任",
                            systemImage: record?.statusCode.map { (200..<300).contains($0) } == true
                                ? "checkmark.seal.fill" : "hand.raised.fill"
                        )
                        .foregroundStyle(
                            record?.statusCode.map { (200..<300).contains($0) } == true
                                ? .green : .orange
                        )
                    }
                    if let record {
                        if let latency = record.latencyMilliseconds {
                            Text("\(latency) ms")
                        }
                        Text(record.checkedAt, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if status.isQuarantined, let reason = quarantineReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(status == .unavailable ? Color.red : Color.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(quarantineHelpText(reason: reason))
                        .accessibilityLabel(L10n.format("隔离原因：%@", reason))
                } else if let detail = record?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(detail)
                }
            }

            Spacer()

            if status.isQuarantined {
                Button(action: test) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(isTesting || appModel.isTestingModels)
                .help(nativeProtocol == nil ? "重新测试已隔离模型 \(modelName)" : "重新测试 \(modelName) 的原生协议（可能产生费用）")
                .accessibilityLabel("重新测试模型 \(modelName)")
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
        .accessibilityLabel(accessibilityDescription)
    }

    private var quarantineReason: String? {
        guard let cause = record?.quarantineCause else {
            return status.isQuarantined ? mhLocalized("尚未完成真实可用性验证") : nil
        }
        switch cause {
        case .notVerified:
            if let record,
               ModelHealthRecoveryPolicy.isRecoveredPendingVerification(record)
            {
                return mhLocalized("瞬态网络故障记录已恢复，等待真实请求复验")
            }
            return mhLocalized("尚未完成真实可用性验证")
        case .missingCredential:
            return mhLocalized("缺少 API Key，未向供应商发起请求")
        case .invalidCredential:
            if let edition = bailianEditionName {
                return L10n.format("%@ API Key 无效、已过期，或与当前 Base URL 不匹配", edition)
            }
            return mhLocalized("API Key 无效或已过期")
        case .insufficientPermission:
            return mhLocalized("当前凭证无权访问此模型")
        case .invalidRequest:
            return mhLocalized("请求格式、参数或模型能力不匹配")
        case .endpointOrModelNotFound:
            if let edition = bailianEditionName {
                return L10n.format("%@不支持该模型，或 Base URL 与此版本的 API Key 不匹配", edition)
            }
            return mhLocalized("上游未找到该模型，或精确调用端点不匹配")
        case .modelAccessNotConfigured:
            return mhLocalized("官方能力目录确认支持；当前 API Key 所属地域、业务空间或推理端点未开放该模型")
        case .requestTimedOut:
            return mhLocalized("上游请求超时，请检查网络或稍后重试")
        case .rateLimitedOrOutOfQuota:
            return mhLocalized("请求受限或账户配额不足")
        case .upstreamFailure:
            return mhLocalized("供应商服务暂时异常")
        case .networkFailure:
            return mhLocalized("网络连接失败，未能完成上游验证")
        case .nativeVerificationRequired:
            return mhLocalized("原生生成协议尚未完成真实验证")
        case .unsupportedProtocol:
            return mhLocalized("当前版本尚未适配此模型协议")
        case .unknownFailure:
            return mhLocalized("最近一次验证失败，请查看技术详情并重新测试")
        }
    }

    private var bailianEditionName: String? {
        guard let kind = appModel.providers.first(where: { $0.id == providerID })?.kind,
              kind.isBailian
        else { return nil }
        return mhLocalized(kind.displayName)
    }

    private func quarantineHelpText(reason: String) -> String {
        guard let detail = record?.detail.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty
        else { return reason }
        return L10n.format("隔离原因：%@\n技术详情：%@", reason, detail)
    }

    private var accessibilityDescription: String {
        let summary = "\(modelName)，\(isTesting ? mhLocalized("测试中") : status.title)"
        guard let quarantineReason else { return summary }
        return L10n.format("%@，隔离原因：%@", summary, quarantineReason)
    }
}

private struct AvailabilityCountBadge: View {
    let value: Int
    let label: String
    let status: ModelAvailability
    var onAccent = false

    var body: some View {
        Label("\(value) \(label)", systemImage: status.icon)
            .font(.caption2)
            .foregroundStyle(onAccent ? Color.white : status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                onAccent ? Color.white.opacity(0.14) : status.color.opacity(0.1),
                in: Capsule()
            )
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
        case .musicGeneration: "music.note"
        case .videoGeneration: "video"
        case .speech: "waveform"
        case .transcription: "captions.bubble"
        case .embeddings: "point.3.filled.connected.trianglepath.dotted"
        case .reranking: "arrow.up.arrow.down"
        case .providerNative: "arrow.triangle.branch"
        }
    }
}

private extension ModelCategory {
    var icon: String {
        switch self {
        case .reasoning: "brain.head.profile"
        case .text: "text.alignleft"
        case .image: "photo"
        case .music: "music.note"
        case .video: "video"
        }
    }

    var color: Color {
        switch self {
        case .reasoning: .orange
        case .text: .blue
        case .image: .purple
        case .music: .pink
        case .video: .teal
        }
    }
}

private struct ProviderModelImportPreview: Identifiable {
    let id = UUID()
    let models: [String]
    let prices: [String: ProviderModelPrice]
    let endpointURLs: [String: String]
    var capabilityDetails: [String: ModelCapabilityDetails] = [:]
    let description: String
    var preselectAll = true
}

private struct ProviderEditorBadge: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
            .overlay { Capsule().stroke(color.opacity(0.18)) }
            .accessibilityElement(children: .combine)
    }
}

private struct ProviderEditorSectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(MHDesign.accent)
                .frame(width: 26, height: 26)
                .background(MHDesign.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            Text(mhLocalized(title))
                .font(.headline)
        }
        .padding(.top, 4)
    }
}

private struct ProviderEditorNotice: View {
    let message: String
    let isError: Bool

    var body: some View {
        Label(
            message,
            systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(isError ? Color.orange : Color.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isError ? Color.orange : Color.green).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke((isError ? Color.orange : Color.green).opacity(0.18))
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

enum ProviderEditorValidation {
    static func isSavable(
        provider: ProviderConfig,
        endpointsText: String,
        requiresBailianReplacementKey: Bool
    ) -> Bool {
        guard let baseURL = URLComponents(string: provider.baseURL) else { return false }
        return !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ProviderEndpointSecurity.isSafeConfigurationURL(baseURL)
            && (try? ProviderEndpointEditorCodec.records(from: endpointsText)) != nil
            && BailianEndpointPolicy.validationMessage(for: provider) == nil
            && !requiresBailianReplacementKey
    }
}

struct ProviderEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ProviderConfig
    @State private var apiKey: String
    @State private var modelsText: String
    @State private var endpointsText: String
    @State private var modelCatalogURL: String
    @State private var endpointValidationMessage = ""
    @State private var testResult = ""
    @State private var isTesting = false
    @State private var isFetchingCatalog = false
    @State private var catalogResultText = ""
    @State private var catalogResultIsError = false
    @State private var pricingQuery = ""
    @State private var pricingResultText = ""
    @State private var pricingResultIsError = false
    @State private var isRefreshingProviderPrices = false
    @State private var pendingImport: ProviderModelImportPreview?
    @State private var showingDeleteKeyConfirmation = false
    @State private var pendingNativeProtocol: ModelNativeProtocol?
    private let initialKind: ProviderKind

    init(provider: ProviderConfig?) {
        var initial = provider ?? ProviderConfig(
            name: "通用兼容供应商",
            kind: .unifiedCompatible,
            baseURL: ""
        )
        if let preset = ProviderConnectionPresets.preset(for: initial.kind) {
            initial = preset.applying(to: initial, mode: .fillMissing)
        }
        initialKind = initial.kind
        _provider = State(initialValue: initial)
        _apiKey = State(initialValue: "")
        _modelsText = State(initialValue: initial.models.joined(separator: "\n"))
        _modelCatalogURL = State(initialValue: initial.endpointURLs[
            ProviderEndpointRecord.key(for: .modelCatalog)
        ] ?? "")
        let operationEndpoints = initial.endpointURLs.filter {
            $0.key != ProviderEndpointRecord.key(for: .modelCatalog)
        }
        _endpointsText = State(
            initialValue: ProviderEndpointEditorCodec.text(from: operationEndpoints)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                MHIconTile(
                    symbol: provider.kind == .ollama ? "desktopcomputer" : "server.rack",
                    size: 50,
                    emphasized: true
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.name.isEmpty ? "添加供应商" : provider.name)
                        .font(.title2.weight(.semibold))
                    Text("配置精确端点、钥匙串凭证并拉取模型名录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        ProviderEditorBadge(
                            icon: provider.enabled ? "checkmark.circle.fill" : "pause.circle.fill",
                            text: mhLocalized(provider.enabled ? "已启用" : "已停用"),
                            color: provider.enabled ? .green : .secondary
                        )
                        ProviderEditorBadge(
                            icon: credentialValidationMessage == nil
                                ? (hasStoredAPIKey ? "key.fill" : "key.slash")
                                : "exclamationmark.key.fill",
                            text: credentialStatusText,
                            color: credentialValidationMessage == nil && hasStoredAPIKey
                                ? .green
                                : .orange
                        )
                        ProviderEditorBadge(
                            icon: "square.stack.3d.up.fill",
                            text: "\(parsedModels.count)",
                            color: MHDesign.accent
                        )
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    provider.models = parsedModels
                    guard applyExplicitEndpoints() else { return }
                    if model.saveProvider(provider, apiKey: apiKey) {
                        apiKey = ""
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(MHDesign.elevatedSurface.opacity(0.94))

            Rectangle()
                .fill(MHDesign.border)
                .frame(height: 1)

            Form {
                Section {
                    TextField("名称", text: $provider.name)
                    Picker("供应商类型", selection: $provider.kind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(mhLocalized(kind.displayName)).tag(kind)
                        }
                    }
                    .onChange(of: provider.kind) { oldValue, newValue in
                        let defaultNames = [
                            oldValue.displayName,
                            "阿里云百炼",
                            "阿里云百炼 / Qwen",
                            "阿里云百炼企业版（团队版）",
                            "千问AI平台",
                            "MiniMax",
                        ]
                        if defaultNames.contains(provider.name) || provider.name.isEmpty {
                            provider.name = newValue.displayName
                        }
                        applyConnectionPreset(newValue, mode: .replaceURLs)
                    }
                    TextField("Base URL", text: $provider.baseURL)
                        .font(.system(.body, design: .monospaced))
                    if ProviderConnectionPresets.preset(for: provider.kind) != nil {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Label(
                                hasPresetModelCatalog
                                    ? "已内置该供应商的官方连接预设；通常只需填写 API Key 即可拉取模型并使用支持的协议。"
                                    : "已自动填入该供应商可确定的 Base URL 与请求端点；由于官方未提供可仅凭该 API Key 读取的唯一模型名录，模型 ID 仍需手工添加。",
                                systemImage: "checkmark.shield.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.green)
                            Spacer()
                            Button("恢复官方 URL") {
                                applyConnectionPreset(provider.kind, mode: .replaceURLs)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("通用兼容协议没有唯一官方地址，需要手动填写完整 Base URL、模型目录和适用端点；ModelHub 不会猜测路径。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let description = provider.kind.bailianEditionDescription,
                       let recommendedURL = provider.kind.recommendedBaseURL
                    {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(mhLocalized(provider.kind.displayName), systemImage: "building.2.crop.circle")
                                .font(.subheadline.weight(.semibold))
                            Text(mhLocalized(description))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(recommendedURL)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text("切换千问AI平台类型时会自动应用对应的 Base URL 与聊天端点；仅在已保存密钥与目标计费体系明确兼容时复用，否则必须输入目标类型的专属 API Key。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let message = bailianBaseURLValidationMessage {
                                Label(mhLocalized(message), systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .background(MHDesign.insetSurface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(MHDesign.border)
                        }
                    }
                    Toggle("启用此供应商", isOn: $provider.enabled)
                } header: {
                    ProviderEditorSectionHeader(icon: "slider.horizontal.3", title: "基本信息")
                }

                Section {
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
                    if requiresBailianReplacementKey {
                        Label(
                            credentialValidationMessage
                                ?? "千问AI平台版本已变更。请输入新版本专属 API Key；原凭证不会被自动复用。",
                            systemImage: "key.horizontal.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if provider.kind == .anthropic {
                        TextField("API 版本（可选）", text: $provider.apiVersion)
                    }
                } header: {
                    ProviderEditorSectionHeader(icon: "key.fill", title: "凭证")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("模型名录拉取")
                            .font(.headline)
                        TextField(
                            "精确模型名录 URL（不会使用 Base URL）",
                            text: $modelCatalogURL
                        )
                        .font(.system(.body, design: .monospaced))
                        if modelCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let suggestion = ProviderModelCatalogSuggestions.suggestion(for: provider)
                        {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Button("填入已核验官方模型目录") {
                                    modelCatalogURL = suggestion.exactURL.absoluteString
                                    catalogResultText = ""
                                }
                                .buttonStyle(.bordered)
                                Text(
                                    mhLocalized(suggestion.scope)
                                        + mhLocalized(
                                            suggestion.canReturnTokenPrices
                                                ? "；目录同时提供可自动同步的 Token 价格。"
                                                : "；该目录未公开可直接同步的 Token 价格。"
                                        )
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if modelCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("该供应商暂无已核验的公开模型目录地址，请从供应商官方文档复制完整 URL；ModelHub 不会猜测路径。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button {
                                fetchModelCatalog()
                            } label: {
                                if isFetchingCatalog {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("拉取模型名录", systemImage: "arrow.down.circle")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                isFetchingCatalog
                                    || modelCatalogURL.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                            Button {
                                selectCSVFile()
                            } label: {
                                Label("导入 CSV", systemImage: "doc.badge.plus")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isFetchingCatalog)
                        }
                        if !catalogResultText.isEmpty {
                            ProviderEditorNotice(
                                message: catalogResultText,
                                    isError: catalogResultIsError
                                )
                            }
                        Text("内置供应商会自动带出已核验的完整名录地址；通用兼容类型才需要手工填写。运行时不会使用 Base URL 猜测路径。凭证通过请求头发送，拉取结果需预览确认后才会合并。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("CSV 支持 UTF-8、UTF-16 与 Excel 分隔符声明。必填列：model（也支持 model_id、模型名称）；可选列：endpoint、各协议端点、input_price、output_price、request_price、price_source。Token 价格单位为美元/百万 Token，request_price 为美元/次。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    TextEditor(text: $modelsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(MHDesign.insetSurface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(MHDesign.border) }
                    Text("共 \(parsedModels.count) 个模型；每行一个名称。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    ProviderEditorSectionHeader(icon: "square.stack.3d.up.fill", title: "模型名称")
                }

                Section {
                    HStack(spacing: 10) {
                        TextField("搜索模型", text: $pricingQuery)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            refreshProviderPrices()
                        } label: {
                            if isRefreshingProviderPrices {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("一键同步官方价格", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            isRefreshingProviderPrices
                                || modelCatalogURL.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                                || parsedModels.isEmpty
                                || pricingAvailabilityReason != nil
                        )
                    }
                    if !pricingResultText.isEmpty {
                        ProviderEditorNotice(
                            message: pricingResultText,
                            isError: pricingResultIsError
                        )
                    }
                    Text("自动价格只读取供应商自身模型目录明确返回的机器可读金额与单位；不会抓取第三方价格、不会猜价。所有模型都可以在下方手动配置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let reason = pricingAvailabilityReason {
                        Label(mhLocalized(reason), systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVStack(spacing: 8) {
                        ForEach(filteredPricingModels, id: \.self) { modelName in
                            ModelPricingEditorRow(
                                modelName: modelName,
                                profile: pricingProfileBinding(for: modelName)
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    if matchingPricingModelCount > filteredPricingModels.count {
                        Text(
                            L10n.format(
                                "为保持界面流畅，当前显示前 %lld 个匹配模型；输入更精确的名称可配置其余模型。",
                                Int64(filteredPricingModels.count)
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    ProviderEditorSectionHeader(icon: "dollarsign.circle.fill", title: "费用管理")
                }

                Section {
                    TextEditor(text: $endpointsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(MHDesign.insetSurface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(MHDesign.border) }
                    Text("每行格式：端点类型|模型名称 = 完整 URL。运行时只使用这里或 Base URL 保存的完整地址，不补全任何路径；视频和音乐任务端点可使用 {task_id}。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !endpointValidationMessage.isEmpty {
                        Label(endpointValidationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    ProviderEditorSectionHeader(icon: "point.3.connected.trianglepath.dotted", title: "显式请求端点")
                }

                Section {
                    Toggle(
                        "维护已核实的隐私元数据",
                        isOn: Binding(
                            get: { provider.privacyProfile != nil },
                            set: { provider.privacyProfile = $0 ? (provider.privacyProfile ?? .init()) : nil }
                        )
                    )
                    if provider.privacyProfile != nil {
                        Picker(
                            "数据处理地区",
                            selection: Binding(
                                get: { provider.privacyProfile?.dataRegion ?? .unknown },
                                set: { provider.privacyProfile?.dataRegion = $0 }
                            )
                        ) {
                            ForEach(ProviderDataRegion.allCases) { region in
                                Text(region.displayName).tag(region)
                            }
                        }
                        Toggle(
                            "供应商明确承诺零数据留存",
                            isOn: Binding(
                                get: { provider.privacyProfile?.zeroDataRetention ?? false },
                                set: { provider.privacyProfile?.zeroDataRetention = $0 }
                            )
                        )
                        Picker(
                            "是否可能用于训练",
                            selection: Binding<Int>(
                                get: {
                                    guard let value = provider.privacyProfile?.mayUseForTraining else { return -1 }
                                    return value ? 1 : 0
                                },
                                set: {
                                    provider.privacyProfile?.mayUseForTraining = $0 < 0 ? nil : $0 == 1
                                }
                            )
                        ) {
                            Text("未核实").tag(-1)
                            Text("明确不会").tag(0)
                            Text("可能会").tag(1)
                        }
                        TextField(
                            "最长留存天数（未知留空）",
                            value: Binding(
                                get: { provider.privacyProfile?.retentionDays ?? 0 },
                                set: { provider.privacyProfile?.retentionDays = $0 >= 0 ? $0 : nil }
                            ),
                            format: .number
                        )
                        TextField(
                            "政策来源 URL 或核实说明",
                            text: Binding(
                                get: { provider.privacyProfile?.policySource ?? "" },
                                set: {
                                    provider.privacyProfile?.policySource = String($0.prefix(1_000))
                                    provider.privacyProfile?.verifiedAt = .now
                                }
                            )
                        )
                        Text("未填写或未核实的数据不会被推测；严格工作区策略会按失败关闭排除此供应商。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    ProviderEditorSectionHeader(icon: "hand.raised.fill", title: "供应商隐私与数据边界")
                }

                Section {
                    HStack {
                        Button {
                            requestProviderTest()
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
                } header: {
                    ProviderEditorSectionHeader(icon: "waveform.path.ecg", title: "连接测试")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .mhPageBackground()
        .frame(width: 880, height: 900)
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
        .sheet(item: $pendingImport) { preview in
            ModelCatalogImportSheet(
                models: preview.models,
                description: preview.description,
                priceCount: preview.prices.count,
                endpointCount: preview.endpointURLs.count,
                preselectAll: preview.preselectAll
            ) { selected in
                mergeImportedSelection(selected, preview: preview)
            }
        }
        .confirmationDialog(
            "测试原生协议？",
            isPresented: Binding(
                get: { pendingNativeProtocol != nil },
                set: { if !$0 { pendingNativeProtocol = nil } }
            )
        ) {
            Button("继续测试（可能产生费用）") {
                pendingNativeProtocol = nil
                runProviderTest(allowNativeProbe: true)
            }
            Button("取消", role: .cancel) { pendingNativeProtocol = nil }
        } message: {
            if let nativeProtocol = pendingNativeProtocol {
                Text("将向 \(provider.name) 的 \(nativeProtocol.displayName) 原生接口发送一次最小真实请求。视频、图像、音乐或语音供应商可能按请求计费。")
            }
        }
    }

    private func requestProviderTest() {
        guard let firstModel = parsedModels.first,
              let nativeProtocol = ModelProbePolicy.nativeProtocol(
                  provider: provider,
                  model: firstModel
              ), nativeProtocol != .providerNative else {
            runProviderTest()
            return
        }
        pendingNativeProtocol = nativeProtocol
    }

    private func fetchModelCatalog() {
        guard !modelCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            catalogResultText = "请先填写精确的模型名录 URL。"
            catalogResultIsError = true
            return
        }
        guard applyExplicitEndpoints() else { return }
        provider.models = parsedModels
        Task {
            isFetchingCatalog = true
            catalogResultText = "正在请求模型名录…"
            catalogResultIsError = false
            defer { isFetchingCatalog = false }
            do {
                let result = try await model.fetchProviderModelCatalog(
                    for: provider,
                    enteredAPIKey: apiKey
                )
                let directlyCallable = ProviderModelCatalogMergePolicy.shouldAutomaticallyMerge(
                    provider: provider,
                    endpoint: result.endpoint
                )
                catalogResultText = "拉取到 \(result.models.count) 个模型、\(result.prices.count) 个价格、\(result.capabilityDetails.count) 组能力参数（\(result.pageCount) 页）· \(result.durationMilliseconds) ms"
                catalogResultIsError = false
                pendingImport = ProviderModelImportPreview(
                    models: result.models,
                    prices: result.prices,
                    endpointURLs: [:],
                    capabilityDetails: result.capabilityDetails,
                    description: directlyCallable
                        ? "拉取只代表供应商列出了这些模型，不代表已经通过真实调用验证。"
                        : "这是可部署参考目录，不代表模型名可直接调用。已默认不勾选；只应导入你已部署并拿到调用代码的项目。",
                    preselectAll: directlyCallable
                )
            } catch {
                pendingImport = nil
                catalogResultText = error.localizedDescription
                catalogResultIsError = true
            }
        }
    }

    private func selectCSVFile() {
        let panel = NSOpenPanel()
        panel.title = mhLocalized("导入 CSV")
        panel.prompt = mhLocalized("导入")
        panel.message = mhLocalized("请选择一个 CSV 文件。导入前会先显示模型预览。")
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let fileURL = panel.url else { return }
            Task { @MainActor in
                importCSV(fileURL)
            }
        }
    }

    private func importCSV(_ fileURL: URL) {
        do {
            guard fileURL.pathExtension.lowercased() == "csv" else {
                catalogResultText = "只允许导入 .csv 格式的文件。"
                catalogResultIsError = true
                return
            }
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let imported = try ProviderModelCSVImporter.parse(
                data,
                source: fileURL.lastPathComponent
            )
            catalogResultText = "CSV 读取到 \(imported.models.count) 个模型、\(imported.prices.count) 个价格、\(imported.endpointURLs.count) 个精确端点；忽略 \(imported.duplicateCount) 个重复项"
            catalogResultIsError = false
            pendingImport = ProviderModelImportPreview(
                models: imported.models,
                prices: imported.prices,
                endpointURLs: imported.endpointURLs,
                description: "CSV 导入只会在确认后合并所选模型、价格和精确端点；不会修改 Base URL，也不会把模型标记为可用。"
            )
        } catch {
            pendingImport = nil
            catalogResultText = localizedCSVError(error)
            catalogResultIsError = true
        }
    }

    private func localizedCSVError(_ error: Error) -> String {
        guard let csvError = error as? ProviderModelCSVError else {
            return error.localizedDescription
        }
        switch csvError {
        case .fileTooLarge(let maximumBytes):
            return L10n.format(
                "CSV 文件超过安全上限（%lld MiB）",
                Int64(maximumBytes / 1_048_576)
            )
        case .invalidEncoding:
            return mhLocalized("CSV 文件必须使用 UTF-8 或 UTF-16 编码")
        case .malformedCSV(let row):
            return L10n.format("CSV 第 %lld 行的引号格式不完整", Int64(row))
        case .missingHeader:
            return mhLocalized("CSV 文件缺少表头")
        case .missingModelColumn:
            return mhLocalized("CSV 表头必须包含 model 或 模型名称 列")
        case .missingModels:
            return mhLocalized("CSV 文件中没有可导入的模型")
        case .tooManyRows(let maximum):
            return L10n.format("CSV 模型数量超过安全上限（%lld）", Int64(maximum))
        case .invalidModel(let row):
            return L10n.format(
                "CSV 第 %lld 行的模型名称为空、过长或包含控制字符",
                Int64(row)
            )
        case .invalidPrice(let row, let column):
            return L10n.format(
                "CSV 第 %lld 行的 %@ 必须是大于或等于 0 的数字",
                Int64(row),
                column
            )
        case .invalidEndpoint(let row, let column):
            return L10n.format(
                "CSV 第 %lld 行的 %@ 必须是无凭证的完整 HTTP(S) URL",
                Int64(row),
                column
            )
        }
    }

    private func mergeImportedSelection(
        _ selected: [String],
        preview: ProviderModelImportPreview
    ) -> Bool {
        let selectedIdentities = Set(selected.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        do {
            var endpointRecords = try ProviderEndpointEditorCodec.records(from: endpointsText)
            let selectedEndpoints = preview.endpointURLs.filter { key, _ in
                guard let separator = key.firstIndex(of: "|") else { return false }
                return selectedIdentities.contains(
                    String(key[key.index(after: separator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                )
            }
            endpointRecords.merge(selectedEndpoints) { _, imported in imported }
            endpointsText = ProviderEndpointEditorCodec.text(from: endpointRecords)

            let merged = ProviderModelCatalogImporter.merging(
                existing: parsedModels,
                imported: selected
            )
            modelsText = merged.joined(separator: "\n")
            provider.models = merged
            let selectedPrices = preview.prices.filter {
                selectedIdentities.contains(
                    $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }
            var noRoutes: [RouteConfig] = []
            let priceCount = ProviderModelPricingUpdater.apply(
                prices: selectedPrices,
                to: &provider,
                routes: &noRoutes
            )
            let selectedDetails = preview.capabilityDetails.filter {
                selectedIdentities.contains(
                    $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }
            let capabilityCount = ProviderModelCapabilityUpdater.apply(
                details: selectedDetails,
                to: &provider
            )
            endpointValidationMessage = ""
            catalogResultText = "已合并 \(selected.count) 个选择项、\(priceCount) 个价格、\(capabilityCount) 组能力参数、\(selectedEndpoints.count) 个精确端点，共 \(merged.count) 个模型；保存后生效"
            catalogResultIsError = false
            return true
        } catch {
            endpointValidationMessage = error.localizedDescription
            catalogResultText = error.localizedDescription
            catalogResultIsError = true
            return false
        }
    }

    private var filteredPricingModels: [String] {
        Array(matchingPricingModels.prefix(250))
    }

    private var matchingPricingModels: [String] {
        let query = pricingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return parsedModels }
        return parsedModels.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var matchingPricingModelCount: Int {
        matchingPricingModels.count
    }

    private func pricingProfileBinding(for modelName: String) -> Binding<TargetProfile> {
        Binding(
            get: {
                provider.modelProfiles?.first(where: {
                    $0.key.caseInsensitiveCompare(modelName) == .orderedSame
                })?.value ?? TargetProfile()
            },
            set: { proposed in
                var updated = proposed
                updated.inputCostPerMillionTokens = validPrice(updated.inputCostPerMillionTokens)
                updated.outputCostPerMillionTokens = validPrice(updated.outputCostPerMillionTokens)
                updated.requestCostUSD = validPrice(updated.requestCostUSD)
                if updated.hasKnownPrice {
                    if updated.pricingSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        updated.pricingSource = "手动配置"
                    }
                    updated.pricingUpdatedAt = .now
                }

                var profiles = provider.modelProfiles ?? [:]
                if let existing = profiles.keys.first(where: {
                    $0.caseInsensitiveCompare(modelName) == .orderedSame
                        && $0 != modelName
                }) {
                    profiles.removeValue(forKey: existing)
                }
                if updated.hasKnownPrice
                    || !updated.pricingSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    profiles[modelName] = updated
                } else {
                    profiles.removeValue(forKey: modelName)
                }
                provider.modelProfiles = profiles.isEmpty ? nil : profiles
            }
        )
    }

    private func validPrice(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 1_000_000 else { return nil }
        return value
    }

    private func refreshProviderPrices() {
        guard !modelCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pricingResultText = "请先填写供应商自身提供的精确模型名录 URL。"
            pricingResultIsError = true
            return
        }
        guard applyExplicitEndpoints() else {
            pricingResultText = endpointValidationMessage
            pricingResultIsError = true
            return
        }
        guard let endpoint = URL(string: modelCatalogURL) else {
            pricingResultText = "模型名录 URL 无效。"
            pricingResultIsError = true
            return
        }
        if case .unavailable(let reason) = ProviderModelCatalogPricingPolicy.availability(
            provider: provider,
            endpoint: endpoint
        ) {
            pricingResultText = reason
            pricingResultIsError = false
            return
        }
        provider.models = parsedModels
        Task {
            isRefreshingProviderPrices = true
            pricingResultText = "正在从供应商模型目录读取价格…"
            pricingResultIsError = false
            defer { isRefreshingProviderPrices = false }
            do {
                let result = try await model.fetchProviderModelCatalog(
                    for: provider,
                    enteredAPIKey: apiKey
                )
                guard !result.prices.isEmpty else {
                    pricingResultText = "供应商模型目录没有返回带明确单位的机器可读价格；现有费用未被修改。"
                    pricingResultIsError = true
                    return
                }
                var noRoutes: [RouteConfig] = []
                let updated = ProviderModelPricingUpdater.apply(
                    prices: result.prices,
                    to: &provider,
                    routes: &noRoutes
                )
                if updated > 0 {
                    pricingResultText = "已从供应商模型目录同步 \(updated) 个模型的价格；点击保存后生效。"
                    pricingResultIsError = false
                } else {
                    pricingResultText = "供应商返回了价格，但没有与当前模型名称匹配；现有费用未被修改。"
                    pricingResultIsError = true
                }
            } catch {
                pricingResultText = error.localizedDescription
                pricingResultIsError = true
            }
        }
    }

    private func runProviderTest(allowNativeProbe: Bool = false) {
        Task {
            isTesting = true
            provider.models = parsedModels
            guard applyExplicitEndpoints() else {
                isTesting = false
                return
            }
            if model.saveProvider(provider, apiKey: apiKey) {
                apiKey = ""
                testResult = await model.testProvider(
                    provider,
                    allowNativeProbe: allowNativeProbe
                )
            } else {
                testResult = "API Key 保存失败，请查看提示。"
            }
            isTesting = false
        }
    }

    private var hasStoredAPIKey: Bool {
        model.hasAPIKey(for: provider)
    }

    private var credentialStatusText: String {
        if !provider.kind.needsAPIKey { return String(localized: "此供应商无需 API Key", locale: AppLanguage.saved.locale) }
        if credentialValidationMessage != nil {
            return mhLocalized("凭证类型不匹配")
        }
        return mhLocalized(hasStoredAPIKey ? "钥匙串中已保存 API Key" : "尚未保存 API Key")
    }

    private var credentialValidationMessage: String? {
        model.providerCredentialValidationMessage(
            for: provider,
            enteredAPIKey: apiKey
        )
    }

    private var parsedModels: [String] {
        modelsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var isValid: Bool {
        var draft = provider
        draft.endpointURLs = [:]
        return ProviderEditorValidation.isSavable(
            provider: draft,
            endpointsText: endpointsText,
            requiresBailianReplacementKey: requiresBailianReplacementKey
        )
    }

    private var hasPresetModelCatalog: Bool {
        ProviderConnectionPresets.preset(for: provider.kind)?.endpointURLs[
            ProviderEndpointRecord.key(for: .modelCatalog)
        ] != nil
    }

    private var requiresBailianReplacementKey: Bool {
        credentialValidationMessage != nil
            || model.providerCredentialRequiresReplacement(
                from: initialKind,
                to: provider,
                enteredAPIKey: apiKey
            )
    }

    private var pricingAvailabilityReason: String? {
        guard let endpoint = URL(
            string: modelCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return nil }
        if case .unavailable(let reason) = ProviderModelCatalogPricingPolicy.availability(
            provider: provider,
            endpoint: endpoint
        ) {
            return reason
        }
        return nil
    }

    private var bailianBaseURLValidationMessage: String? {
        var baseOnly = provider
        baseOnly.endpointURLs = [:]
        return BailianEndpointPolicy.validationMessage(for: baseOnly)
    }

    private func applyConnectionPreset(
        _ kind: ProviderKind,
        mode: ProviderConnectionPresetApplicationMode
    ) {
        guard let preset = ProviderConnectionPresets.preset(for: kind) else {
            if mode == .replaceURLs {
                provider.baseURL = ""
                provider.endpointURLs = [:]
                modelCatalogURL = ""
                endpointsText = ""
            }
            endpointValidationMessage = ""
            catalogResultText = ""
            return
        }
        provider = preset.applying(to: provider, mode: mode)
        let catalogKey = ProviderEndpointRecord.key(for: .modelCatalog)
        modelCatalogURL = provider.endpointURLs[catalogKey] ?? ""
        endpointsText = ProviderEndpointEditorCodec.text(
            from: provider.endpointURLs.filter { $0.key != catalogKey }
        )
        endpointValidationMessage = ""
        catalogResultText = ""
    }

    @discardableResult
    private func applyExplicitEndpoints() -> Bool {
        do {
            provider.endpointURLs = try ProviderEndpointEditorCodec.records(from: endpointsText)
            let catalog = modelCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !catalog.isEmpty {
                let catalogRecord = "\(ProviderEndpointKind.modelCatalog.rawValue) = \(catalog)"
                let validated = try ProviderEndpointEditorCodec.records(from: catalogRecord)
                provider.endpointURLs.merge(validated) { _, new in new }
            }
            endpointValidationMessage = ""
            return true
        } catch {
            endpointValidationMessage = error.localizedDescription
            return false
        }
    }
}

private struct ModelPricingEditorRow: View {
    let modelName: String
    @Binding var profile: TargetProfile
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("输入价格")
                        TextField(
                            "美元/百万 Token",
                            value: $profile.inputCostPerMillionTokens,
                            format: .number.precision(.fractionLength(0...8))
                        )
                        Text("输出价格")
                        TextField(
                            "美元/百万 Token",
                            value: $profile.outputCostPerMillionTokens,
                            format: .number.precision(.fractionLength(0...8))
                        )
                    }
                    GridRow {
                        Text("单次调用价格")
                        TextField(
                            "美元/次",
                            value: $profile.requestCostUSD,
                            format: .number.precision(.fractionLength(0...8))
                        )
                        Text("价格来源")
                        TextField("供应商目录或手动配置", text: $profile.pricingSource)
                    }
                }
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    if let date = profile.pricingUpdatedAt {
                        Label(
                            "更新于 \(date.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "clock"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("清除费用", role: .destructive) {
                        profile.inputCostPerMillionTokens = nil
                        profile.outputCostPerMillionTokens = nil
                        profile.requestCostUSD = nil
                        profile.pricingSource = ""
                        profile.pricingUpdatedAt = nil
                    }
                    .buttonStyle(.borderless)
                    .disabled(!profile.hasKnownPrice && profile.pricingSource.isEmpty)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: profile.hasKnownPrice ? "dollarsign.circle.fill" : "dollarsign.circle")
                    .foregroundStyle(profile.hasKnownPrice ? Color.green : Color.secondary)
                Text(modelName)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .lineLimit(1)
                    .help(modelName)
                Spacer()
                Text(priceSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(profile.hasKnownPrice ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .padding(13)
        .background(MHDesign.elevatedSurface, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.07))
        }
        .accessibilityElement(children: .contain)
    }

    private var priceSummary: String {
        var parts: [String] = []
        if let input = profile.inputCostPerMillionTokens {
            parts.append("输入 $\(formatted(input))/M")
        }
        if let output = profile.outputCostPerMillionTokens {
            parts.append("输出 $\(formatted(output))/M")
        }
        if let request = profile.requestCostUSD {
            parts.append("$\(formatted(request))/次")
        }
        return parts.isEmpty ? mhLocalized("未配置费用") : parts.joined(separator: " · ")
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }
}

private struct ModelCatalogImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let models: [String]
    let description: String
    let priceCount: Int
    let endpointCount: Int
    let importSelection: ([String]) -> Bool
    @State private var query = ""
    @State private var selection: Set<String>

    init(
        models: [String],
        description: String,
        priceCount: Int,
        endpointCount: Int,
        preselectAll: Bool = true,
        importSelection: @escaping ([String]) -> Bool
    ) {
        self.models = models
        self.description = description
        self.priceCount = priceCount
        self.endpointCount = endpointCount
        self.importSelection = importSelection
        _selection = State(initialValue: preselectAll ? Set(models) : [])
    }

    private var filteredModels: [String] {
        guard !query.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                MHIconTile(
                    symbol: "square.and.arrow.down.on.square.fill",
                    size: 48,
                    emphasized: true
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入模型名录")
                        .font(.title2.weight(.semibold))
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("合并所选（\(selection.count)）") {
                    let selected = models.filter(selection.contains)
                    if importSelection(selected) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
            .padding(22)
            .background(MHDesign.elevatedSurface.opacity(0.94))

            Divider()

            HStack(spacing: 10) {
                CatalogImportMetric(
                    icon: "square.stack.3d.up.fill",
                    value: models.count,
                    label: "模型"
                )
                CatalogImportMetric(
                    icon: "dollarsign.circle.fill",
                    value: priceCount,
                    label: "价格"
                )
                CatalogImportMetric(
                    icon: "point.3.connected.trianglepath.dotted",
                    value: endpointCount,
                    label: "精确端点"
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            HStack(spacing: 12) {
                TextField("搜索模型", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("全选") { selection.formUnion(filteredModels) }
                Button("清除") { selection.subtract(filteredModels) }
                Text("显示 \(filteredModels.count) / \(models.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            List(filteredModels, id: \.self) { modelName in
                Toggle(
                    isOn: Binding(
                        get: { selection.contains(modelName) },
                        set: { selected in
                            if selected { selection.insert(modelName) }
                            else { selection.remove(modelName) }
                        }
                    )
                ) {
                    Text(modelName)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .toggleStyle(.checkbox)
            }
            .scrollContentBackground(.hidden)
        }
        .mhPageBackground()
        .frame(width: 700, height: 620)
    }
}

private struct CatalogImportMetric: View {
    let icon: String
    let value: Int
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(MHDesign.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.formatted())
                    .font(.headline.monospacedDigit())
                Text(mhLocalized(label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(MHDesign.elevatedSurface, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.06))
        }
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
            .padding(MHDesign.pagePadding)

            DefaultRoutingRulePanel()
                .padding(.horizontal, MHDesign.pagePadding)
                .padding(.bottom, 14)

            RouteDecisionSimulator()
                .padding(.horizontal, MHDesign.pagePadding)
                .padding(.bottom, 14)

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
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, MHDesign.pagePadding - 8)
                .padding(.bottom, MHDesign.pagePadding)
            }
        }
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

private struct RouteDecisionSimulator: View {
    @EnvironmentObject private var model: AppModel
    @State private var requestedModel = ""
    @State private var report: RouteDecisionReport?
    @State private var isRunning = false

    var body: some View {
        DisclosureGroup("路由决策模拟器") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("输入路由别名或模型名称", text: $requestedModel)
                        .textFieldStyle(.roundedBorder)
                    Button("只读模拟") {
                        Task {
                            isRunning = true
                            report = await model.simulateRoute(
                                requestedModel: requestedModel.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                            )
                            isRunning = false
                        }
                    }
                    .disabled(requestedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
                }
                Text("不会调用供应商、不会产生费用，也不会修改轮询计数、健康状态或用量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let report {
                    if report.candidates.isEmpty {
                        Text("没有匹配的路由目标或直接模型。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(report.candidates) { candidate in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: candidate.state == .selected
                                    ? "checkmark.circle.fill"
                                    : candidate.state == .eligible ? "circle" : "xmark.circle.fill")
                                    .foregroundStyle(candidate.state == .selected
                                        ? .green : candidate.state == .eligible ? .blue : .orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(candidate.providerName) / \(candidate.target.model)")
                                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                    Text(candidate.reasons.joined(separator: "；"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !candidate.endpoint.isEmpty {
                                        Text(candidate.endpoint)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                Spacer()
                                if let rank = candidate.rank { Text("#\(rank)").font(.caption.monospacedDigit()) }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: MHDesign.cardRadius).fill(MHDesign.surface))
        .overlay {
            RoundedRectangle(cornerRadius: MHDesign.cardRadius)
                .stroke(MHDesign.border)
        }
    }
}

private struct DefaultRoutingRulePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("默认路由规则")
                        .font(.headline)
                    Text("同名模型跨供应商时仅启用一项；三项规则均为内置规则，不可删除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(text: "已启用：\(model.configuration.routing.activeRule.displayName)", active: true)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                spacing: 10
            ) {
                ForEach(DefaultRoutingRule.allCases) { rule in
                    Button {
                        model.setDefaultRoutingRule(rule)
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Image(systemName: model.configuration.routing.activeRule == rule
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(model.configuration.routing.activeRule == rule
                                        ? Color.accentColor : Color.secondary)
                                    .font(.title3)
                                Spacer()
                                Text("内置")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(rule.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(rule.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(model.configuration.routing.activeRule == rule
                                ? Color.accentColor.opacity(0.09)
                                : MHDesign.elevatedSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(model.configuration.routing.activeRule == rule
                                ? Color.accentColor.opacity(0.42)
                                : MHDesign.border, lineWidth: 1)
                    )
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: MHDesign.cardRadius).fill(MHDesign.surface))
        .overlay {
            RoundedRectangle(cornerRadius: MHDesign.cardRadius)
                .stroke(MHDesign.border)
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
                .foregroundStyle(route.enabled ? MHDesign.accent : Color.secondary)
                .frame(width: 38, height: 38)
                .background(MHDesign.accent.opacity(route.enabled ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 10))
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
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
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
            MHModalHeader(
                title: "模型路由",
                subtitle: "使用稳定别名组织多个上游，并配置故障转移。",
                icon: "arrow.triangle.branch",
                trailing: AnyView(HStack {
                    Button("取消") { dismiss() }
                    Button("保存") {
                        model.saveRoute(route)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                })
            )
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

                Section("自适应约束") {
                    Toggle(
                        "启用价格、延迟、上下文与官方约束",
                        isOn: Binding(
                            get: { route.constraints != nil },
                            set: { route.constraints = $0 ? (route.constraints ?? RouteConstraints()) : nil }
                        )
                    )
                    if route.constraints != nil {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("最高综合 $/百万 Token")
                                TextField(
                                    "不限",
                                    value: Binding(
                                        get: { route.constraints?.maximumCombinedCostPerMillionTokens ?? 0 },
                                        set: { route.constraints?.maximumCombinedCostPerMillionTokens = $0 > 0 ? $0 : nil }
                                    ),
                                    format: .number
                                )
                                Text("最高 P90 延迟 ms")
                                TextField(
                                    "不限",
                                    value: Binding(
                                        get: { route.constraints?.maximumP90LatencyMilliseconds ?? 0 },
                                        set: { route.constraints?.maximumP90LatencyMilliseconds = $0 > 0 ? $0 : nil }
                                    ),
                                    format: .number
                                )
                            }
                            GridRow {
                                Text("最小上下文窗口")
                                TextField(
                                    "不限",
                                    value: Binding(
                                        get: { route.constraints?.minimumContextWindow ?? 0 },
                                        set: { route.constraints?.minimumContextWindow = $0 > 0 ? $0 : nil }
                                    ),
                                    format: .number
                                )
                                Toggle(
                                    "必须有已知价格",
                                    isOn: Binding(
                                        get: { route.constraints?.requireKnownPrice ?? false },
                                        set: { route.constraints?.requireKnownPrice = $0 }
                                    )
                                )
                            }
                        }
                        Toggle(
                            "仅允许模型官方供应商",
                            isOn: Binding(
                                get: { route.constraints?.requireOfficialProvider ?? false },
                                set: { route.constraints?.requireOfficialProvider = $0 }
                            )
                        )
                        Text("需要的模型能力")
                            .font(.caption.weight(.semibold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                            ForEach(ModelCapability.allCases) { capability in
                                Toggle(
                                    capability.displayName,
                                    isOn: Binding(
                                        get: { route.constraints?.requiredCapabilities.contains(capability) == true },
                                        set: {
                                            if $0 { route.constraints?.requiredCapabilities.insert(capability) }
                                            else { route.constraints?.requiredCapabilities.remove(capability) }
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                            }
                        }
                        Text("约束缺少可核实数据时采用失败关闭：目标不会被调用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                                        Text("固定 $/次")
                                        TextField(
                                            "未知",
                                            value: Binding(
                                                get: { target.profile?.requestCostUSD ?? 0 },
                                                set: {
                                                    target.profile?.requestCostUSD = $0 >= 0 ? $0 : nil
                                                    target.profile?.pricingUpdatedAt = .now
                                                }
                                            ),
                                            format: .number
                                        )
                                        Text("价格来源")
                                        TextField(
                                            "供应商目录 / 手工",
                                            text: Binding(
                                                get: { target.profile?.pricingSource ?? "" },
                                                set: {
                                                    target.profile?.pricingSource = $0
                                                    target.profile?.pricingUpdatedAt = .now
                                                }
                                            )
                                        )
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
            .scrollContentBackground(.hidden)
        }
        .mhPageBackground()
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
    @State private var operation: ConsoleOperation = .chat
    @State private var confirmsMusicGeneration = false

    private var availableModels: [String] {
        let aliases = model.routes.filter(\.enabled).map(\.alias)
        let direct = model.providers.filter(\.enabled).flatMap { provider in
            model.orderedModels(for: provider).map { "\(provider.name)/\($0)" }
        }
        return aliases + direct
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "API 调试", subtitle: "从应用内部调用同一个本地 HTTP 接口，验证完整路由链路。")

            HStack(spacing: 14) {
                Picker("协议", selection: $operation) {
                    ForEach(ConsoleOperation.allCases) { operation in
                        Text(operation.title).tag(operation)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Picker("模型", selection: $selectedModel) {
                    Text("请选择").tag("")
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .frame(maxWidth: 420)
                Spacer()
                Button {
                    if operation == .musicGeneration {
                        confirmsMusicGeneration = true
                    } else {
                        Task {
                            await model.runConsole(
                                model: selectedModel,
                                prompt: prompt,
                                operation: operation
                            )
                        }
                    }
                } label: {
                    if model.consoleIsRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("发送请求", systemImage: "paperplane")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedModel.isEmpty || prompt.isEmpty || model.consoleIsRunning)
            }
            .mhSurface(.secondary, padding: 16)

            GroupBox(operation == .musicGeneration ? "音乐描述" : "用户消息") {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(MHDesign.insetSurface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(MHDesign.border) }
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
        .padding(MHDesign.pagePadding)
        .onAppear {
            if selectedModel.isEmpty { selectedModel = availableModels.first ?? "" }
        }
        .onChange(of: availableModels) { _, models in
            if !models.contains(selectedModel) { selectedModel = models.first ?? "" }
        }
        .onChange(of: operation) { _, newValue in
            prompt = newValue == .musicGeneration
                ? "温暖、轻快的钢琴与弦乐，适合清晨。"
                : "请用一句话介绍你自己。"
        }
        .alert("确认音乐生成", isPresented: $confirmsMusicGeneration) {
            Button("取消", role: .cancel) {}
            Button("确认并发送") {
                Task {
                    await model.runConsole(
                        model: selectedModel,
                        prompt: prompt,
                        operation: operation
                    )
                }
            }
        } message: {
            Text("音乐生成可能产生供应商费用。只有确认当前模型、精确端点和费用后才会发送请求；隔离模型仍会被网关拒绝。")
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
            .padding(MHDesign.pagePadding)

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
                .background(MHDesign.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: MHDesign.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: MHDesign.cardRadius)
                        .stroke(MHDesign.border)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, MHDesign.pagePadding)
                .padding(.bottom, MHDesign.pagePadding)
            }
        }
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
                subtitle: "按模型与供应商聚合成功率、延迟、Token 和已知价格估算；不保存提示词或响应正文。",
                trailing: AnyView(
                    HStack(spacing: 10) {
                        Text("展示币种")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker(
                            "展示币种",
                            selection: Binding(
                                get: { model.currencyDisplaySettings.currency },
                                set: { model.selectDisplayCurrency($0) }
                            )
                        ) {
                            ForEach(DisplayCurrency.allCases) { currency in
                                Text(mhLocalized(currency.displayName)).tag(currency)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 138)
                        .disabled(model.isRefreshingCurrencyRates)

                        Button {
                            model.refreshCurrencyRatesNow()
                        } label: {
                            if model.isRefreshingCurrencyRates {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .help("刷新官方参考汇率")
                        .accessibilityLabel("刷新官方参考汇率")
                        .disabled(
                            model.isRefreshingCurrencyRates
                                || model.currencyDisplaySettings.currency == .usd
                        )

                        Button {
                            model.refreshModelPricesNow()
                        } label: {
                            HStack(spacing: 7) {
                                if model.isRefreshingModelPrices {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text("一键同步官方价格")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isRefreshingModelPrices || model.providers.isEmpty)
                    }
                )
            )
            .padding(MHDesign.pagePadding)

            if let progress = model.modelPriceRefreshProgress {
                ModelPriceRefreshBanner(progress: progress)
                    .padding(.horizontal, MHDesign.pagePadding)
                    .padding(.bottom, 16)
            } else if let message = model.configuration.operational.pricingUpdate?.lastMessage,
                      !message.isEmpty
            {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MHDesign.pagePadding)
                    .padding(.bottom, 12)
                    .accessibilityElement(children: .combine)
            }

            Label(model.currencyRateStatusText, systemImage: "coloncurrencysign.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MHDesign.pagePadding)
                .padding(.bottom, 12)
                .accessibilityElement(children: .combine)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: 16)],
                spacing: 16
            ) {
                MetricCard(title: "本月请求", value: "\(rows.reduce(0) { $0 + $1.requests })", icon: "arrow.up.arrow.down", color: .blue)
                MetricCard(title: "Token", value: "\(totalTokens)", icon: "number", color: .purple)
                MetricCard(
                    title: "已知价格估算（\(model.currencyDisplaySettings.currency.rawValue)）",
                    value: model.formattedDisplayCost(totalCost),
                    icon: "coloncurrencysign.circle",
                    color: .green
                )
            }
            .padding(.horizontal, MHDesign.pagePadding)
            .padding(.bottom, 16)

            if let warning = model.budgetStatusText {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MHDesign.pagePadding)
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
                        Text(
                            row.pricedRequests > 0
                                ? model.formattedDisplayCost(row.estimatedCostUSD)
                                : "未知"
                        )
                    }.width(90)
                }
                .background(MHDesign.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: MHDesign.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: MHDesign.cardRadius)
                        .stroke(MHDesign.border)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, MHDesign.pagePadding)
                .padding(.bottom, MHDesign.pagePadding)
            }
        }
    }
}

private struct ModelPriceRefreshBanner: View {
    let progress: ModelPriceRefreshProgress

    var body: some View {
        HStack(spacing: 16) {
            ProgressView(value: progress.fractionCompleted)
                .frame(maxWidth: 240)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在逐个检查已启用供应商…")
                    .font(.headline)
                Text("\(progress.completed) / \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(16)
        .background(MHDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(MHDesign.accent.opacity(0.16))
        }
        .accessibilityElement(children: .combine)
    }
}

struct OperationsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var settings = OperationalSettings()
    @State private var monthlyBudget = ""
    @State private var showAgentToken = false
    @State private var mcpStatus = ""
    @State private var pendingMCPInstall: MCPInstallDestination?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "路由与协议",
                subtitle: "集中配置韧性、预算、上下文优化与本机 Agent 协议。"
            )
            .padding(MHDesign.pagePadding)

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

            Section("模型价格自动更新") {
                Toggle(
                    "每天自动读取模型价格",
                    isOn: Binding(
                        get: { settings.pricingUpdate?.enabled ?? true },
                        set: {
                            var pricing = settings.pricingUpdate ?? PricingUpdateSettings()
                            pricing.enabled = $0
                            settings.pricingUpdate = pricing
                        }
                    )
                )
                if settings.pricingUpdate?.enabled ?? true {
                    HStack {
                        Picker(
                            "本机时间",
                            selection: Binding(
                                get: { settings.pricingUpdate?.localHour ?? 0 },
                                set: {
                                    var pricing = settings.pricingUpdate ?? PricingUpdateSettings()
                                    pricing.localHour = $0
                                    settings.pricingUpdate = pricing
                                }
                            )
                        ) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(String(format: "%02d 时", hour)).tag(hour)
                            }
                        }
                        .frame(maxWidth: 180)
                        Picker(
                            "分钟",
                            selection: Binding(
                                get: { settings.pricingUpdate?.localMinute ?? 0 },
                                set: {
                                    var pricing = settings.pricingUpdate ?? PricingUpdateSettings()
                                    pricing.localMinute = $0
                                    settings.pricingUpdate = pricing
                                }
                            )
                        ) {
                            ForEach(0..<60, id: \.self) { minute in
                                Text(String(format: "%02d 分", minute)).tag(minute)
                            }
                        }
                        .frame(maxWidth: 180)
                        Spacer()
                    }
                }
                HStack {
                    Button("立即更新模型价格") { model.refreshModelPricesNow() }
                        .disabled(model.isRefreshingModelPrices)
                    if model.isRefreshingModelPrices {
                        ProgressView().controlSize(.small)
                        Text("正在逐个检查已启用供应商…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let message = model.configuration.operational.pricingUpdate?.lastMessage,
                   !message.isEmpty
                {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("默认每天本机时间 00:00 更新。只读取供应商自身已配置或已核验的官方模型目录，不修改 Base URL、不合并新模型、不调用生成接口；仅当目录明确提供 Token 或单次调用价格及单位时更新，其他供应商保留手动价格。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本机内存缓存与离线回退") {
                Toggle(
                    "缓存完全相同的非流式文字请求",
                    isOn: Binding(
                        get: { settings.responseCache?.enabled ?? false },
                        set: {
                            var cache = settings.responseCache ?? ResponseCacheSettings()
                            cache.enabled = $0
                            settings.responseCache = cache
                        }
                    )
                )
                if settings.responseCache?.enabled == true {
                    Stepper(
                        "新鲜缓存：\(settings.responseCache?.timeToLiveSeconds ?? 300) 秒",
                        value: Binding(
                            get: { settings.responseCache?.timeToLiveSeconds ?? 300 },
                            set: { settings.responseCache?.timeToLiveSeconds = $0 }
                        ),
                        in: 10...86_400,
                        step: 10
                    )
                    Stepper(
                        "故障回退最长：\(settings.responseCache?.staleFallbackSeconds ?? 3_600) 秒",
                        value: Binding(
                            get: { settings.responseCache?.staleFallbackSeconds ?? 3_600 },
                            set: { settings.responseCache?.staleFallbackSeconds = $0 }
                        ),
                        in: 10...604_800,
                        step: 60
                    )
                    Stepper(
                        "最多条目：\(settings.responseCache?.maximumEntries ?? 128)",
                        value: Binding(
                            get: { settings.responseCache?.maximumEntries ?? 128 },
                            set: { settings.responseCache?.maximumEntries = $0 }
                        ),
                        in: 1...2_000
                    )
                }
                Button("立即清空内存缓存") { model.clearResponseCache() }
                Text("默认关闭。仅缓存 /v1/chat/completions 与 /v1/responses 的非流式成功响应；键只保存 SHA-256 摘要，正文只驻留内存、不写磁盘，并按虚拟密钥隔离。上游 5xx 时可返回仍在回退时限内的旧响应，响应头会标记 X-ModelHub-Cache: STALE。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("仅监听 127.0.0.1 并校验本机 Origin；生成工具需确认可能计费，所有调用仍经过隔离、限流、预算与日志。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("MCP 任务上下文与安装") {
                LabeledContent("MCP 地址") {
                    Text(model.mcpURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("MCP 可读取本机状态、可用模型、聚合用量和你保存的任务文本，也可调用文字、图片、视频、语音、向量与重排模型；不会自动读取 Codex/Claude 的全部会话或返回密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("一键安装到 Codex") { pendingMCPInstall = .codex }
                    Button("一键安装到 Claude") { pendingMCPInstall = .claude }
                    Button("复制手动安装配置") {
                        model.copyMCPManualConfiguration()
                        mcpStatus = "手动配置已复制；剪贴板包含 Agent 令牌。"
                    }
                }
                if !mcpStatus.isEmpty {
                    Text(mcpStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("当前任务文本（可选，最多 12,000 字符）")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: Binding(
                    get: { settings.agentProtocols.taskContext ?? "" },
                    set: { settings.agentProtocols.taskContext = String($0.prefix(12_000)) }
                ))
                .font(.system(.body, design: .default))
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                HStack {
                    Button("导入任务文本文件") { importTaskContext() }
                    Button("清空") { settings.agentProtocols.taskContext = nil }
                    Spacer()
                    Text("保存后 MCP 才会读取")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("请只粘贴或导入你授权共享的任务内容；ModelHub 不会自动扫描其他客户端的聊天记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("保存路由与协议设置") { save() }
                    .buttonStyle(.borderedProminent)
            }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "安装 ModelHub MCP？",
            isPresented: Binding(
                get: { pendingMCPInstall != nil },
                set: { if !$0 { pendingMCPInstall = nil } }
            )
        ) {
            if let destination = pendingMCPInstall {
                Button("安装到 \(destination.title)") {
                    mcpStatus = destination == .codex
                        ? model.installMCPToCodex()
                        : model.installMCPToClaude()
                    pendingMCPInstall = nil
                }
            }
            Button("取消", role: .cancel) { pendingMCPInstall = nil }
        } message: {
            Text("将更新用户主目录中的配置文件，并替换同名 modelhub MCP 条目；其他 MCP 条目会保留。")
        }
        .onAppear {
            settings = model.configuration.operational
            monthlyBudget = settings.budget.monthlyLimitUSD.map { String($0) } ?? ""
        }
    }

    private func save() {
        settings.budget.monthlyLimitUSD = Double(monthlyBudget)
        model.persistOperationalSettings(settings)
    }

    private func importTaskContext() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.title = "导入当前任务文本"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            settings.agentProtocols.taskContext = String(text.prefix(12_000))
            mcpStatus = "已导入任务文本；点击下方保存后才会通过 MCP 暴露。"
        } catch {
            mcpStatus = "任务文本导入失败：\(error.localizedDescription)"
        }
    }
}

private enum MCPInstallDestination: String, Identifiable {
    case codex
    case claude

    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Claude" }
}

struct GovernanceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingWorkspace: WorkspaceConfig?
    @State private var showingWorkspaceEditor = false
    @State private var showingKeyEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "访问与安全",
                    subtitle: "用工作区、虚拟密钥、预算与隐私策略隔离不同客户端；原始虚拟令牌只显示一次。",
                    trailing: AnyView(HStack {
                        Button("新建工作区") { showingWorkspaceEditor = true }
                        Button("签发虚拟密钥") { showingKeyEditor = true }
                            .buttonStyle(.borderedProminent)
                    })
                )

                if let token = model.lastIssuedVirtualKeyToken {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("请立即保存新虚拟密钥", systemImage: "key.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(token)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("ModelHub 只保存 SHA-256 摘要；关闭此提示后无法再次显示原始令牌。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(token, forType: .string)
                            }
                            Button("我已保存") { model.clearIssuedVirtualKeyToken() }
                        }
                    }
                    .cardStyle()
                }

                GroupBox("工作区策略") {
                    if model.configuration.workspaces.isEmpty {
                        Text("尚无工作区。主访问令牌仍拥有本机全部权限。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.configuration.workspaces) { workspace in
                                Button {
                                    editingWorkspace = workspace
                                } label: {
                                    HStack {
                                        Image(systemName: workspace.enabled ? "folder.badge.gearshape" : "folder")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(workspace.name).font(.headline)
                                            Text(workspaceSummary(workspace))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(workspace.enabled ? "已启用" : "已停用")
                                            .foregroundStyle(workspace.enabled ? .green : .secondary)
                                    }
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }

                GroupBox("虚拟密钥") {
                    if model.configuration.virtualKeys.isEmpty {
                        Text("尚未签发虚拟密钥。可为 Codex、Claude、IDE 或项目分别设置模型范围、RPM、到期时间和预算。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.configuration.virtualKeys) { key in
                                HStack {
                                    Image(systemName: key.enabled ? "key.fill" : "key.slash")
                                        .foregroundStyle(key.enabled ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(key.name).font(.headline)
                                        Text(keySummary(key))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if key.enabled {
                                        Button("撤销", role: .destructive) { model.revokeVirtualKey(key) }
                                    } else {
                                        Text("已撤销").foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }

                GroupBox("安全审计（不含提示词、响应和密钥）") {
                    if model.configuration.securityAudit.isEmpty {
                        Text("暂无安全事件。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.configuration.securityAudit.prefix(100))) { event in
                                HStack(alignment: .top) {
                                    Text(event.timestamp, style: .relative)
                                        .frame(width: 90, alignment: .leading)
                                    Text(event.action.rawValue)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 140, alignment: .leading)
                                    Text(event.detail)
                                        .font(.caption)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(MHDesign.pagePadding)
        }
        .sheet(isPresented: $showingWorkspaceEditor) {
            WorkspaceEditorView(workspace: nil).environmentObject(model)
        }
        .sheet(item: $editingWorkspace) { workspace in
            WorkspaceEditorView(workspace: workspace).environmentObject(model)
        }
        .sheet(isPresented: $showingKeyEditor) {
            VirtualKeyEditorView().environmentObject(model)
        }
    }

    private func workspaceSummary(_ workspace: WorkspaceConfig) -> String {
        let providers = workspace.allowedProviderIDs.isEmpty ? "全部供应商" : "\(workspace.allowedProviderIDs.count) 个供应商"
        let models = workspace.allowedModels.isEmpty ? "全部模型" : "\(workspace.allowedModels.count) 个模型"
        let regions = workspace.privacy.allowedRegions.isEmpty
            ? "地区不限"
            : workspace.privacy.allowedRegions.map(\.displayName).sorted().joined(separator: "、")
        return "\(providers) · \(models) · \(regions)"
    }

    private func keySummary(_ key: VirtualAccessKey) -> String {
        let workspace = key.workspaceID.flatMap { id in
            model.configuration.workspaces.first { $0.id == id }?.name
        } ?? "无工作区"
        let budget = key.monthlyBudgetUSD.map { String(format: "$%.2f", $0) } ?? "不限预算"
        return "\(workspace) · \(key.requestsPerMinute) RPM · \(budget) · 本月 \(key.requestsThisMonth) 次"
    }
}

private struct WorkspaceEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: WorkspaceConfig
    @State private var modelsText: String
    @State private var budgetText: String
    @State private var retentionText: String

    init(workspace: WorkspaceConfig?) {
        let value = workspace ?? WorkspaceConfig(name: "个人项目")
        _workspace = State(initialValue: value)
        _modelsText = State(initialValue: value.allowedModels.sorted().joined(separator: "\n"))
        _budgetText = State(initialValue: value.monthlyBudgetUSD.map { String($0) } ?? "")
        _retentionText = State(initialValue: value.privacy.maximumRetentionDays.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            MHModalHeader(
                title: "工作区策略",
                subtitle: "限定供应商、模型、预算与数据边界。",
                icon: "folder.badge.gearshape",
                trailing: AnyView(HStack {
                    Button("取消") { dismiss() }
                    Button("保存") {
                    workspace.allowedModels = Set(modelsText.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .filter { !$0.isEmpty })
                    workspace.monthlyBudgetUSD = Double(budgetText).flatMap { $0 > 0 ? $0 : nil }
                    workspace.privacy.maximumRetentionDays = Int(retentionText).flatMap { $0 >= 0 ? $0 : nil }
                    model.saveWorkspace(workspace)
                    dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                })
            )
            Divider()
            Form {
                Section("基本范围") {
                    TextField("工作区名称", text: $workspace.name)
                    Toggle("启用", isOn: $workspace.enabled)
                    TextField("月度费用上限 USD（留空不限）", text: $budgetText)
                    Text("允许的模型（每行一个；留空允许全部）")
                    TextEditor(text: $modelsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80)
                        .padding(8)
                        .background(MHDesign.insetSurface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(MHDesign.border) }
                }
                Section("允许的供应商（不选表示全部）") {
                    ForEach(model.providers) { provider in
                        Toggle(
                            provider.name,
                            isOn: Binding(
                                get: { workspace.allowedProviderIDs.contains(provider.id) },
                                set: {
                                    if $0 { workspace.allowedProviderIDs.insert(provider.id) }
                                    else { workspace.allowedProviderIDs.remove(provider.id) }
                                }
                            )
                        )
                    }
                }
                Section("隐私策略（严格失败关闭）") {
                    Text("允许的数据地区（不选表示不限）")
                    ForEach(ProviderDataRegion.allCases) { region in
                        Toggle(
                            region.displayName,
                            isOn: Binding(
                                get: { workspace.privacy.allowedRegions.contains(region) },
                                set: {
                                    if $0 { workspace.privacy.allowedRegions.insert(region) }
                                    else { workspace.privacy.allowedRegions.remove(region) }
                                }
                            )
                        )
                        .toggleStyle(.checkbox)
                    }
                    Toggle("必须明确为零数据留存", isOn: $workspace.privacy.requireZeroDataRetention)
                    Toggle("必须明确禁止用于训练", isOn: $workspace.privacy.forbidTrainingUse)
                    TextField("最长留存天数（留空不限）", text: $retentionText)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .mhPageBackground()
        .frame(width: 700, height: 800)
    }
}

private struct VirtualKeyEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Codex"
    @State private var workspaceID: UUID?
    @State private var modelsText = ""
    @State private var requestsPerMinute = 120
    @State private var budgetText = ""
    @State private var expires = false
    @State private var expiryDays = 30

    var body: some View {
        VStack(spacing: 0) {
            MHModalHeader(
                title: "签发虚拟密钥",
                subtitle: "为单个客户端创建可撤销、可限额的本地访问权。",
                icon: "key.fill",
                trailing: AnyView(HStack {
                    Button("取消") { dismiss() }
                    Button("签发") {
                    let models = Set(modelsText.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .filter { !$0.isEmpty })
                    if model.issueVirtualKey(
                        name: name,
                        workspaceID: workspaceID,
                        allowedModels: models,
                        requestsPerMinute: requestsPerMinute,
                        monthlyBudgetUSD: Double(budgetText),
                        expiresAt: expires ? Calendar.current.date(byAdding: .day, value: expiryDays, to: .now) : nil
                    ) != nil { dismiss() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                })
            )
            Divider()
            Form {
                TextField("密钥名称", text: $name)
                Picker("工作区", selection: $workspaceID) {
                    Text("无工作区（仅密钥自身限制）").tag(UUID?.none)
                    ForEach(model.configuration.workspaces.filter(\.enabled)) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
                Stepper("每分钟请求上限：\(requestsPerMinute)", value: $requestsPerMinute, in: 1...10_000)
                TextField("月度预算 USD（留空不限）", text: $budgetText)
                Text("允许的模型（每行一个；留空允许工作区范围内全部）")
                TextEditor(text: $modelsText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 100)
                    .padding(8)
                    .background(MHDesign.insetSurface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(MHDesign.border) }
                Toggle("设置到期时间", isOn: $expires)
                if expires {
                    Stepper("\(expiryDays) 天后到期", value: $expiryDays, in: 1...365)
                }
                Text("原始令牌只在签发后显示一次，配置文件只保存摘要。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .mhPageBackground()
        .frame(width: 620, height: 620)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var requireAuthentication = true
    @State private var startAutomatically = true
    @State private var showToken = false
    @State private var modelProxy = ModelProxySettings()
    @State private var showProxyModels = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "服务设置",
                subtitle: "管理本地 API、系统启动、访问令牌、备份与界面语言。"
            )
            .padding(MHDesign.pagePadding)

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
                LabeledContent("兼容 API Base URL") {
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

            Section("模型专用代理") {
                Toggle("启用 ModelHub 自定义代理", isOn: $modelProxy.enabled)
                Picker("代理类型", selection: $modelProxy.kind) {
                    ForEach(ModelProxyKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .disabled(!modelProxy.enabled)
                TextField("代理主机", text: $modelProxy.host)
                    .disabled(!modelProxy.enabled)
                TextField("代理端口", value: $modelProxy.port, format: .number.grouping(.never))
                    .disabled(!modelProxy.enabled)

                HStack {
                    Button("选择使用代理的模型") { showProxyModels = true }
                        .disabled(!modelProxy.enabled)
                    Text(L10n.format("已选择 %d 个精确模型", modelProxy.selections.count))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("保存代理设置") {
                        _ = model.persistModelProxySettings(modelProxy)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(modelProxy.validationMessage != nil)
                }

                if let message = modelProxy.validationMessage {
                    Label(mhLocalized(message), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(mhLocalized("默认所有模型、模型目录与官方价格均直连；只有所选供应商下的精确模型 ID 会使用此代理。代理配置不接收或保存用户名、密码。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        guard save(restart: false) else { return }
                        model.isServerRunning ? model.stopServer() : model.startServer()
                    }
                    Spacer()
                    Button("保存设置") { save(restart: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(modelProxy.validationMessage != nil)
                }
            }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            requireAuthentication = model.configuration.server.requireAuthentication
            startAutomatically = model.configuration.server.startAutomatically
            modelProxy = model.configuration.operational.modelProxy ?? .init()
            model.refreshLaunchAtLoginStatus()
        }
        .sheet(isPresented: $showProxyModels) {
            ModelProxySelectionView(
                settings: $modelProxy,
                providers: model.providers
            )
        }
    }

    @discardableResult
    private func save(restart: Bool) -> Bool {
        guard model.persistModelProxySettings(modelProxy) else { return false }
        model.persistServerSettings(
            ServerSettings(
                requireAuthentication: requireAuthentication,
                startAutomatically: startAutomatically
            ),
            restart: restart
        )
        return true
    }
}

private struct ModelProxySelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: ModelProxySettings
    let providers: [ProviderConfig]
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredProviders, id: \.id) { provider in
                    Section(provider.name) {
                        ForEach(filteredModels(for: provider), id: \.self) { model in
                            Button {
                                settings.setSelected(
                                    !settings.contains(providerID: provider.id, model: model),
                                    providerID: provider.id,
                                    model: model
                                )
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.primary)
                                        Text(provider.kind.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: settings.contains(
                                        providerID: provider.id,
                                        model: model
                                    ) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(settings.contains(
                                        providerID: provider.id,
                                        model: model
                                    ) ? Color.accentColor : Color.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(
                text: $query,
                prompt: Text(mhLocalized("搜索供应商或精确模型 ID"))
            )
            .navigationTitle("选择代理模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清除全部") { settings.selections.removeAll() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 620)
    }

    private var filteredProviders: [ProviderConfig] {
        providers.filter { !filteredModels(for: $0).isEmpty }
    }

    private func filteredModels(for provider: ProviderConfig) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return provider.models.sorted() }
        if provider.name.localizedCaseInsensitiveContains(needle) {
            return provider.models.sorted()
        }
        return provider.models.filter {
            $0.localizedCaseInsensitiveContains(needle)
        }.sorted()
    }
}

private struct MHGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(MHDesign.accent)
                    .frame(width: 3, height: 16)
                configuration.label
                    .font(.headline)
            }
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            MHDesign.elevatedSurface,
            in: RoundedRectangle(cornerRadius: MHDesign.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MHDesign.cardRadius, style: .continuous)
                .stroke(MHDesign.border)
        }
        .shadow(color: .black.opacity(0.055), radius: 12, y: 5)
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            MHIconTile(symbol: icon, size: 48, emphasized: true)
            VStack(alignment: .leading, spacing: 5) {
                Text("MODELHUB")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(MHDesign.accent)
                Text(mhLocalized(title))
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                Text(mhLocalized(subtitle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 680, alignment: .leading)
            }
            Spacer(minLength: 24)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var icon: String {
        switch title {
        case "概览": "square.grid.2x2.fill"
        case "模型供应商": "server.rack"
        case "模型路由": "arrow.triangle.branch"
        case "用量分析": "chart.xyaxis.line"
        case "路由与协议": "switch.2"
        case "访问与安全": "lock.shield.fill"
        case "API 调试": "terminal.fill"
        case "请求日志": "list.bullet.rectangle"
        case "代理订阅": "network.badge.shield.half.filled"
        case "服务设置": "gearshape.fill"
        default: "circle.grid.2x2.fill"
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let active: Bool
    var onAccent = false

    var body: some View {
        Label(mhLocalized(text), systemImage: active ? "checkmark.circle.fill" : "pause.circle")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(onAccent ? Color.white : (active ? Color.green : Color.secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                onAccent ? Color.white.opacity(0.14) : (active ? Color.green : Color.secondary).opacity(0.1),
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(
                    onAccent ? Color.white.opacity(0.18) : (active ? Color.green : Color.secondary).opacity(0.16)
                )
            }
    }
}

private struct EmptyCallout: View {
    let icon: String
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            MHIconTile(symbol: icon, size: 64)
            Text(mhLocalized(title))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(mhLocalized(detail))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button(mhLocalized(action), action: perform)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(36)
        .frame(maxWidth: 640)
        .mhSurface(.secondary, padding: 4)
    }
}

private extension View {
    func cardStyle() -> some View {
        mhSurface(.elevated, padding: 20)
    }
}
