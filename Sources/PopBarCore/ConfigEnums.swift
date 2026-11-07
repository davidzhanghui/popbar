import Foundation

/// 配置里的「模式」类字段统一用它：解码遇到未知值（手写错、老版本残留）回落到默认值，保证老配置能读。
public protocol LenientEnum: RawRepresentable, Codable, CaseIterable, Hashable, Sendable where RawValue == String {
    static var fallback: Self { get }
}

extension LenientEnum {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = (try? c.decode(String.self)) ?? ""
        self = Self(rawValue: raw) ?? Self.fallback
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// 从字符串宽松构造（设置页、迁移用）
    public init(lenient raw: String) { self = Self(rawValue: raw) ?? Self.fallback }
}

/// 划词触发方式（`keyboard` 是 v2 的死分支，读到时回落为 both）
public enum TriggerMode: String, LenientEnum {
    case both, drag, doubleClick
    public static let fallback = TriggerMode.both
}

/// 敏感内容守卫
public enum GuardMode: String, LenientEnum {
    case ask, mask, off
    public static let fallback = GuardMode.ask
}

public enum AppearanceMode: String, LenientEnum {
    case system, light, dark
    public static let fallback = AppearanceMode.system
}

public enum LanguagePref: String, LenientEnum {
    case system, zh, en
    public static let fallback = LanguagePref.system
}

/// 左键点菜单栏图标
public enum TrayClick: String, LenientEnum {
    case menu, deck, input, clipboard
    public static let fallback = TrayClick.menu
}

/// 翻译面板默认位置
public enum PanelPosition: String, LenientEnum {
    /// 紧贴选区（下方优先，放不下再放上方）
    case top
    /// 鼠标位置
    case cursor
    public static let fallback = PanelPosition.top
}

/// 浮动条按钮排序
public enum ToolbarOrder: String, LenientEnum {
    case manual, perApp
    public static let fallback = ToolbarOrder.manual
}

/// 浮动条搜索按钮用的搜索引擎
public enum SearchEngine: String, LenientEnum {
    case google, baidu, bing, duckduckgo
    public static let fallback = SearchEngine.google

    public var title: String {
        switch self {
        case .google: return "Google"
        case .baidu: return L10n.t("百度", "Baidu")
        case .bing: return "Bing"
        case .duckduckgo: return "DuckDuckGo"
        }
    }

    /// `{q}` 处替换为百分号编码后的查询
    public var template: String {
        switch self {
        case .google: return "https://www.google.com/search?q={q}"
        case .baidu: return "https://www.baidu.com/s?wd={q}"
        case .bing: return "https://www.bing.com/search?q={q}"
        case .duckduckgo: return "https://duckduckgo.com/?q={q}"
        }
    }

    public func url(for text: String) -> URL? {
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: template.replacingOccurrences(of: "{q}", with: q))
    }
}

/// 按应用规则
public enum AppRuleMode: String, LenientEnum {
    /// 完全不触发
    case disabled
    /// 划词不弹，只有快捷键能唤起
    case hotkeyOnly
    /// 只显示列出的动作
    case custom
    public static let fallback = AppRuleMode.disabled
}

public enum ExtensionType: String, LenientEnum {
    case url, shell, shortcut
    public static let fallback = ExtensionType.url
}

public enum ExtensionOutput: String, LenientEnum {
    case none, copy, replace, show, panel
    public static let fallback = ExtensionOutput.none
}

/// 截图 OCR 识别后去哪
public enum OCRAfter: String, LenientEnum {
    case panel, bar
    public static let fallback = OCRAfter.panel
}

public enum ImageFormat: String, LenientEnum {
    case png, jpg
    public static let fallback = ImageFormat.png
}
