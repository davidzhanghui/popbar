import Foundation

/// 极简双语：语言偏好 zh/en 直接生效，"system" 跟随系统首选语言（中文系统用中文，其他用英文）。
/// 偏好由 Kit 侧的 ConfigStore 在配置变化时写进 `preference`。
public enum L10n {
    /// system | zh | en
    nonisolated(unsafe) public static var preference: String = "system"

    public static var isEnglish: Bool {
        switch preference {
        case "en": return true
        case "zh": return false
        default:
            return !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }

    public static func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}
