# 凭证池与 OAuth 合规边界

最后复核：2026-08-30

本文说明 ModelHub 的凭证池可以做什么、明确不做什么，以及个人自用时仍需遵守的边界。它是产品与工程控制说明，不是法律意见；供应商条款、账号权限和地区限制发生变化时，应以供应商最新官方文件为准。

## 结论

ModelHub 只允许“开发者 API 凭证池”，不把消费者订阅账号转换成网关凭证。个人自用不会自动获得绕过服务条款、速率限制、额度或产品边界的许可。

可以进入池的凭证：

- 用户自己创建、付费并有权使用的官方 Developer API Key；
- 供应商官方明确支持 Developer API 的 OAuth，且使用用户自己的开发者项目、官方授权端点、最小范围和合规计费项目；
- 供应商官方支持的 ADC、WIF 或工作负载身份。ModelHub 当前没有启用通用工作负载身份适配器，遇到该类型会失败关闭。

不能进入池的内容：

- ChatGPT、Claude、Gemini Apps 等消费者订阅的 Cookie、会话 Token、刷新 Token或本地登录文件；
- Codex、Claude Code、Gemini CLI 或浏览器配置目录中由官方客户端管理的登录材料；
- 抓取的 `auth.json`、浏览器存储、私密 URL、设备码、客户端内部令牌或逆向得到的凭证；
- 用多个账号在 429、配额不足或月度额度耗尽后自动换号继续调用的逻辑；
- 冒充官方客户端、复用官方公共 Client ID、修改回调地址或规避供应商限制的流程。

消费者订阅仍可以在其官方产品中正常使用；ModelHub 最多可以在未来提供“不含秘密的账号状态卡片”和“打开官方客户端”入口，但不会读取或代理该订阅身份。

## 当前实现状态

| 能力 | 当前状态 | 运行边界 |
| --- | --- | --- |
| 多个 Developer API Key | 已实现 | 每条秘密单独保存到 macOS Keychain；配置只保存 UUID、标签、优先级、启停和用途 |
| 手动选择凭证 | 已实现 | 只使用用户明确选择且仍合规、仍启用的条目 |
| 失效凭证故障转移 | 已实现 | 仅对明确的 401/403 或 OAuth 刷新端点返回的 400/401/403 标记该凭证不可用 |
| 429/额度轮换 | 明确禁止 | 原响应直接返回，不选择下一条凭证 |
| 网络错误/5xx 轮换凭证 | 明确禁止 | 可由模型路由处理不同目标，但不会借此轮换同一供应商的凭证 |
| Gemini Developer OAuth 策略与刷新运行时 | 已实现 | 只接受官方 Google 端点、`cloud-platform` 范围、用户自己的计费项目和未过期官方证据 |
| Gemini 交互式登录 | 已实现 | 用户显式发起；使用系统默认浏览器、PKCE S256、一次性 state/nonce 和精确 `127.0.0.1:11469/oauth/callback`，令牌只写入 Keychain |
| Claude/OpenAI 消费者订阅池 | 不实现 | 消费者订阅和 Developer API 是不同产品边界 |
| ADC/WIF 工作负载身份 | 预留但未启用 | 没有受支持适配器时失败关闭，不回退为令牌导入 |

## Gemini Developer OAuth 的合规前置条件

只有以下条件同时满足时，ModelHub 的 Gemini OAuth 运行时才允许使用已正式登记的开发者凭证：

1. 用户拥有并控制自己的 Google Cloud 项目；
2. 项目已启用 Generative Language API；
3. 已配置 OAuth 同意屏幕，开发阶段只加入自己的测试用户；
4. 使用用户项目中创建的 Desktop OAuth Client，不使用他人的 Client ID；
5. 授权端点固定为 `https://accounts.google.com/o/oauth2/v2/auth`；
6. 令牌端点固定为 `https://oauth2.googleapis.com/token`；
7. 当前允许范围固定为 `https://www.googleapis.com/auth/cloud-platform`；
8. 请求通过 Bearer Token 鉴权，并带用户自己的 `x-goog-user-project` 计费项目；
9. 使用 PKCE S256、`state` 和 `nonce`，令牌只进入 Keychain；
10. 官方证据已复核且未过期。证据过期、端点或范围变化时自动失败关闭。

