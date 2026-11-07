import Cocoa
import SwiftUI

/// 设计令牌（与 Decklet `crates/decklet/src/theme.rs` 数值一致）。
///
/// 视觉语言：暖纸色中性灰 + 一种强调色「朱砂」，单色线性图标，发丝线分隔，大圆角胶囊与卡片。
/// 颜色都是 `NSColor(name:dynamicProvider:)`，自动跟随系统外观（或 NSApp.appearance 的手动设置），
/// 深色模式不另外手调。界面代码只引用这里的语义名：AppKit 用 `Theme.*`，SwiftUI 用 `DS.*`。
public enum Theme {
    public static let bg            = dyn("bg", 0xF7F6F3, 0x161615)
    public static let surface       = dyn("surface", 0xFFFFFF, 0x1F1E1C)
    public static let surface2      = dyn("surface2", 0xF1EFEB, 0x282725)
    public static let hover         = dyn("hover", 0x1C1B19, 0x0D, 0xEDEBE7, 0x12)
    public static let active        = dyn("active", 0x1C1B19, 0x17, 0xEDEBE7, 0x1F)
    public static let border        = dyn("border", 0xE7E5E0, 0x34322F)
    public static let borderStrong  = dyn("borderStrong", 0xD6D3CC, 0x46433F)
    public static let text          = dyn("text", 0x1C1B19, 0xEDEBE7)
    public static let text2         = dyn("text2", 0x3D3B37, 0xD5D2CC)
    public static let muted         = dyn("muted", 0x6B6862, 0xA19D96)
    public static let faint         = dyn("faint", 0xA19D96, 0x6F6B65)
    public static let accent        = dyn("accent", 0xD9480F, 0xF0652A)
    public static let accentSoft    = dyn("accentSoft", 0xD9480F, 0x1A, 0xF0652A, 0x24)
    public static let onAccent      = dyn("onAccent", 0xFFFFFF, 0xFFFFFF)
    public static let danger        = dyn("danger", 0xE5484D, 0xFF6369)
    public static let dangerSoft    = dyn("dangerSoft", 0xE5484D, 0x1A, 0xFF6369, 0x24)
    public static let success       = dyn("success", 0x2F9E6B, 0x4CC38A)
    public static let successSoft   = dyn("successSoft", 0x2F9E6B, 0x1A, 0x4CC38A, 0x24)
    public static let warning       = dyn("warning", 0xC98A00, 0xF1B33A)
    public static let warningSoft   = dyn("warningSoft", 0xC98A00, 0x1A, 0xF1B33A, 0x24)
    public static let selection     = dyn("selection", 0xD9480F, 0x38, 0xF0652A, 0x4D)
    public static let shadow        = dyn("shadow", 0x1C1B19, 0x24, 0x000000, 0x66)
    public static let scrim         = dyn("scrim", 0x000000, 0x66, 0x000000, 0x80)

    // MARK: 尺寸

    public enum Radius {
        public static let capsule: CGFloat = 19
        public static let panel: CGFloat = 12
        public static let card: CGFloat = 10
        public static let button: CGFloat = 8
        public static let checkbox: CGFloat = 5
    }

    public enum FontSize {
        public static let display: CGFloat = 26
        public static let title: CGFloat = 20
        public static let heading: CGFloat = 13
        public static let body: CGFloat = 13
        public static let caption: CGFloat = 12
        public static let small: CGFloat = 11
    }

    /// 浮动类窗口阴影：y 8、blur 24
    public static func applyFloatingShadow(to layer: CALayer?) {
        guard let layer else { return }
        layer.shadowColor = shadow.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -8)
    }

    /// 当前外观是否深色
    public static func isDark(_ appearance: NSAppearance? = nil) -> Bool {
        (appearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing())
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 在指定外观下解析动态颜色（CALayer 的 cgColor 不会自动跟随外观，需要手动解析）
    public static func resolve(_ color: NSColor, in appearance: NSAppearance?) -> CGColor {
        var out = color.cgColor
        (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            out = color.cgColor
        }
        return out
    }

    // MARK: 内部

    private static func dyn(_ name: String, _ light: UInt32, _ dark: UInt32) -> NSColor {
        dyn(name, light, 0xFF, dark, 0xFF)
    }

    private static func dyn(_ name: String, _ light: UInt32, _ la: UInt32, _ dark: UInt32, _ da: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("popbar." + name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? rgb(dark, da) : rgb(light, la)
        }
    }

    static func rgb(_ hex: UInt32, _ alpha: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: CGFloat(alpha) / 255)
    }
}

/// SwiftUI 侧的令牌（桥接到同一组动态 NSColor）
public enum DS {
    public static let bg = Color(nsColor: Theme.bg)
    public static let surface = Color(nsColor: Theme.surface)
    public static let surface2 = Color(nsColor: Theme.surface2)
    public static let hover = Color(nsColor: Theme.hover)
    public static let active = Color(nsColor: Theme.active)
    public static let border = Color(nsColor: Theme.border)
    public static let borderStrong = Color(nsColor: Theme.borderStrong)
    public static let text = Color(nsColor: Theme.text)
    public static let text2 = Color(nsColor: Theme.text2)
    public static let muted = Color(nsColor: Theme.muted)
    public static let faint = Color(nsColor: Theme.faint)
    public static let accent = Color(nsColor: Theme.accent)
    public static let accentSoft = Color(nsColor: Theme.accentSoft)
    public static let onAccent = Color(nsColor: Theme.onAccent)
    public static let danger = Color(nsColor: Theme.danger)
    public static let dangerSoft = Color(nsColor: Theme.dangerSoft)
    public static let success = Color(nsColor: Theme.success)
    public static let successSoft = Color(nsColor: Theme.successSoft)
    public static let warning = Color(nsColor: Theme.warning)
    public static let warningSoft = Color(nsColor: Theme.warningSoft)
    public static let selection = Color(nsColor: Theme.selection)
    public static let shadow = Color(nsColor: Theme.shadow)
    public static let scrim = Color(nsColor: Theme.scrim)

    public static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    public static let pageTitle = font(Theme.FontSize.title, .semibold)
    public static let heading = font(Theme.FontSize.heading, .medium)
    public static let body = font(Theme.FontSize.body)
    public static let caption = font(Theme.FontSize.caption)
    public static let small = font(Theme.FontSize.small)
    public static let mono = Font.system(size: 12, design: .monospaced)
}
