# 模型枢纽 ModelHub

[English](README.en.md) · 简体中文

模型枢纽是一款原生 macOS 应用，用一个本机 OpenAI 兼容接口统一管理多家大模型 API，并通过稳定别名进行模型路由、轮询、权重分流和故障转移。

## 已实现

- 原生 SwiftUI 管理界面，支持浅色/深色模式和 VoiceOver 标签。
- 支持跟随系统或在应用内即时切换 11 种界面语言：简体中文、繁体中文、英语、日语、韩语、西班牙语、法语、德语、葡萄牙语（巴西）、俄语和阿拉伯语；Widget 跟随 macOS 系统语言。
- `GET /health`、可用模型/供应商/聚合用量目录、`POST /v1/chat/completions` 与 `POST /v1/responses`。
- `/v1/models` 默认只输出本机最近状态明确可用的模型；隔离、不可用、未知状态、已停用供应商及无可用目标的路由都不会出现在目录中。`/v1/models/available` 保留为兼容别名，两者都不会产生上游调用。
- 原生能力端点：图像 `/v1/images/generations`、视频 `/v1/videos/generations`、任务查询 `/v1/tasks/{id}`、语音 `/v1/audio/speech`、转录 `/v1/audio/transcriptions`、向量 `/v1/embeddings`、重排 `/v1/rerank`。
- 原生透传保留查询参数顺序、重复键、无值开关和 `+` 字面值，避免厂商签名、回调或多值参数失真。
- 路由策略：优先级故障转移、轮询、权重随机、最低延迟、最高稳定性、最低成本、最大上下文和综合评分；可按工具、视觉、音频等能力标签排除明确不兼容目标。
- 韧性控制：本机每分钟限流、单目标并发上限、连续失败熔断、冷却、指数退避和最大回退次数；不会对同一目标自动重放一次可能计费的调用。
- 成本与分析：手工价格来源/更新时间、模型月 Token 配额、月度预算预警/硬限制，以及按模型和供应商聚合的成功率、延迟、Token、费用与上下文节省量；未知价格保持“未知”。
- 本地备份支持 10 MiB 上限、导入预览和自动回滚副本；备份始终排除 Keychain。
- 本机 Agent 管理面提供带独立令牌的只读 MCP、A2A 与 ACP stdio 进程，只输出状态、聚合用量和未隔离模型。
- OpenAI 兼容聊天与 Responses API 支持工具、多模态字段原样透传；Anthropic 与 Gemini 聊天目标会把工具、工具结果和多模态内容转换为供应商原生内容块，并把原生响应与 SSE 转回 OpenAI Chat Completions。`stream: true` 使用增量分块转发，客户端断开会取消上游读取。
- 内置上下文保守整理默认关闭，不下载第三方二进制，并跳过代码块、工具参数和结构化多模态内容。
- CLI 辅助只生成和复制无密钥预览，不自动改写其他客户端配置。
- 模型可用性：支持全部、单供应商和单模型检测；失败、缺少凭证或待适配模型会记录并隔离，路由、一键测试和直接调用均不再触发该模型，直到在应用中人工标记为可用。
- 检测会区分“需配置密钥”和“原生协议已接入”。生成类模型不会被错误送到聊天端点，也不会因一键测试自动产生生成费用。
- 模型目录：供应商分栏、模型搜索、状态筛选、延迟和最近检测结果。
- 密钥管理：明确显示钥匙串保存状态，可在供应商编辑页覆盖或删除 API Key。
- 仅监听 `127.0.0.1`，端口固定为 `11435`，并可由 ProjectDock 统一启停。
- 网关 Bearer 令牌和供应商 API Key 均保存到 macOS 钥匙串；后台启动和请求处理禁止弹出授权框，只有用户主动显示、复制或修改密钥时才允许系统授权交互。
- 支持在设置页启停 macOS 登录时自动启动，持久保存用户选择，并在应用更新或重启后自动恢复注册状态；若 macOS 要求批准，会明确显示系统登录项状态。
- 默认以菜单栏后台应用运行，不显示程序坞图标且启动时不弹主窗口；可从菜单栏的 ModelHub 图标打开控制台、启停本地 API 或退出。
- 提供桌面状态小组件，显示服务、可用模型、供应商、路由、请求量和成功率；共享快照不含令牌、API Key、提示词或响应正文。
- 日志不记录 API Key、提示词或模型响应正文。
- OpenAI 协议直连：OpenAI、Azure OpenAI、DeepSeek、Qwen、Kimi、GLM、Grok、Groq、Mistral、Ollama，以及任意 OpenAI 兼容服务。
- 原生协议转换：Anthropic Claude、Google Gemini、APIMart Seedance、Agnes 图像/视频、百炼语音，以及 OpenAI 风格的图像、音频、Embedding、Rerank 接口。
- 厂商专用动作协议：`/v1/native` 只向已配置供应商的固定主机透传原始 HTTP 方法、路径、参数、正文与响应；网关访问令牌不会转发，上游密钥由 Keychain 自动注入。
- 本地 HTTP 入口支持 `Content-Length` 与 `chunked` 请求体，错误方法返回 405，不完整或冲突的请求会明确拒绝；请求头限制为 64 KiB，请求体限制为 32 MiB。
- 资源优化：模型健康索引增量维护，模型/供应商目录响应按配置缓存；高频运行状态在 500 毫秒窗口内合并落盘，网关令牌在内存中复用，空闲连接 30 秒自动回收，降低 Keychain 访问、CPU、主线程刷新和磁盘写入。

