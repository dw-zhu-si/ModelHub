# 内置上游公开参考价与汇率策略

ModelHub 在供应商目录没有可机器读价格时，可为能被精确识别的模型填入一组随应用发布、已核对的上游公开参考价。这些金额用于本地用量估算，不是当前代理商、转售渠道、地区、私有合同或优惠活动的结算价。

## 价格优先级

价格同步严格按以下优先级执行：

1. 用户手工价或导入 CSV；
2. 当前供应商返回的、单位明确的机器可读价格；
3. ModelHub 内置上游公开参考价；
4. 没有可靠数据时保持“未知”。

内置参考价不会覆盖前两类显式价格。用户在界面中编辑过一条内置参考价后，该条会立即转为手工价，后续同步不再改写。

## 匹配与估算边界

- 只对注册表中能精确匹配的模型 ID 和已知日期快照生效；不确定的后缀、长上下文档位或私有变体保持未知。
- 有分档价格时，来源标签会记录所用档位；DeepSeek 动态时段价采用峰值时段作为保守估算，不计缓存折扣。
- 注册表保存美元或人民币原生报价；人民币价使用当前保存的 ECB 参考汇率换算为美元后存储。
- 当汇率或内置价格修订变化时，只重算来源仍为 ModelHub 内置参考价的条目。

## 汇率更新

- 启动后会对过期或缺失汇率执行补更新，之后每 6 小时检查一次。
- 刷新失败时保留上次成功值，30 分钟后再试；界面同时显示生效日、获取时间和最近失败，不会在断网时把旧值冒充成刚更新的值。
- ECB 参考汇率在欧洲中部时间工作日约 16:00 更新，因此“及时”指定期追踪最新已发布工作日数据，不是外汇交易逐秒报价。

## 官方公开来源

内置修订 `2026-08-31` 使用以下上游公开页面进行人工核对：

- ECB 参考汇率：<https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html>
- OpenAI API 价格与模型：<https://developers.openai.com/api/docs/pricing>
- Google Gemini API 价格：<https://ai.google.dev/gemini-api/docs/pricing>
- DeepSeek API 价格：<https://api-docs.deepseek.com/quick_start/pricing>
- 阿里云百炼模型价格：<https://help.aliyun.com/zh/model-studio/model-pricing>
- MiniMax 按量付费价格：<https://platform.minimaxi.com/docs/guides/pricing-paygo>

这些网页不会被应用在后台自动抓取。更新价格需要新的发布修订或当前供应商提供单位明确的机器目录，从而避免网页格式变动静默写入错误金额。
