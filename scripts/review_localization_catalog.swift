import Foundation

let catalogURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "")
guard
    !catalogURL.path.isEmpty,
    let data = try? Data(contentsOf: catalogURL),
    var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    var strings = root["strings"] as? [String: Any]
else {
    fputs("Usage: review_localization_catalog.swift <Localizable.xcstrings>\n", stderr)
    exit(2)
}

let reviewed: [String: [String: String]] = [
    "%arg": [
        "zh-Hans": "%arg", "zh-Hant": "%arg", "en": "%arg", "ja": "%arg",
        "ko": "%arg", "es": "%arg", "fr": "%arg", "de": "%arg",
        "pt-BR": "%arg", "ru": "%arg", "ar": "%arg",
    ],
    "%arg / %arg": [
        "zh-Hans": "%arg / %arg", "zh-Hant": "%arg / %arg", "en": "%arg / %arg",
        "ja": "%arg / %arg", "ko": "%arg / %arg", "es": "%arg / %arg",
        "fr": "%arg / %arg", "de": "%arg / %arg", "pt-BR": "%arg / %arg",
        "ru": "%arg / %arg", "ar": "%arg / %arg",
    ],
    "%arg %arg": [
        "zh-Hans": "%arg %arg", "zh-Hant": "%arg %arg", "en": "%arg %arg",
        "ja": "%arg %arg", "ko": "%arg %arg", "es": "%arg %arg",
        "fr": "%arg %arg", "de": "%arg %arg", "pt-BR": "%arg %arg",
        "ru": "%arg %arg", "ar": "%arg %arg",
    ],
    "%arg ms": [
        "zh-Hans": "%arg 毫秒", "zh-Hant": "%arg 毫秒", "en": "%arg ms",
        "ja": "%arg ミリ秒", "ko": "%arg밀리초", "es": "%arg ms", "fr": "%arg ms",
        "de": "%arg ms", "pt-BR": "%arg ms", "ru": "%arg мс", "ar": "%arg مللي ثانية",
    ],
    "%arg，%arg": [
        "zh-Hans": "%arg，%arg", "zh-Hant": "%arg，%arg", "en": "%arg, %arg",
        "ja": "%arg、%arg", "ko": "%arg, %arg", "es": "%arg, %arg",
        "fr": "%arg, %arg", "de": "%arg, %arg", "pt-BR": "%arg, %arg",
        "ru": "%arg, %arg", "ar": "%arg، %arg",
    ],
    "Base URL": [
        "zh-Hans": "Base URL", "zh-Hant": "Base URL", "en": "Base URL", "ja": "Base URL",
        "ko": "Base URL", "es": "URL base", "fr": "URL de base", "de": "Basis-URL",
        "pt-BR": "URL base", "ru": "Базовый URL", "ar": "عنوان URL الأساسي",
    ],
    "http://127.0.0.1:%arg/v1": [
        "zh-Hans": "http://127.0.0.1:%arg/v1", "zh-Hant": "http://127.0.0.1:%arg/v1",
        "en": "http://127.0.0.1:%arg/v1", "ja": "http://127.0.0.1:%arg/v1",
        "ko": "http://127.0.0.1:%arg/v1", "es": "http://127.0.0.1:%arg/v1",
        "fr": "http://127.0.0.1:%arg/v1", "de": "http://127.0.0.1:%arg/v1",
        "pt-BR": "http://127.0.0.1:%arg/v1", "ru": "http://127.0.0.1:%arg/v1",
        "ar": "http://127.0.0.1:%arg/v1",
    ],
    "ModelHub": [
        "zh-Hans": "ModelHub", "zh-Hant": "ModelHub", "en": "ModelHub", "ja": "ModelHub",
        "ko": "ModelHub", "es": "ModelHub", "fr": "ModelHub", "de": "ModelHub",
        "pt-BR": "ModelHub", "ru": "ModelHub", "ar": "ModelHub",
    ],
    "OpenAI Base URL": [
        "zh-Hans": "OpenAI Base URL", "zh-Hant": "OpenAI Base URL", "en": "OpenAI Base URL",
        "ja": "OpenAI Base URL", "ko": "OpenAI Base URL", "es": "URL base de OpenAI",
        "fr": "URL de base OpenAI", "de": "OpenAI-Basis-URL", "pt-BR": "URL base da OpenAI",
        "ru": "Базовый URL OpenAI", "ar": "عنوان URL الأساسي لـ OpenAI",
    ],
    "Token": [
        "zh-Hans": "Token", "zh-Hant": "Token", "en": "Token", "ja": "トークン",
        "ko": "토큰", "es": "Token", "fr": "Jeton", "de": "Token",
        "pt-BR": "Token", "ru": "Токен", "ar": "الرمز",
    ],
    "模型枢纽": [
        "zh-Hans": "模型枢纽", "zh-Hant": "模型樞紐", "en": "ModelHub",
        "ja": "ModelHub", "ko": "ModelHub", "es": "ModelHub", "fr": "ModelHub",
        "de": "ModelHub", "pt-BR": "ModelHub", "ru": "ModelHub", "ar": "ModelHub",
    ],
    "模型供应商": [
        "zh-Hans": "模型供应商", "zh-Hant": "模型供應商", "en": "Model Providers",
        "ja": "モデルプロバイダー", "ko": "모델 제공업체", "es": "Proveedores de modelos",
        "fr": "Fournisseurs de modèles", "de": "Modellanbieter", "pt-BR": "Provedores de modelos",
        "ru": "Поставщики моделей", "ar": "موفّرو النماذج",
    ],
    "模型路由": [
        "zh-Hans": "模型路由", "zh-Hant": "模型路由", "en": "Model Routes",
        "ja": "モデルルート", "ko": "모델 경로", "es": "Rutas de modelos",
        "fr": "Routes de modèles", "de": "Modellrouten", "pt-BR": "Rotas de modelos",
        "ru": "Маршруты моделей", "ar": "مسارات النماذج",
    ],
    "供应商": [
        "zh-Hans": "供应商", "zh-Hant": "供應商", "en": "Provider", "ja": "プロバイダー",
        "ko": "제공업체", "es": "Proveedor", "fr": "Fournisseur", "de": "Anbieter",
        "pt-BR": "Provedor", "ru": "Поставщик", "ar": "المزوّد",
    ],
    "供应商 / 模型": [
        "zh-Hans": "供应商 / 模型", "zh-Hant": "供應商 / 模型", "en": "Provider / Model",
        "ja": "プロバイダー / モデル", "ko": "제공업체 / 모델", "es": "Proveedor / Modelo",
        "fr": "Fournisseur / Modèle", "de": "Anbieter / Modell", "pt-BR": "Provedor / Modelo",
        "ru": "Поставщик / Модель", "ar": "المزوّد / النموذج",
    ],
    "供应商类型": [
        "zh-Hans": "供应商类型", "zh-Hant": "供應商類型", "en": "Provider Type",
        "ja": "プロバイダーの種類", "ko": "제공업체 유형", "es": "Tipo de proveedor",
        "fr": "Type de fournisseur", "de": "Anbietertyp", "pt-BR": "Tipo de provedor",
        "ru": "Тип поставщика", "ar": "نوع المزوّد",
    ],
    "用量分析": [
        "zh-Hans": "用量分析", "zh-Hant": "用量分析", "en": "Usage Analytics",
        "ja": "使用状況分析", "ko": "사용량 분석", "es": "Análisis de uso",
        "fr": "Analyse de l’utilisation", "de": "Nutzungsanalyse", "pt-BR": "Análise de uso",
        "ru": "Аналитика использования", "ar": "تحليلات الاستخدام",
    ],
    "凭证": [
        "zh-Hans": "凭证", "zh-Hant": "憑證", "en": "Credentials", "ja": "認証情報",
        "ko": "자격 증명", "es": "Credenciales", "fr": "Identifiants", "de": "Anmeldedaten",
        "pt-BR": "Credenciais", "ru": "Учётные данные", "ar": "بيانات الاعتماد",
    ],
    "韧性控制": [
        "zh-Hans": "韧性控制", "zh-Hant": "韌性控制", "en": "Resilience Controls",
        "ja": "耐障害性制御", "ko": "복원력 제어", "es": "Controles de resiliencia",
        "fr": "Contrôles de résilience", "de": "Resilienzsteuerung", "pt-BR": "Controles de resiliência",
        "ru": "Управление отказоустойчивостью", "ar": "عناصر التحكم في المرونة",
    ],
    "本机 Agent 协议": [
        "zh-Hans": "本机 Agent 协议", "zh-Hant": "本機 Agent 協議", "en": "Local Agent Protocols",
        "ja": "ローカル Agent プロトコル", "ko": "로컬 Agent 프로토콜", "es": "Protocolos locales de Agent",
        "fr": "Protocoles Agent locaux", "de": "Lokale Agent-Protokolle", "pt-BR": "Protocolos locais de Agent",
        "ru": "Локальные протоколы Agent", "ar": "بروتوكولات Agent المحلية",
    ],
    "熔断冷却：%arg 秒": [
        "zh-Hans": "熔断冷却：%arg 秒", "zh-Hant": "熔斷冷卻：%arg 秒", "en": "Circuit-breaker cooldown: %arg seconds",
        "ja": "サーキットブレーカーのクールダウン：%arg 秒", "ko": "회로 차단기 대기 시간: %arg초",
        "es": "Espera del disyuntor: %arg segundos", "fr": "Délai du coupe-circuit : %arg secondes",
        "de": "Abkühlzeit des Schutzschalters: %arg Sekunden", "pt-BR": "Espera do disjuntor: %arg segundos",
        "ru": "Пауза автоматического выключателя: %arg с", "ar": "مهلة قاطع الدائرة: %arg ثانية",
    ],
    "上下文优化": [
        "zh-Hans": "上下文优化", "zh-Hant": "上下文最佳化", "en": "Context Optimization",
        "ja": "コンテキスト最適化", "ko": "컨텍스트 최적화", "es": "Optimización del contexto",
        "fr": "Optimisation du contexte", "de": "Kontextoptimierung", "pt-BR": "Otimização de contexto",
        "ru": "Оптимизация контекста", "ar": "تحسين السياق",
    ],
    "好": [
        "zh-Hans": "好", "zh-Hant": "好", "en": "OK", "ja": "OK", "ko": "확인",
        "es": "Aceptar", "fr": "OK", "de": "OK", "pt-BR": "OK", "ru": "ОК", "ar": "موافق",
    ],
]