## 构建

要求 macOS 14 或更高版本以及 Xcode 16 或更高版本。

```bash
swift test
./scripts/package_app.sh
open ./dist/ModelHub.app
```

打包脚本生成包含 arm64 与 x86_64 的 Universal `dist/ModelHub.app`。默认使用 ad-hoc 签名；发布时可通过 `MODELHUB_SIGNING_IDENTITY` 指定 Developer ID Application 身份，并启用 hardened runtime 与时间戳。Apple 公证需在签名打包后单独提交。

当前源码版本为 1.9.0（构建号 17）。`dist` 中的本地验证包默认采用 ad-hoc 签名；Developer ID 签名、公证、App Store 签名和安装需作为独立发布步骤验证，不能沿用旧版本的公证结论。

## 使用

1. 打开“模型供应商”，添加供应商、API Key 和模型名称。
2. 如需检测，点击“一键测试”并确认可能产生的上游调用费用；也可按供应商或单模型测试。
3. 打开“模型路由”，创建别名，例如 `smart`，并配置一个或多个上游目标。
4. 在“服务设置”复制本地接口地址和访问令牌。
5. 把现有 OpenAI SDK 的 Base URL 改为 `http://127.0.0.1:11435/v1`（保留末尾 `/v1`）。

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "smart",
    "messages": [{"role": "user", "content": "你好"}],
    "stream": false
  }'
```

完整合同见 [openapi/modelhub-openapi.yaml](openapi/modelhub-openapi.yaml)。

只查询本机最近状态明确可用的模型（不会调用供应商）：

```bash
curl http://127.0.0.1:11435/v1/models/available \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN"
```

视频示例：

```bash
curl http://127.0.0.1:11435/v1/videos/generations \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "APIMart Seedance/doubao-seedance-2.0",
    "prompt": "小猫对着镜头打哈欠",
    "resolution": "720p",
    "size": "16:9",
    "duration": 5
  }'
```

云雾 Midjourney、Suno、可灵、PixVerse 等动作型接口使用原生透传。先用
`GET /v1/providers` 查看供应商 ID，再把厂商文档中的原生路径放入 `path`：

```bash
curl -X POST 'http://127.0.0.1:11435/v1/native?provider=云雾%20API&model=mj_imagine&path=/mj/submit/imagine' \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"小猫对着镜头打哈欠"}'
```

`model` 用于记录成功/失败与执行隔离；`path` 必须是供应商主机内以 `/`
开头的路径，不能包含主机名或 `..`。除 `provider`、`model`、`path` 外的
查询参数会原样传给上游。

## 协议边界

- OpenAI 兼容供应商会保留请求中的额外字段，并把路由模型名替换为真实上游模型名。
- Anthropic 与 Gemini 适配器覆盖文本、system、工具定义、工具调用/结果、图像等多模态内容和原生 SSE 转换。无法安全表示的供应商内容类型会返回 400，不会静默丢弃字段；工具仍由调用方执行，ModelHub 不会自动执行模型输出。
- OpenAI 兼容供应商的聊天与 Responses SSE 会在收到上游数据块后立即以 HTTP chunked 传输继续转发；网关不会等待完整响应。
- 一键测试会真实请求聊天模型；图像、视频、语音、转录、向量与重排模型只验证本地协议适配，不会自动发起可能计费的上游生成。真实原生请求成功后才会记录为“可用”。
- 原生端点保留供应商扩展字段和原生响应。不同厂商同类模型的可选参数并不完全相同，请按对应厂商文档组织请求正文。
- 原生透传解决的是供应商动作协议差异，不会猜测或改写厂商参数；调用路径和正文仍以该供应商当前文档为准。
- 已隔离模型在 API 调用时返回 HTTP 409 `model_quarantined`，不会请求上游。应用模型列表中的盾牌按钮用于人工解除隔离并标记为可用；更新密钥不会自动清除隔离记录。
- 批量检测最多同时调用 3 个模型，单次超时 30 秒，会使用已保存在 Keychain 的供应商密钥并可能产生费用。
- “支持供应商”表示协议与配置入口已实现，不代表用户账户已购买模型权限，也不代表任何真实 API Key 已通过在线连通性验证。

## 开源与致谢

ModelHub 以 [Apache License 2.0](LICENSE) 开源。路由、韧性、预算、上下文、协议和本机 Agent 功能族参考了 MIT 许可的 [OmniRoute](https://github.com/diegosouzapw/OmniRoute) 项目理念，并使用原生 Swift/macOS 能力实现；完整声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

安全问题请按 [SECURITY.md](SECURITY.md) 私下报告；贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。
