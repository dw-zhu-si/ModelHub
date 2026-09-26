import ModelHubShared
import SwiftUI

private enum Destination: String, CaseIterable, Identifiable {
    case overview = "概览"
    case settings = "设置"

    var id: String { rawValue }
    var symbol: String { self == .overview ? "square.grid.2x2" : "gearshape" }
}

struct RootView: View {
    @Bindable var store: MobileStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: Destination? = .overview

    var body: some View {
        if horizontalSizeClass == .compact {
            TabView {
                OverviewDestination(store: store)
                    .tabItem { Label("概览", systemImage: "square.grid.2x2") }
                SettingsDestination(store: store)
                    .tabItem { Label("设置", systemImage: "gearshape") }
            }
        } else {
            NavigationSplitView {
                List(Destination.allCases, selection: $selection) { destination in
                    Label(destination.rawValue, systemImage: destination.symbol)
                        .tag(destination)
                }
                .navigationTitle("ModelHub")
            } detail: {
                switch selection ?? .overview {
                case .overview: OverviewDestination(store: store)
                case .settings: SettingsDestination(store: store)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }
}

private struct OverviewDestination: View {
    @Bindable var store: MobileStore

    var body: some View {
        NavigationStack {
            Group {
                switch store.state {
                case .unpaired:
                    PairingView(store: store)
                case .awaitingApproval:
                    StatusView(
                        symbol: "macbook.and.iphone",
                        title: "等待 Mac 批准",
                        message: "请在 ModelHub 桌面端核对设备名称与公钥指纹后批准。",
                        showsProgress: true
                    )
                case .connected(let bootstrap):
                    OverviewView(overview: bootstrap.overview, offline: false, refresh: store.refresh)
                case .offline(let cached):
                    if let cached {
                        OverviewView(overview: cached.overview, offline: true, refresh: store.refresh)
                    } else {
                        StatusView(
                            symbol: "wifi.slash",
                            title: "无法连接网关",
                            message: "确认 Mac 已开启移动访问，且设备处于同一局域网或 VPN。",
                            actionTitle: "重试",
                            action: store.refresh
                        )
                    }
                case .revoked:
                    StatusView(
                        symbol: "lock.slash",
                        title: "设备授权已撤销",
                        message: "请在桌面端重新生成配对二维码。",
                        actionTitle: "重新配对",
                        action: store.forgetBinding
                    )
                case .failed(let message):
                    StatusView(
                        symbol: "exclamationmark.triangle",
                        title: "配对未完成",
                        message: message,
                        actionTitle: "重新配对",
                        action: store.forgetBinding
                    )
                }
            }
            .navigationTitle("概览")
        }
    }
}

private struct PairingView: View {
    @Bindable var store: MobileStore
    @State private var payload = ""
    @State private var deviceName = UIDevice.current.name
    @State private var showsScanner = false

    var body: some View {
        Form {
            Section {
                Button {
                    showsScanner = true
                } label: {
                    Label("扫描配对二维码", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                TextField("或粘贴二维码内容", text: $payload, axis: .vertical)
                    .lineLimit(4...8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("设备名称", text: $deviceName)
            } header: {
                Text("连接 ModelHub")
            } footer: {
                Text("扫码不会自动授权；仍需在 Mac 上显式批准。")
            }
            Section {
                Button("提交安全配对") {
                    store.pair(rawPayload: payload, deviceName: deviceName)
                }
                .disabled(payload.isEmpty || deviceName.isEmpty)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            Section {
                Label("供应商密钥、OAuth 令牌和桌面全局令牌始终留在 Mac。", systemImage: "checkmark.shield")
            }
        }
        .sheet(isPresented: $showsScanner) {
            NavigationStack {
                QRScannerView { code in
                    payload = code
                    showsScanner = false
                }
                .ignoresSafeArea()
                .navigationTitle("扫描配对码")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showsScanner = false }
                    }
                }
            }
        }
    }
}

private struct OverviewView: View {
    let overview: MobileGatewayOverview
    let offline: Bool
    let refresh: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(offline ? "离线快照" : "已安全连接")
                            .font(.headline)
                        Text(offline ? overview.generatedAt : "ModelHub \(overview.gatewayVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    SummaryCard(title: "默认模型", value: overview.defaultModel ?? "暂无健康默认模型")
                    SummaryCard(title: "可用模型", value: "\(overview.modelHealth.available) / \(overview.modelHealth.total)")
                    SummaryCard(title: "已启用供应商", value: "\(overview.enabledProviderCount)")
                }
                Text("供应商健康").font(.title2.bold())
                ForEach(overview.providers, id: \.id) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(provider.name).font(.headline)
                            Text("可用 \(provider.availableModels) · 隔离 \(provider.quarantinedModels)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(provider.availableModels)/\(provider.totalModels)")
                            .monospacedDigit()
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding()
        }
        .refreshable { refresh() }
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding()
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct SettingsDestination: View {
    @Bindable var store: MobileStore
    @State private var showsForgetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    LabeledContent("网关", value: store.serviceURL ?? "未配对")
                }
                Section("安全") {
                    Label("签名私钥保存在 Secure Enclave/Keychain", systemImage: "key.fill")
                    Text("移动端不保存供应商密钥、OAuth 令牌或桌面全局令牌。")
                }
                Section {
                    Button("忘记本机配对", role: .destructive) {
                        showsForgetConfirmation = true
                    }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .navigationTitle("设置")
            .confirmationDialog("忘记本机配对？", isPresented: $showsForgetConfirmation, titleVisibility: .visible) {
                Button("忘记配对", role: .destructive, action: store.forgetBinding)
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除本机的设备签名密钥和网关绑定。下次连接需要重新扫码并在 Mac 上批准。")
            }
        }
    }
}

private struct StatusView: View {
    let symbol: String
    let title: String
    let message: String
    var showsProgress = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if showsProgress { ProgressView() }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
    }
}
