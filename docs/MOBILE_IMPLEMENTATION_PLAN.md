# ModelHub 移动端实施计划

状态：Phase 1 首个代码切片与本地工具链收口已完成；Checkpoint A 等待真机端到端验收<br>
范围：iPhone、iPad、Android 手机、Android 平板<br>
原则：两套安装包、四类设备体验；桌面端继续作为安全网关和配置权威源。

## 1. 产品边界

移动端定位为 **ModelHub 安全伴侣端**，而不是在手机上复制一套供应商网关：

- 供应商 API Key、OAuth 刷新令牌、代理订阅 URL 和桌面配置仍只保存在桌面端的安全存储中。
- 移动端负责配对、模型调用、模型与供应商状态、用量分析、节点测速和授权范围内的路由管理。
- 桌面端关闭或不可达时，移动端只显示带更新时间的本地缓存；不会绕过 ModelHub 直连供应商。
- 首版支持局域网和用户自有 VPN；不自建公共中继，不默认把网关暴露到公网。
- 移动访问默认关闭，必须由桌面端显式开启、审批设备和授予权限。

## 2. 架构决定

### 2.1 客户端结构

- `mobile/shared`：Kotlin Multiplatform，共享 API 客户端、领域模型、认证状态机、缓存策略和错误映射。
- `mobile/iosApp`：SwiftUI 原生界面，同时支持 iPhone 和 iPad。
- `mobile/androidApp`：Jetpack Compose 原生界面，通过 Window Size Class 同时支持手机、平板、折叠屏和分屏。
- `openapi/modelhub-openapi.yaml`：继续作为桌面网关与移动端的合同权威源。
- `Sources/ModelHubMobileAccess`：桌面端独立的移动访问服务，不改变现有仅回环监听的本地 API 默认行为。

选择 KMP 只共享业务逻辑，不共享界面。这样可以减少认证、重试、分页和错误语义的重复实现，同时让 iOS/iPadOS 遵循 Apple HIG，让 Android 使用 Material 3 Adaptive。

### 2.2 Apple 与 Android 产品形态

- Apple：一个同时支持 iPhone/iPad 的目标，建议沿用现有 Apple ID `6797847364` 和 Bundle ID `com.local.modelhub`，在获授权后向同一 App Store Connect 记录添加 iOS 平台，形成通用购买。
- Android：一个自适应 APK/AAB，建议应用 ID 使用 `com.local.modelhub`；手机和平板不拆成两个商店条目。
- 建议最低版本：iOS/iPadOS 17；Android 10（API 29）。实施前会用当前 Xcode、Android SDK 和商店要求再次核对。

### 2.3 配对与信任模型

1. 桌面端生成短时、单次配对会话，并显示二维码。
2. 二维码只包含服务地址、证书公钥指纹、一次性配对码和到期时间，不包含供应商秘密或长期访问令牌。
3. 移动端在 Secure Enclave/Keychain 或 Android Keystore 中生成设备密钥；配对请求通过证书固定的 TLS 连接提交公钥。
4. 桌面端显示设备名称和请求权限，由用户批准后签发按设备、按权限范围绑定的凭证。
5. 每次请求包含设备签名、时间戳和一次性 nonce；服务端拒绝重放、过期请求、权限越界和已撤销设备。
6. 桌面端可随时查看、降权或撤销设备；撤销不影响本地网关令牌和其他设备。

默认权限分为：

- `viewer`：目录、健康状态和聚合用量只读。
- `chat`：增加文字/媒体模型调用。
- `operator`：增加单节点测速、默认模型和路由调整；删除供应商、密钥和订阅仍只能在桌面端完成。

### 2.4 移动 API

新增独立、分页且最小化的移动接口，不直接暴露桌面配置对象：

- `POST /mobile/v1/pairing/complete`
- `GET /mobile/v1/bootstrap`
- `GET /mobile/v1/models?cursor=&limit=&query=&status=&capability=`
- `GET /mobile/v1/providers/health`
- `GET /mobile/v1/usage/summary?range=`
- `GET /mobile/v1/nodes`
- `POST /mobile/v1/nodes/{id}/latency-tests`
- `PATCH /mobile/v1/routes/{id}`
- `GET /mobile/v1/events`（前台 SSE；后台不保持常驻连接）

聊天和媒体调用继续复用现有 OpenAI 兼容接口，但使用设备权限令牌，不把桌面全局网关令牌复制到移动设备。

## 3. 自适应信息架构

### iPhone

