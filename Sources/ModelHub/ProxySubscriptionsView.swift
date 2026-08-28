import SwiftUI
import ModelHubCore

struct ProxySubscriptionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsAddSheet = false
    @State private var assignmentContext: ProxyAssignmentContext?
    @State private var pendingRemoval: ProxySubscription?

    private let columns = [
        GridItem(.adaptive(minimum: 310, maximum: 430), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "代理订阅",
                    subtitle: "添加 Clash/Mihomo 兼容订阅，并把不同节点精确分配给供应商下的模型。"
                )

                runtimeSummary

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("订阅")
                            .font(.title3.weight(.semibold))
                        Text("订阅链接仅保存在 Keychain，列表只显示来源域名。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.refreshAllProxySubscriptions()
                    } label: {
                        Label("全部更新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.proxySubscriptions.isEmpty)
                    Button {
                        showsAddSheet = true
                    } label: {
                        Label("新建订阅", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if model.proxySubscriptions.isEmpty {
                    ContentUnavailableView {
                        Label("尚未添加代理订阅", systemImage: "network.badge.shield.half.filled")
                    } description: {
                        Text("添加 HTTPS 订阅后，ModelHub 会通过本机 Mihomo 读取节点；不会修改 Clash Verge 的配置或系统代理。")
                    } actions: {
                        Button("新建订阅") { showsAddSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 250)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(model.proxySubscriptions) { subscription in
                            ProxySubscriptionCard(
                                subscription: subscription,
                                nodes: model.proxySubscriptionNodes.filter {
                                    $0.subscriptionID == subscription.id
                                },
                                isRefreshing: model.refreshingProxySubscriptionIDs.contains(
                                    subscription.id
                                ),
                                message: model.proxySubscriptionMessages[subscription.id],
                                hasStoredURL: model.proxySubscriptionHasStoredURL(subscription.id),
                                onRefresh: { model.refreshProxySubscription(subscription.id) },
                                onToggle: {
                                    model.setProxySubscriptionEnabled($0, id: subscription.id)
                                },
                                onChooseNodes: {
                                    assignmentContext = ProxyAssignmentContext(
                                        subscriptionID: subscription.id
                                    )
                                },
                                onRemove: { pendingRemoval = subscription }
                            )
                        }
                    }
                }
            }
            .padding(MHDesign.pagePadding)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .sheet(isPresented: $showsAddSheet) {
            AddProxySubscriptionView { name, url, interval in
                if model.addProxySubscription(
                    name: name,
                    url: url,
                    updateIntervalHours: interval
                ) {
                    showsAddSheet = false
                }
            }
        }
        .sheet(item: $assignmentContext) { context in
            ProxyNodeAssignmentView(context: context)
                .environmentObject(model)
        }
        .confirmationDialog(
            "删除订阅？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { subscription in
            Button("删除“\(subscription.name)”", role: .destructive) {
                model.removeProxySubscription(subscription.id)
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: { subscription in
            Text("相关模型分配会一并清除；Keychain 中的订阅链接也会删除。")
        }
    }

    private var runtimeSummary: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Toggle(
                    "启用模型专用代理",
                    isOn: Binding(
                        get: { model.modelProxyEnabled },
                        set: { model.setModelProxyEnabled($0) }
                    )
                )
                .font(.headline)
                Text("运行状态：\(model.proxyRuntimeStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 42)
            summaryMetric(value: "\(model.proxySubscriptions.count)", label: "订阅")
            summaryMetric(value: "\(model.proxySubscriptionNodes.count)", label: "节点")
            summaryMetric(value: "\(model.modelProxyAssignmentCount)", label: "模型分配")
            Spacer()
            Button {
                assignmentContext = ProxyAssignmentContext()
            } label: {
                Label("分配模型节点", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.proxySubscriptionNodes.isEmpty)
        }
        .padding(18)
        .background(MHDesign.elevatedSurface, in: RoundedRectangle(cornerRadius: MHDesign.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MHDesign.cardRadius).stroke(MHDesign.border)
        }
        .accessibilityElement(children: .contain)
    }

    private func summaryMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 58, alignment: .leading)
    }
}

private struct ProxySubscriptionCard: View {
    let subscription: ProxySubscription
    let nodes: [ProxySubscriptionNode]
    let isRefreshing: Bool
    let message: String?
    let hasStoredURL: Bool
    let onRefresh: () -> Void
    let onToggle: (Bool) -> Void
    let onChooseNodes: () -> Void
    let onRemove: () -> Void

    private var nodeCount: Int { nodes.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subscription.name)
                        .font(.headline)
                        .lineLimit(1)
                    Label(subscription.sourceHost, systemImage: "lock.fill")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    onToggle(!subscription.enabled)
                } label: {
                    Image(systemName: subscription.enabled
                        ? "checkmark.circle.fill"
                        : "circle")
                        .font(.title3)
                        .foregroundStyle(subscription.enabled ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(subscription.enabled ? "停用订阅" : "启用订阅")
            }

            HStack(spacing: 14) {
                Label("\(nodeCount) 个节点", systemImage: "point.3.filled.connected.trianglepath.dotted")
                if let lastUpdatedAt = subscription.lastUpdatedAt {
                    Label(lastUpdatedAt.formatted(.relative(presentation: .named)), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let total = subscription.totalBytes, total > 0 {
                let used = min(
                    (subscription.uploadBytes ?? 0) + (subscription.downloadBytes ?? 0),
                    total
                )
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: Double(used), total: Double(total))
                    HStack {
                        Text("已用 \(byteString(used))")
                        Spacer()
                        Text("共 \(byteString(total))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            if let expiresAt = subscription.expiresAt {
                Label("到期：\(expiresAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(expiresAt < .now ? Color.orange : Color.secondary)
            }

            if let message {
                Label(message, systemImage: nodeCount > 0 ? "checkmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(nodeCount > 0 ? Color.secondary : Color.orange)
                    .lineLimit(2)
            } else if !hasStoredURL {
                Label("需要重新填写订阅链接", systemImage: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !nodes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("可选节点")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(nodes.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }.prefix(3)) { node in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(node.isAlive ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(node.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(node.type)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if nodes.count > 3 {
                        Text("另有 \(nodes.count - 3) 个节点")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack {
                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || !subscription.enabled || !hasStoredURL)
                Button("选择节点", action: onChooseNodes)
                    .disabled(nodes.isEmpty)
                Spacer()
                Button("删除", role: .destructive, action: onRemove)
            }
        }
        .padding(17)
        .background(MHDesign.elevatedSurface, in: RoundedRectangle(cornerRadius: MHDesign.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MHDesign.cardRadius).stroke(MHDesign.border)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct AddProxySubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var updateIntervalHours = 24
    let onSave: (String, String, Int) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅信息") {
                    TextField("名称", text: $name)
                    SecureField("HTTPS 订阅链接", text: $url)
                    Stepper(
                        "每 \(updateIntervalHours) 小时更新",
                        value: $updateIntervalHours,
                        in: 1...168
                    )
                }
                Section {
                    Label("链接中的令牌只写入 macOS Keychain，不写入配置备份、日志或节点运行配置。", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("新建代理订阅")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onSave(name, url, updateIntervalHours)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 560, height: 360)
    }
}

enum ProxyAssignmentScope: String, CaseIterable, Identifiable {
    case pending
    case quarantined
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: "待验证"
        case .quarantined: "已隔离"
        case .all: "全部"
        }
    }
}

struct ProxyAssignmentContext: Identifiable {
    let id = UUID()
    var providerID: UUID?
    var subscriptionID: UUID?
    var scope: ProxyAssignmentScope

    init(
        providerID: UUID? = nil,
        subscriptionID: UUID? = nil,
        scope: ProxyAssignmentScope = .pending
    ) {
        self.providerID = providerID
        self.subscriptionID = subscriptionID
        self.scope = scope
    }
}

struct ProxyNodeAssignmentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProviderID: UUID?
    @State private var selectedNodeID: String?
    @State private var candidateNodeIDs: [String] = []
    @State private var automaticFailoverEnabled = false
    @State private var failoverThreshold = ModelProxyAutomaticFailoverSettings.defaultConsecutiveFailureThreshold
    @State private var scope: ProxyAssignmentScope
    @State private var query = ""
    @State private var nodeQuery = ""
    @State private var selectedModels = Set<String>()
    @State private var showsProbeConfirmation = false
    private let initialSubscriptionID: UUID?

    init(context: ProxyAssignmentContext = ProxyAssignmentContext()) {
        _selectedProviderID = State(initialValue: context.providerID)
        _scope = State(initialValue: context.scope)
        initialSubscriptionID = context.subscriptionID
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                assignmentControls
                    .padding(18)
                Divider()
                modelList
                Divider()
                actionBar
                    .padding(16)
            }
            .navigationTitle("选择节点并批量分配")
            .searchable(text: $query, prompt: "搜索精确模型 ID")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 700)
        .onAppear(perform: prepareInitialSelection)
        .onChange(of: selectedProviderID) {
            selectedModels.removeAll()
            candidateNodeIDs.removeAll()
        }
        .onChange(of: scope) {
            selectedModels.removeAll()
        }
        .confirmationDialog(
            "复验所选隔离文字模型？",
            isPresented: $showsProbeConfirmation
        ) {
            Button("开始最小复验（可能产生少量费用）") {
                guard let providerID = selectedProviderID else { return }
                model.startTestingQuarantinedModels(
                    providerID: providerID,
                    selectedModels: Array(selectedModels)
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(probeConfirmationMessage)
        }
    }

    private var assignmentControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Picker("供应商", selection: $selectedProviderID) {
                    Text("请选择供应商").tag(Optional<UUID>.none)
                    ForEach(model.providers) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
                .frame(minWidth: 220)

                Picker("范围", selection: $scope) {
                    ForEach(ProxyAssignmentScope.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("节点")
                    .font(.subheadline.weight(.semibold))
                Text("卡片显示通过各节点访问外网的最近延迟")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("搜索节点", text: $nodeQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button {
                    model.testProxyNodeLatencies(visibleNodes.map(\.id))
                } label: {
                    Label(
                        "节点出站测速（\(visibleNodes.count)）",
                        systemImage: "gauge.with.dots.needle.33percent"
                    )
                }
                .disabled(
                    visibleNodes.isEmpty
                        || model.isTestingProxyNodeLatency
                )
                .help("受管代理会按顺序通过每个指定节点访问固定 HTTPS 204 外网探针，避免并发测速互相干扰；不测试订阅服务器，不调用模型。")
            }

            nodeCardGrid

            HStack(spacing: 12) {
                Toggle("启用有序节点自动切换", isOn: $automaticFailoverEnabled)
                    .toggleStyle(.switch)
                Stepper(
                    L10n.format("连续瞬态故障 %d 次后切换", failoverThreshold),
                    value: $failoverThreshold,
                    in: 1...ModelProxyAutomaticFailoverSettings.maximumConsecutiveFailureThreshold
                )
                .disabled(!automaticFailoverEnabled)
                Spacer()
                Text("只使用卡片中显式加入的备选节点；候选耗尽后失败关闭，绝不静默直连。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label(
                    selectedNode.map {
                        "已选节点：\($0.name) · \($0.type)"
                    } ?? "请先选择一个订阅节点",
                    systemImage: selectedNode?.isAlive == true
                        ? "network.badge.shield.half.filled"
                        : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(selectedNode == nil ? Color.orange : Color.secondary)
                .lineLimit(1)
                Spacer()
                Button("全选当前 \(visibleModels.count)") {
                    selectedModels.formUnion(visibleModels)
                }
                .disabled(visibleModels.isEmpty)
                Button("清空选择") { selectedModels.removeAll() }
                    .disabled(selectedModels.isEmpty)
            }
        }
    }

    private var nodeCardGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(visibleNodes) { node in
                    nodeCard(node)
                }
            }
            .padding(2)
        }
        .frame(minHeight: 110, maxHeight: 230)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(MHDesign.border)
        }
        .accessibilityLabel("订阅节点卡片")
    }

    private func nodeCard(_ node: ProxySubscriptionNode) -> some View {
        let selected = selectedNodeID == node.id
        let candidateIndex = candidateNodeIDs.firstIndex(of: node.id)
        let testing = model.testingProxyNodeIDs.contains(node.id)
        let result = model.proxyNodeLatencyResults[node.id]
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                selectedNodeID = node.id
                candidateNodeIDs.removeAll { $0 == node.id }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        Text(node.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(node.isAlive ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(subscriptionName(for: node))
                            .lineLimit(1)
                        Text("·")
                        Text(node.type)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!node.isAlive)

            Divider()

            HStack(spacing: 7) {
                if testing {
                    ProgressView()
                        .controlSize(.mini)
                    Text("外网测速中")
                        .foregroundStyle(.secondary)
                } else if let latency = result?.latencyMilliseconds {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Text("外网 \(latency) ms")
                        .monospacedDigit()
                } else if result != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(result?.failure?.shortDescription ?? L10n.text("失败/超时"))
                } else {
                    Image(systemName: "gauge.with.dots.needle.0percent")
                    Text("未测速")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("测外网") {
                    model.testProxyNodeLatency(node.id)
                }
                .controlSize(.small)
                .disabled(model.isTestingProxyNodeLatency)
            }
            .font(.caption)
            .foregroundStyle(latencyColor(result))

            Button {
                guard node.id != selectedNodeID else { return }
                if candidateIndex != nil {
                    candidateNodeIDs.removeAll { $0 == node.id }
                } else {
                    candidateNodeIDs.append(node.id)
                }
            } label: {
                Label(
                    candidateIndex.map { L10n.format("备选 #%d", $0 + 1) }
                        ?? L10n.text("加入有序备选"),
                    systemImage: candidateIndex == nil
                        ? "plus.circle" : "arrow.triangle.branch"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selected || !node.isAlive)
        }
        .padding(11)
        .background(
            selected ? MHDesign.accent.opacity(0.10) : MHDesign.elevatedSurface,
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? MHDesign.accent : MHDesign.border, lineWidth: selected ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.name)，\(latencyAccessibilityText(node.id))")
    }

    @ViewBuilder
    private var modelList: some View {
        if selectedProvider == nil {
            ContentUnavailableView(
                "请选择供应商",
                systemImage: "building.2",
                description: Text("选择供应商后，可以按待验证、已隔离或全部模型批量分配节点。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleModels.isEmpty {
            ContentUnavailableView(
                "当前范围没有模型",
                systemImage: "checkmark.shield",
                description: Text("调整范围或搜索条件。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visibleModels, id: \.self) { modelID in
                Button {
                    if selectedModels.contains(modelID) {
                        selectedModels.remove(modelID)
                    } else {
                        selectedModels.insert(modelID)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedModels.contains(modelID)
                            ? "checkmark.circle.fill"
                            : "circle")
                            .foregroundStyle(selectedModels.contains(modelID)
                                ? Color.accentColor
                                : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(modelID)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(modelStatusDetail(modelID))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(assignedNodeName(modelID) ?? "直连")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(modelID)，\(selectedModels.contains(modelID) ? "已选择" : "未选择")")
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("已选择 \(selectedModels.count) 个模型")
                    .font(.headline)
                Text(automaticFailoverEnabled
                    ? "主节点与有序备选按精确模型保存；自动切换绝不回退直连。"
                    : "节点按精确模型保存；未分配的模型继续直连。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消所选分配") {
                guard let providerID = selectedProviderID else { return }
                model.assignProxyNode(
                    nil,
                    providerID: providerID,
                    models: Array(selectedModels)
                )
            }
            .disabled(selectedModels.isEmpty || selectedProviderID == nil)

            Button("应用并启用节点") {
                guard let providerID = selectedProviderID else { return }
                model.assignProxyNodes(
                    primaryNodeID: selectedNodeID,
                    candidateNodeIDs: candidateNodeIDs,
                    providerID: providerID,
                    models: Array(selectedModels),
                    enableWhenAssigned: true,
                    automaticFailover: ModelProxyAutomaticFailoverSettings(
                        enabled: automaticFailoverEnabled,
                        consecutiveFailureThreshold: failoverThreshold
                    )
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedModels.isEmpty || selectedProviderID == nil || selectedNode?.isAlive != true)

            Button("复验已选文字模型") {
                showsProbeConfirmation = true
            }
            .disabled(!canProbeSelectedModels)
            .help("需要先应用所选节点，并等待模型代理显示为运行中。生成/原生协议模型不会批量调用。")
        }
    }

    private var selectedProvider: ProviderConfig? {
        guard let selectedProviderID else { return nil }
        return model.providers.first { $0.id == selectedProviderID }
    }

    private var selectedNode: ProxySubscriptionNode? {
        guard let selectedNodeID else { return nil }
        return model.proxySubscriptionNodes.first { $0.id == selectedNodeID }
    }

    private var visibleNodes: [ProxySubscriptionNode] {
        let enabledSubscriptionIDs = Set(model.proxySubscriptions.filter(\.enabled).map(\.id))
        let needle = nodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.proxySubscriptionNodes.filter { node in
            enabledSubscriptionIDs.contains(node.subscriptionID)
                && (needle.isEmpty || node.name.localizedCaseInsensitiveContains(needle))
        }.sorted { lhs, rhs in
            if lhs.subscriptionID == rhs.subscriptionID {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return subscriptionName(for: lhs).localizedCaseInsensitiveCompare(
                subscriptionName(for: rhs)
            ) == .orderedAscending
        }
    }

    private var visibleModels: [String] {
        guard let provider = selectedProvider else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.orderedModels(for: provider).filter { modelID in
            let status = model.healthRecord(providerID: provider.id, model: modelID)?.status
                ?? .unknown
            let matchesScope: Bool
            switch scope {
            case .pending: matchesScope = status == .unknown
            case .quarantined: matchesScope = status == .unavailable
            case .all: matchesScope = true
            }
            return matchesScope && (needle.isEmpty
                || modelID.localizedCaseInsensitiveContains(needle))
        }
    }

    private var selectedProbeableChatModels: [String] {
        guard let provider = selectedProvider else { return [] }
        return selectedModels.filter { modelID in
            let status = model.healthRecord(providerID: provider.id, model: modelID)?.status
                ?? .unknown
            return (status == .unknown || status == .unavailable)
                && ModelProbePolicy.nativeProtocol(provider: provider, model: modelID) == nil
        }.sorted()
    }

    private var selectedPendingNativeCount: Int {
        guard let provider = selectedProvider else { return 0 }
        return selectedModels.lazy.filter { modelID in
            let status = model.healthRecord(providerID: provider.id, model: modelID)?.status
                ?? .unknown
            return (status == .unknown || status == .unavailable)
                && ModelProbePolicy.nativeProtocol(provider: provider, model: modelID) != nil
        }.count
    }

    private var selectedModelsUseChosenNode: Bool {
        guard let providerID = selectedProviderID, let selectedNodeID else { return false }
        return selectedProbeableChatModels.allSatisfy { modelID in
            model.assignedProxyNodeID(providerID: providerID, model: modelID) == selectedNodeID
        }
    }

    private var canProbeSelectedModels: Bool {
        !selectedProbeableChatModels.isEmpty
            && selectedModelsUseChosenNode
            && model.modelProxyEnabled
            && model.proxyRuntimeStatus.hasPrefix("运行中")
            && !model.isTestingModels
    }

    private var probeConfirmationMessage: String {
        var message = "将通过所选节点向 \(selectedProvider?.name ?? "供应商") 发起 \(selectedProbeableChatModels.count) 个最小文字请求（每个最多 1 token），可能产生少量费用。只有成功的模型会恢复路由。"
        if selectedPendingNativeCount > 0 {
            message += " 另有 \(selectedPendingNativeCount) 个生成/原生协议模型会保持待验证，不会批量调用。"
        }
        return message
    }

    private func nodes(for subscription: ProxySubscription) -> [ProxySubscriptionNode] {
        model.proxySubscriptionNodes.filter {
            $0.subscriptionID == subscription.id
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func subscriptionName(for node: ProxySubscriptionNode) -> String {
        model.proxySubscriptions.first(where: { $0.id == node.subscriptionID })?.name
            ?? "未知订阅"
    }

    private func latencyColor(_ result: ProxyNodeLatencyResult?) -> Color {
        guard let result else { return .secondary }
        guard let latency = result.latencyMilliseconds else { return .orange }
        if latency < 180 { return .green }
        if latency < 350 { return .orange }
        return .red
    }

    private func latencyAccessibilityText(_ nodeID: String) -> String {
        if model.testingProxyNodeIDs.contains(nodeID) { return "正在通过节点测试外网延迟" }
        guard let result = model.proxyNodeLatencyResults[nodeID] else { return "未测速" }
        guard let latency = result.latencyMilliseconds else {
            return result.failure?.shortDescription ?? "测速失败或超时"
        }
        return "经该节点访问外网的延迟 \(latency) 毫秒"
    }

    private func assignedNodeName(_ modelID: String) -> String? {
        guard let providerID = selectedProviderID,
              let nodeID = model.assignedProxyNodeID(providerID: providerID, model: modelID)
        else { return nil }
        return model.proxySubscriptionNodes.first(where: { $0.id == nodeID })?.name
    }

    private func modelStatusDetail(_ modelID: String) -> String {
        guard let provider = selectedProvider else { return "" }
        let status = model.healthRecord(providerID: provider.id, model: modelID)?.status
            ?? .unknown
        let statusText: String
        switch status {
        case .available: statusText = "可用"
        case .unavailable: statusText = "已隔离"
        case .unknown: statusText = "待验证 · 已隔离"
        case .configurationRequired: statusText = "需配置密钥 · 已隔离"
        case .unsupported: statusText = "待适配 · 已隔离"
        }
        if let nativeProtocol = ModelProbePolicy.nativeProtocol(provider: provider, model: modelID) {
            return "\(statusText) · \(nativeProtocol.displayName)不参与批量复验"
        }
        return statusText
    }

    private func prepareInitialSelection() {
        let failover = model.proxyAutomaticFailoverSettings
        automaticFailoverEnabled = failover.enabled
        failoverThreshold = failover.consecutiveFailureThreshold
        if selectedProviderID == nil {
            selectedProviderID = model.providers.first?.id
        }
        guard selectedNodeID == nil else { return }
        if let initialSubscriptionID,
           let node = model.proxySubscriptionNodes.first(where: {
               $0.subscriptionID == initialSubscriptionID && $0.isAlive
           })
        {
            selectedNodeID = node.id
        } else {
            selectedNodeID = model.proxySubscriptionNodes.first(where: \.isAlive)?.id
        }
    }
}
