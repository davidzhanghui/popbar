import Cocoa

/// 极简双语:语言偏好 zh/en 直接生效,"system" 跟随系统首选语言(中文系统用中文,其他用英文)。
/// 覆盖范围:菜单栏菜单、浮动条提示、翻译面板、偏好设置窗口;provider 设置窗口暂只做中文。
enum L10n {
    static var isEnglish: Bool {
        switch ConfigStore.shared.config.language {
        case "en": return true
        case "zh": return false
        default:
            return !(NSLocale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }

    static func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}
