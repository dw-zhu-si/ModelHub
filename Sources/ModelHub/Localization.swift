import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case brazilianPortuguese = "pt-BR"
    case russian = "ru"
    case arabic = "ar"

    static let defaultsKey = "ModelHubAppLanguage"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .system: "跟随系统 / System"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .brazilianPortuguese: "Português (Brasil)"
        case .russian: "Русский"
        case .arabic: "العربية"
        }
    }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    static var saved: AppLanguage {
        guard
            let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
            let language = AppLanguage(rawValue: rawValue)
        else {
            return .system
        }
        return language
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: localizationBundle,
            value: key,
            comment: ""
        )
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: AppLanguage.saved.locale, arguments: arguments)
    }

    private static var localizationBundle: Bundle {
        let language = AppLanguage.saved
        guard
            language != .system,
            let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return .main
        }
        return bundle
    }

    // Kept as literal calls so Xcode's localization extractor sees values that
    // originate in ModelHubCore and are rendered dynamically by the app UI.
    private static func registerDynamicCatalogKeysForExtraction() {
        _ = String(localized: "本地 API 已运行", locale: AppLanguage.saved.locale)
        _ = String(localized: "本地 API 未运行", locale: AppLanguage.saved.locale)
        _ = String(localized: "停止本地 API", locale: AppLanguage.saved.locale)
        _ = String(localized: "启动本地 API", locale: AppLanguage.saved.locale)
        _ = String(localized: "停止本地 API 服务", locale: AppLanguage.saved.locale)
        _ = String(localized: "启动本地 API 服务", locale: AppLanguage.saved.locale)
        _ = String(localized: "已启用", locale: AppLanguage.saved.locale)
        _ = String(localized: "已停用", locale: AppLanguage.saved.locale)
        _ = String(localized: "全部", locale: AppLanguage.saved.locale)
        _ = String(localized: "可用", locale: AppLanguage.saved.locale)
        _ = String(localized: "已隔离", locale: AppLanguage.saved.locale)
        _ = String(localized: "未测试", locale: AppLanguage.saved.locale)
        _ = String(localized: "需密钥", locale: AppLanguage.saved.locale)
        _ = String(localized: "待适配", locale: AppLanguage.saved.locale)
        _ = String(localized: "需配置密钥 · 已隔离", locale: AppLanguage.saved.locale)
        _ = String(localized: "待适配 · 已隔离", locale: AppLanguage.saved.locale)
        _ = String(localized: "此供应商无需 API Key", locale: AppLanguage.saved.locale)
        _ = String(localized: "钥匙串中已保存 API Key", locale: AppLanguage.saved.locale)
        _ = String(localized: "尚未保存 API Key", locale: AppLanguage.saved.locale)
        _ = String(localized: "图像生成", locale: AppLanguage.saved.locale)
        _ = String(localized: "视频生成", locale: AppLanguage.saved.locale)
        _ = String(localized: "语音合成", locale: AppLanguage.saved.locale)
        _ = String(localized: "语音转录", locale: AppLanguage.saved.locale)
        _ = String(localized: "向量", locale: AppLanguage.saved.locale)
        _ = String(localized: "重排", locale: AppLanguage.saved.locale)
        _ = String(localized: "供应商专用", locale: AppLanguage.saved.locale)
        _ = String(localized: "Ollama（本地）", locale: AppLanguage.saved.locale)
        _ = String(localized: "通用 OpenAI 兼容", locale: AppLanguage.saved.locale)
        _ = String(localized: "优先级故障转移", locale: AppLanguage.saved.locale)
        _ = String(localized: "轮询", locale: AppLanguage.saved.locale)
        _ = String(localized: "权重随机", locale: AppLanguage.saved.locale)
        _ = String(localized: "最低延迟", locale: AppLanguage.saved.locale)
        _ = String(localized: "最高稳定性", locale: AppLanguage.saved.locale)
        _ = String(localized: "最低成本", locale: AppLanguage.saved.locale)
        _ = String(localized: "最大上下文", locale: AppLanguage.saved.locale)
        _ = String(localized: "综合评分", locale: AppLanguage.saved.locale)
        _ = String(localized: "聊天", locale: AppLanguage.saved.locale)
        _ = String(localized: "工具调用", locale: AppLanguage.saved.locale)
        _ = String(localized: "视觉输入", locale: AppLanguage.saved.locale)
        _ = String(localized: "音频", locale: AppLanguage.saved.locale)
        _ = String(localized: "推理", locale: AppLanguage.saved.locale)
        _ = String(localized: "关闭", locale: AppLanguage.saved.locale)
        _ = String(localized: "保守文本整理", locale: AppLanguage.saved.locale)
    }
}

func mhLocalized(_ key: String, comment: String = "") -> String {
    L10n.text(key)
}