- 底部标签：概览、对话、模型、用量、设置。
- 模型、节点和历史记录使用单列列表进入详情。
- 主要操作位于拇指可达区域，触控目标不小于 44×44 pt。

### iPad

- `NavigationSplitView` 侧栏 + 列表 + 详情。
- 支持横竖屏、Split View、Stage Manager、键盘快捷键和指针。
- 不放大 iPhone 页面；模型、节点和用量使用双栏或三栏信息密度。

### Android 手机

- Compact 宽度使用 Navigation Bar 和单列详情。
- 支持系统返回、预测返回、横竖屏及状态恢复。

### Android 平板/折叠屏

- Medium 使用 Navigation Rail；Expanded 使用持久侧栏。
- 模型、节点和会话使用 list-detail，自适应分屏和窗口尺寸变化。
- 不锁定方向或宽高比。

## 4. 功能阶段

### Phase 1：安全配对与只读概览

- 桌面端开启/关闭移动访问、二维码配对、设备批准与撤销。
- 移动端保存设备身份，显示连接状态、网关版本、默认模型和供应商健康摘要。
- 支持局域网连接、手动地址和用户自有 VPN；失败显示可操作原因。

### Phase 2：模型调用

- 流式文字对话、默认模型和按能力选择模型。
- 图片、语音、转录和视频任务按模型能力渐进开放。
- 对话历史默认仅保存在设备端并加密，不上传云端；用户可关闭保存或一键清除。
- 模型调用仍按现有计费和真实验证授权边界执行。

### Phase 3：健康、用量与节点

- 搜索/筛选模型，查看可用、隔离、待验证和需配置状态及原因。
- 聚合请求、Token、费用、成功率和延迟；默认不下载完整账本。
- 节点以卡片展示真实外网延迟、最近测试时间和失败原因。
- 只允许单节点或明确选中节点测速；批量测试需二次确认并有并发上限。
- `operator` 可调整默认模型和路由，所有写入带版本检查、审计和回滚。

### Phase 4：发布质量

- VoiceOver/TalkBack、Dynamic Type/字体缩放、深色模式、提高对比度和减少动态效果。
- iOS/iPadOS 模拟器与真机、Android 手机/平板/折叠屏模拟器与真机验收。
- App Store 隐私清单、本地网络用途说明、Google Play Data safety 和隐私政策同步。
- 发布、签名、商店记录和外部元数据修改在单独授权后执行。

## 5. 实施任务

### Task 1：冻结移动端合同与威胁模型

**验收标准：**

- 移动端永远拿不到供应商秘密和桌面全局网关令牌。
- 信任边界覆盖首次配对、证书轮换、请求重放、设备丢失、撤销和 VPN 场景。
- OpenAPI 明确分页、限流、错误码、权限范围和乐观并发版本。

**验证：** OpenAPI 校验、威胁模型人工复审、秘密字段负向测试设计完成。<br>
**依赖：** 无。<br>
**范围：** 中。

### Task 2：实现桌面端设备身份与配对状态机

**验收标准：**

- 配对码短时、单次使用；过期、重复和错误批准全部失败关闭。
- 设备公钥、权限和撤销状态持久化；秘密只进入 Keychain。
- 设备列表不显示令牌或私密 URL。

**验证：** 单元测试覆盖成功、过期、重放、撤销和并发批准。<br>
**依赖：** Task 1。<br>
**范围：** 中。

### Task 3：实现独立 TLS 移动访问服务

**验收标准：**

- 默认关闭且不改变现有 `127.0.0.1` 本地 API。
- 只暴露移动 API allowlist；未认证、越权、重放和证书不匹配失败关闭。
- 监听端口在实施时通过 ProjectDock 分配和复核，不使用硬编码或 `port 0`。

**验证：** TLS/认证合同测试、模糊输入测试、并发和资源释放测试。<br>
**依赖：** Task 1、2。<br>
**范围：** 中。

### Task 4：建立 KMP 共享客户端

**验收标准：**

- Android/iOS 共用模型、错误、分页、认证和重试语义。
- 平台安全存储通过接口注入，公共代码不接触明文持久化。
- 只对幂等读请求执行一次受控重试；写请求依赖幂等键和版本检查。

**验证：** `shared` 公共测试、Android JVM 测试、iOS simulator 测试。<br>
**依赖：** Task 1。<br>
**范围：** 中。

### Task 5：iPhone/iPad 原生壳与配对切片

**验收标准：**

- 同一 target 在 iPhone 使用 TabView，在 iPad 使用 NavigationSplitView。
- 扫码、手动地址、权限拒绝、离线和撤销状态都有明确界面。
- 支持 VoiceOver、Dynamic Type、深浅色和 44 pt 触控目标。