let reviewedEnglish: [String: String] = [
    "%arg 个目标": "%arg targets",
    "%arg 个模型 · 聊天模型在线检测；生成模型未通过原生验证时保持隔离": "%arg models · chat models are tested online; generative models stay quarantined until native verification passes",
    "%arg原生入口": "%arg native endpoint",
    "%@原生入口": "%@ native endpoint",
    "一键测试": "Test All",
    "仅监听 127.0.0.1；校验本机 Origin；工具全部只读，并且模型目录只返回未隔离目标。": "Listens only on 127.0.0.1, validates local origins, exposes read-only tools, and lists only non-quarantined targets.",
    "优先级数值越小越先尝试；权重仅用于权重随机策略。5xx、429 或网络错误会触发故障转移。": "Lower priority values are tried first. Weights apply only to weighted-random routing. HTTP 5xx, 429, and network errors trigger failover.",
    "例如：供应商定价页 / 手工": "Example: provider pricing page / manual entry",
    "删除供应商？": "Delete provider?",
    "启用整理的最小字符数：%arg": "Minimum characters before cleanup: %arg",
    "将检查 %arg 个模型。已隔离的聊天模型也会重新请求上游，成功后自动恢复，失败则继续隔离。图像、视频、语音、转录、向量和重排模型只验证本地原生适配，不自动发起可能计费的生成。最多并发 3 个，单次超时 30 秒。": "%arg models will be checked. Quarantined chat models are probed again and restored only after success. Image, video, speech, transcription, embedding, and reranking models validate local protocol support without starting billable generation. At most 3 requests run concurrently, with a 30-second timeout each.",
    "月 Token 上限": "Monthly token limit",
    "月度费用上限（USD，留空表示不设）": "Monthly spend limit (USD; leave blank for none)",
    "本月暂无聚合用量。未知价格不会被伪算为已知费用。": "No aggregated usage this month. Models with unknown pricing are not reported as known costs.",
    "耗时": "Duration",
    "启用此供应商": "Enable this provider",
    "添加供应商": "Add provider",
    "编辑供应商与密钥": "Edit provider and key",
    "选择供应商": "Select provider",
    "选择左侧供应商后查看模型状态。": "Select a provider on the left to view model status.",
    "熔断冷却：%arg 秒": "Circuit-breaker cooldown: %arg seconds",
    "请求模型": "Requested model",
    "连续失败熔断阈值：%arg": "Circuit-breaker threshold: %arg consecutive failures",
    "端口由 ModelHub 与 ProjectDock 固定管理，仅监听本机回环地址；请保留末尾 /v1。": "ModelHub and ProjectDock manage this fixed loopback-only port. Keep /v1 at the end.",
    "模型": "Model",
    "保存": "Save",
    "停止": "Stop",
    "成功": "Success",
    "未知": "Unknown",
    "响应": "Response",
    "时间": "Time",
    "访问令牌": "Access Token",
    "路由规则": "Routing Rules",
]