交互式授权必须由用户在凭证池中显式发起。ModelHub 不替用户创建 Cloud 项目、同意屏幕或 OAuth Client，也不把消费者订阅登录误当作 Developer API 授权。应用先在固定 IPv4 回环端口建立一次性监听，再用系统默认浏览器打开 Google 官方 HTTPS 授权页；只接受精确方法、Host、路径、state 和授权码，使用 PKCE S256，取消、超时、慢连接、错误回调、范围不足或 token 交换失败均不保存秘密。成功后只把绑定供应商身份和官方 origin 的访问/刷新令牌写入 macOS Keychain。

## 故障处理规则

| 事件 | 是否换凭证 | 处理方式 |
| --- | --- | --- |
| 2xx | 否 | 记录该凭证恢复可用，只写入凭证 UUID，不记录秘密 |
| 400（仅 OAuth 刷新端点明确拒绝） | 仅故障转移模式 | 标记该 OAuth 凭证失效，再尝试下一条合规开发者凭证 |
| 401/403 | 仅故障转移模式 | 标记单条凭证失效；不会把供应商或模型整体隔离 |
| 408、DNS、TLS 建连、断网 | 否 | 原样按网络/路由韧性规则处理，不换号 |
| 429、额度不足、预算耗尽 | 否 | 原样返回，绝不组合多个账号额度 |
| 5xx | 否 | 可尝试其他模型路由目标，不轮换同供应商凭证 |

## 安全与隐私控制

- 每条池凭证使用不可推测 UUID 作为 Keychain account；删除卡片时同步删除对应秘密。
- 配置备份、用量账本、请求日志和健康指标不包含 API Key、访问令牌、刷新令牌、Cookie、授权码或 PKCE verifier。
- 用量账本只记录请求 ID、工作区/虚拟密钥/供应商/凭证 UUID、模型、状态码、延迟、Token 与估算费用。
- OAuth 刷新使用短超时、禁用 Cookie、拒绝重定向、限制响应大小并合并同一凭证的并发刷新。
- OAuth 项目 ID 会执行字符与长度校验，防止通过 `x-goog-user-project` 注入额外请求头。
- 任何消费者订阅条目即使被旧配置构造出来，也会被强制禁用且无法进入自动选择。

## 官方依据

- [OpenAI 使用条款](https://openai.com/policies/row-terms-of-use/)
- [OpenAI Codex 身份验证](https://developers.openai.com/codex/auth)
- [ChatGPT 与 API 计费相互独立](https://help.openai.com/en/articles/9039756-managing-billing-for-chatgpt-and-the-api-platform)
- [Anthropic 消费者条款](https://www.anthropic.com/legal/consumer-terms)
- [Claude Code 登录说明](https://docs.anthropic.com/en/docs/claude-code/getting-started)
- [Claude 订阅与 API 计费相互独立](https://support.anthropic.com/en/articles/9876003-i-subscribe-to-a-paid-claude-ai-plan-why-do-i-have-to-pay-separately-for-api-usage-on-console)
- [Gemini API OAuth 官方文档](https://ai.google.dev/gemini-api/docs/oauth)
- [Gemini API 附加服务条款](https://ai.google.dev/gemini-api/terms)
- [Google APIs 服务条款](https://developers.google.com/terms)
- [Apple ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)

## 上线前复核清单

- [x] 没有消费者订阅 Token/Cookie/登录文件导入入口；
- [x] 没有 429、额度或预算耗尽后的凭证轮换；
- [x] 当前启用的 Gemini OAuth 具有官方允许列表、固定端点、最小范围和证据有效期；其他供应商 OAuth 默认失败关闭；
- [x] 所有秘密只存在于 Keychain，配置导出与本轮秘密扫描无秘密；
- [x] OAuth 取消、超时、错误回调、范围扩大和证据过期均失败关闭，并由定向自动化覆盖；
- [ ] 真实连接测试和可能计费调用仍由用户单独确认；
- [ ] 发布前重新核对供应商条款与 App Store 审核要求。