**验证：** SwiftUI 单元/UI 测试；iPhone SE/Pro Max 与 iPad 分屏快照。<br>
**依赖：** Task 2、3、4。<br>
**范围：** 中。

### Task 6：Android 手机/平板原生壳与配对切片

**验收标准：**

- Compact/Medium/Expanded 宽度分别使用 Navigation Bar、Rail 和持久侧栏。
- 手机、平板、折叠/分屏切换时保留当前选择和表单状态。
- 设备密钥保存在 Android Keystore，发布构建默认禁止明文流量。

**验证：** Compose UI 测试；手机、平板和可调整窗口截图与旋转测试。<br>
**依赖：** Task 2、3、4。<br>
**范围：** 中。

### Checkpoint A：安全纵向切片

- 两个平台均能从全新安装完成配对、查看概览、撤销后立即失效。
- 桌面本地 API 回归测试全部通过。
- 移动访问关闭时没有非回环监听。

### Task 7：流式对话与默认模型

**验收标准：**

- 首次进入自动采用服务器返回的默认文字模型；无默认时给出可用候选。
- 流式取消、超时、断线重连和重复提交语义一致。
- 提示词和响应正文不进入服务端日志或分析账本。

**验证：** mock 流式合同测试、取消/重连测试、真机局域网非计费桩验收。<br>
**依赖：** Checkpoint A。<br>
**范围：** 中。

### Task 8：模型目录、供应商健康与节点卡片

**验收标准：**

- 大模型目录分页和虚拟化，搜索/筛选不会一次加载全部记录。
- 状态原因、最后验证时间和能力标签准确显示。
- 节点测速测量“通过该节点访问指定外网探针”的延迟，而不是本地按钮响应时间。

**验证：** 1,000 条合成目录性能测试、节点成功/超时/TLS/DNS 失败测试。<br>
**依赖：** Checkpoint A。<br>
**范围：** 中。

### Task 9：用量分析与路由操作

**验收标准：**

- 默认只请求聚合数据，时间范围和币种清晰，汇率带来源和生效时间。
- 路由写入要求 `operator`、版本匹配和明确确认；冲突不覆盖新状态。
- 每次移动写入形成不含秘密的审计事件，并能回滚上一版本。

**验证：** 授权矩阵、并发冲突、审计脱敏和回滚测试。<br>
**依赖：** Task 8。<br>
**范围：** 中。

### Checkpoint B：功能闭环

- iPhone/iPad/Android 手机/Android 平板完成配对、对话、模型浏览、用量查看、节点测速和受控路由调整。
- 现有 macOS 与 Windows 行为无回归。
- 未经明确授权不执行真实计费模型批量测试。

### Task 10：性能、安全与可访问性收口

**验收标准：**

- 建立冷启动、首屏、配对、目录滚动、流式响应、内存和电量基线。
- 完成依赖漏洞、秘密、日志、备份、网络安全配置和移动存储检查。
- 屏幕阅读器、最大字体、提高对比度、减少动态效果和键盘导航通过。

**验证：** 可复现基准报告、依赖/秘密扫描、真机无障碍清单。<br>
**依赖：** Checkpoint B。<br>
**范围：** 中。

### Task 11：CI、签名与商店候选

**验收标准：**

- PR 构建覆盖 Swift/macOS 回归、KMP、Android 和 iOS simulator。
- Android 生成未发布 AAB；Apple 生成未上传 Archive，秘密均来自受保护环境。
- 商店文案、隐私声明和截图仅描述已经验收的能力。

**验证：** CI 全绿、制品哈希、签名检查、安装与升级测试。<br>
**依赖：** Task 10。<br>
**范围：** 中。

## 6. 性能与安全预算

以下为首轮预算，必须以真机基线报告确认，不以单次模拟器结果宣称达标：

- 已配对设备在局域网内，连接握手 p95 目标不高于 800 ms。
- 有缓存时首屏可交互目标不高于 1.5 s；目录首批数据目标不高于 1 s。
- 目录和账本必须分页；后台不轮询，不保持永久 SSE。
- 同一设备最多一个前台事件流；重连采用有上限指数退避。
- 任何性能优化不得放宽 TLS、签名、授权、重放保护、输入限制或秘密隔离。

## 7. 当前环境与已知阻塞