func replace(_ key: String, language: String, value: String) {
    guard var entry = strings[key] as? [String: Any] else { return }
    var localizations = entry["localizations"] as? [String: Any] ?? [:]
    localizations[language] = ["stringUnit": ["state": "translated", "value": value]]
    entry["localizations"] = localizations
    strings[key] = entry
}

for (key, localizations) in reviewed {
    for (language, value) in localizations {
        replace(key, language: language, value: value)
    }
}
for (key, value) in reviewedEnglish {
    replace(key, language: "en", value: value)
}

let reviewURL = catalogURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("scripts/localization_manual_review.json")
if
    let reviewData = try? Data(contentsOf: reviewURL),
    let reviewRoot = try? JSONSerialization.jsonObject(with: reviewData) as? [String: Any],
    let languages = reviewRoot["languages"] as? [String],
    let reviewedStrings = reviewRoot["strings"] as? [String: Any]
{
    for (key, rawValues) in reviewedStrings {
        guard let values = rawValues as? [String], values.count == languages.count else {
            fputs("Invalid manual review entry: \(key)\n", stderr)
            exit(3)
        }
        for (language, value) in zip(languages, values) {
            replace(key, language: language, value: value)
        }
    }
}

root["strings"] = strings
let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try output.write(to: catalogURL, options: .atomic)
print("Reviewed \(reviewed.count) multilingual terms and \(reviewedEnglish.count) English strings.")
