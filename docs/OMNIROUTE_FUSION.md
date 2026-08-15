# OmniRoute 功能融合审计与实施边界

## 审计基线

- 上游项目：[diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute)
- 审计提交：`7163081f5ed2a2104e85c31bfd1588033d43c580`
- 上游版本：`3.8.50`
- 审计日期：2026-08-04
- 许可证：MIT

本文件按功能族追踪融合状态。“功能等价”指在原生 macOS/Swift 架构中提供同等用户结果，
不要求复制 OmniRoute 的 Node.js、Electron、Web/PWA 或安装器实现。当前批次只借鉴公开功能边界，
没有复制或执行 OmniRoute 源码；后续若移植实质代码，必须同时加入其 MIT 版权声明。

## 当前已具备或本批次已完成

| 功能族 | ModelHub 状态 | 说明 |
|---|---|---|
| 通用兼容网关 | 已具备 | 本机 `/v1` API、Bearer 认证、供应商转发 |
| 组合/别名路由 | 已具备 | 优先级故障转移、轮询、权重随机 |
| 多层故障规避 | 已具备基础能力 | 调用失败记录健康状态，后续调用跳过隔离目标 |
| 模型健康与隔离 | 已完成强化 | `/v1/models`、路由和直接调用都只使用明确可用模型 |
| 多模态与原生协议 | 已具备 | 聊天、图像、视频、语音、转录、Embedding、Rerank、原生透传 |
| 本地优先与密钥保护 | 已完成强化 | Keychain 保存；后台禁止弹出授权窗口 |
| 请求观测 | 已具备基础能力 | 本地请求量、成功率、耗时和脱敏日志 |
| 桌面运行体验 | 本批次完成 | 登录时启动开关、WidgetKit 状态小组件、`/v1` Base URL 直接复制 |

## 本机权限边界内已原生完成（1.8.0）

| 功能族 | 完成状态 | 实现与验证 |
|---|---|---|
| 智能组合策略 | 已完成 | 最低延迟、最高稳定性、最低成本、最大上下文、综合评分和能力标签；确定性测试覆盖，隔离目标仍在最外层排除 |
| 韧性控制 | 已完成 | 每分钟限流、单目标并发、连续失败熔断、冷却、指数退避和最大回退；只切换目标，不自动重放同一计费调用 |
| 配额与成本 | 已完成 | 路由目标支持上下文、能力、手工价格来源/更新时间和月 Token 配额；月预算支持预警和硬阻断，未知价格保持未知 |
| 分析面板 | 已完成 | 按请求模型、供应商和真实模型统计成功率、延迟、Token、费用和上下文节省；不持久化正文 |
| 本地备份 | 已完成 | 10 MiB 版本化 JSON、导入预览、导入前自动回滚和一键恢复；Configuration 模型不含 Keychain 字段 |
| 本地 Agent 协议 | 已完成 | MCP Streamable HTTP、A2A JSON-RPC/Agent Card、ACP v1 stdio；独立 Agent 令牌和只读快照，非本机 Origin 拒绝 |
| 协议覆盖 | 已完成 | 通用协议 Chat/Responses 保留工具和多模态结构；Anthropic/Gemini 转换工具、工具结果、多模态内容与原生 SSE；客户端断开取消读取，无法安全表示的内容明确拒绝 |
| 上下文优化 | 已完成 | 内置保守文本整理、默认关闭；跳过代码围栏、多模态结构和工具参数，不下载外部组件 |
| CLI 配置辅助 | 已完成 | 应用只生成、显示和复制无密钥配置预览，不自动修改其他客户端文件，因此不存在静默覆盖风险 |

## 协议依据

- 通用协议保留 Responses 流式事件、工具调用与视觉输入结构，并以本项目自动化测试和 OpenAPI 合同作为实现基线。
- MCP 传输与只读工具：[Transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)、[Tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)。
- A2A Agent Card 与 JSON-RPC：[A2A v0.3.0 Specification](https://a2a-protocol.org/v0.3.0/specification/)。
- ACP 初始化、会话与 stdio：[Initialization](https://agentclientprotocol.com/protocol/v1/initialization)、[Session Setup](https://agentclientprotocol.com/protocol/v1/session-setup)、[Transports](https://agentclientprotocol.com/protocol/v1/transports)。

## 1.8.0 验证结论

- 自动化测试覆盖隔离目录、智能路由、韧性、成本、备份、Agent 工具、工具/多模态透传和真实首块流式时序。
- ACP 独立进程完成 `initialize` 与 `session/new` 实际 stdio 握手。
- Developer ID 签名包已安装并在 `127.0.0.1:11435` 运行；`/health` 返回正常，受保护目录无令牌返回 401，非本机 Agent Origin 返回 403。
- 未调用任何真实供应商接口，未执行本节下方列出的高影响能力。

## 必须单独授权的高影响能力

以下功能会改变系统网络、导入外部凭证、公开本机服务或执行下载内容。实现代码可以在
独立分支/阶段设计，但在用户明确选择权限边界前，不接入、不启用、不迁移真实数据：

- 从 Claude、Codex、Gemini、浏览器或其他 CLI 自动读取、导入、刷新 OAuth/会话令牌。
- Web-cookie 认证、账号池、多账号自动轮换和凭证导出。
- 公网隧道、远程模式、云中继、远程控制面或对 `0.0.0.0` 监听。
- 系统 HTTP/SOCKS 代理、透明代理、MITM、安装或信任根证书。模型专用代理订阅已在用户明确授权后实现，但只使用回环监听与用户已安装的 Mihomo，不修改系统代理。
- 自动下载并执行 RTK、Caveman、LLMLingua 或其他外部压缩/代理工具。
- 云同步、远程备份、云端 Agent、真实第三方账号写入与付费 API 自动探测。

## 不直接移植、改做原生等价能力

- OmniRoute 的 Electron/Web/PWA 界面、Node 服务管理器、npm/pnpm/Docker/Nix 安装链路。
- Web 浏览器扩展、社区榜单、游戏化、捐赠与项目运营模块。
- 与 ModelHub 原生 macOS 应用重复的托盘、更新器和桌面壳层。

这些部分不进入 Swift 应用代码；若确有用户价值，按 macOS 原生交互和发布模型重新设计。

## 完成定义

不能用“列入计划”替代“已经融合”。每个功能族只有在源码实现、自动化测试、应用内入口、
权限说明、迁移/回滚和真实运行探针均通过后，才可标记为完成。高影响能力还必须保留用户的
明确选择记录，并默认关闭。