- 当前已具备 Xcode 27、Swift 6.4、JDK 17、Gradle 9.6、Android Gradle Plugin 9.4、Android SDK 35/36 和 Build Tools 34/35/36；共享 Android 目标已迁移到官方 Android-KMP 插件。
- iPhone、iPad、Android 手机和 Android Expanded 宽度模拟器界面已启动验收；iOS arm64 设备目标也已完成免签名编译。尚未完成四类真实设备、相机扫码、局域网/VPN 和证书固定的端到端验收。
- 现有 Bearer API 继续固定监听 `127.0.0.1:11435`；移动端使用默认关闭的独立 TLS 1.3 服务和 `/mobile/v1` 白名单，不直接暴露现有本地 API。
- App Store Connect 添加 iOS 平台、Google Play 建立应用、证书/签名、上传和发布均是后续外部写入，不包含在本计划确认本身。

## 8. 回滚

- 移动访问由独立开关控制，关闭后恢复“仅本机回环 API”的既有状态。
- 移动端协议版本化；旧客户端只能访问兼容的只读接口，不能绕过服务端策略。
- 配对与设备存储使用独立命名空间，回滚移动功能不删除现有供应商、路由、模型健康或用量记录。
- 每个阶段形成独立提交和验证检查点，不把四个平台一次性合并成不可回退的大提交。

## 9. 已确认的实施参数

建议按以下默认值启动开发：

1. 移动端是桌面 ModelHub 的安全伴侣，不在手机保存供应商密钥。
2. 采用 KMP 共享逻辑 + SwiftUI iOS/iPadOS + Jetpack Compose Android。
3. 首版支持局域网和用户自有 VPN，不建设公共云中继。
4. Apple 端后续添加到现有 App 记录，名称继续使用“模型枢纽 ModelHub”。
5. 首个可交付切片为“安全配对 + 概览”，通过后再加入对话、节点和管理写入。

## 10. Phase 1 实施证据（2026-09-25）

- 桌面端：已实现默认关闭的独立 TLS 服务、短时单次配对、桌面批准/拒绝、设备撤销、P-256 请求签名、时间偏差与 nonce 重放保护、只读概览最小化输出。
- 共享层：Kotlin Multiplatform 合同、严格 JSON、跨平台 SHA-256、请求规范化、配对与概览客户端已完成；Android JVM 与 iOS Simulator 公共测试通过。
- Apple：同一 SwiftUI 目标支持 iPhone `TabView` 与 iPad `NavigationSplitView`；设备私钥使用 Secure Enclave（模拟器回退 Keychain），TLS 固定、二维码扫描、离线缓存和撤销状态已接入；iPhone/iPad 模拟器启动通过，arm64 设备目标编译通过。
- Android：同一 Compose 目标支持 Compact/Medium/Expanded，自带 Google Code Scanner（不申请常驻相机权限）；设备私钥使用 Android Keystore，禁止明文流量并固定 TLS 证书；手机与 Expanded 宽度模拟器启动通过，Debug APK、R8 Release APK 与 Lint 均通过。构建已迁移到 Gradle 9.6、AGP 9.4 和官方 Android-KMP 插件，Kotlin 2.4 元数据可被 Lint/R8 正确解析。
- 身份清理：iOS 与 Android 的“忘记设备”会先删除 Secure Enclave/Keychain 或 Android Keystore 私钥，再清除设备 ID 和概览缓存；密钥删除异常时失败关闭。
- 回归：桌面移动模块测试、真实本机 TLS 握手测试、KMP 合同测试、Android 单元测试均通过；现有桌面回环 API 未改为局域网监听。
- 未完成：真机扫码与局域网/VPN E2E、证书轮换体验、VoiceOver/TalkBack 全量验收、商店隐私元数据、签名归档和外部发布。因此 Checkpoint A 尚未关闭。

## 11. 参考依据

- Apple App ID 与多平台：<https://developer.apple.com/help/account/identifiers/register-an-app-id>
- Apple 添加平台与通用购买：<https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms>
- Apple 本地网络隐私：<https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy>
- Apple Keychain：<https://developer.apple.com/documentation/security/keychain-services>
- Android 自适应布局：<https://developer.android.com/develop/adaptive-apps/guides/canonical-layouts>
- Android 网络安全配置：<https://developer.android.com/privacy-and-security/security-config>
- Android 安全建议：<https://developer.android.com/privacy-and-security/security-tips>
- Kotlin Multiplatform：<https://kotlinlang.org/multiplatform/>
- Android-KMP 插件：<https://developer.android.com/kotlin/multiplatform/plugin>
- Kotlin 与 AGP/R8 兼容矩阵：<https://developer.android.com/build/kotlin-support>
