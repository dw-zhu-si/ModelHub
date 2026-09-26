# ModelHub 移动安全伴侣

此目录承载 iPhone、iPad、Android 手机和 Android 平板客户端。移动端只作为桌面 ModelHub 的安全伴侣，不保存供应商 API Key、OAuth 刷新令牌、代理订阅 URL 或桌面全局网关令牌。

## 目录

- `shared/`：Kotlin Multiplatform 合同、认证状态机、请求签名规范和只读概览客户端。
- `iosApp/`：SwiftUI iPhone/iPad 壳、Secure Enclave/Keychain 设备身份、证书固定与二维码扫描。
- `androidApp/`：Jetpack Compose 自适应壳、Android Keystore、证书固定与 Google Code Scanner。

当前切片只实现安全配对和只读概览。对话、模型目录、用量、节点测速和路由写入仍按 `docs/MOBILE_IMPLEMENTATION_PLAN.md` 分阶段开发。

## 安全流程

1. 用户在 Mac 明确开启移动访问；现有 `127.0.0.1:11435` API 不变。
2. 桌面生成两分钟有效、只能使用一次的二维码；二维码只有服务地址、TLS SHA-256 指纹、配对会话 ID、一次性秘密和到期时间。
3. 移动端在平台安全存储生成 P-256 私钥，通过固定证书的 TLS 1.3 连接提交设备公钥。
4. Mac 显示设备名称与公钥指纹；只有用户批准后才授予默认 `viewer` 权限。
5. 只读请求使用设备 ID、时间戳、nonce 和 P-256 签名；服务端拒绝过期、重放、越权和已撤销设备。
6. 用户选择“忘记此设备”时，客户端先删除平台安全存储中的设备私钥，再清除本地绑定；任何密钥删除失败都会停止清理并提示错误，避免留下看似已解绑但仍可签名的身份。

移动端不会持久化一次性配对秘密。只读概览缓存不包含供应商密钥、Base URL、订阅 URL、提示词或响应正文。

## 构建与测试

环境要求：JDK 17、Gradle 9.6、Android Gradle Plugin 9.4、Android SDK 36、Xcode 27；最低系统为 Android 10（API 29）和 iOS/iPadOS 17。共享 Android 目标使用官方 `com.android.kotlin.multiplatform.library` 插件，避免旧插件的 Kotlin 2.4 元数据解析问题。

共享层与 Android：

```bash
cd mobile
./gradlew :shared:allTests :androidApp:testDebugUnitTest :androidApp:assembleDebug :androidApp:assembleRelease :androidApp:lintDebug
```

Debug APK 输出到：

```text
mobile/androidApp/build/outputs/apk/debug/androidApp-debug.apk
```

iOS/iPadOS 模拟器：

```bash
cd mobile/iosApp
xcodebuild \
  -project ModelHubMobile.xcodeproj \
  -scheme ModelHubMobile \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath /tmp/modelhub-mobile-ios-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

iOS arm64 设备目标的免签名编译检查：

```bash
cd mobile/iosApp
xcodebuild \
  -project ModelHubMobile.xcodeproj \
  -scheme ModelHubMobile \
  -configuration Debug \
  -sdk iphoneos \
  -derivedDataPath /tmp/modelhub-mobile-ios-device-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

以上命令只做本地开发验证；不会签名、上传或发布。

## 当前验收边界

- 已验证：KMP 公共测试、Android JVM 测试、Android Debug APK、经 R8 收缩的未签名 Release APK、Android Lint、iOS Simulator 通用架构构建、iOS arm64 设备目标编译，以及四类自适应界面的模拟器启动。
- 尚未验证：真实 iPhone/iPad/Android 手机/Android 平板上的相机扫码、局域网权限、VPN、系统安全存储、后台/前台切换和设备撤销 E2E。
- 未发布：没有创建商店条目、签名归档、上传 TestFlight/Google Play 或改变现有桌面版本。

详细威胁与剩余风险见 [`../docs/MOBILE_SECURITY_THREAT_MODEL.md`](../docs/MOBILE_SECURITY_THREAT_MODEL.md)。
