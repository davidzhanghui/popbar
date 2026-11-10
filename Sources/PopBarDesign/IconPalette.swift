import Cocoa

/// 彩色图标调色板：浮动条、截屏条、录屏条的按钮按语义着色。
///
/// 同一个图标名（Lucide 或 SF Symbol）在各处颜色一致；深浅两套色值都调过对比度，
/// 浅色下压得深一点避免发灰，深色下提亮一点避免发闷。没登记的图标按名字哈希
/// 落到色板里的某个颜色（扩展等用户自定义图标也有稳定的颜色）。
/// `enabled = false` 时调用方回落到原来的单色令牌。
public enum IconPalette {
    /// 由配置驱动（PopBarKit 的 ConfigStore 加载/变更时写入）
    nonisolated(unsafe) public static var enabled = true

    public static let red    = dyn("red", 0xE5484D, 0xFF6B70)
    public static let orange = dyn("orange", 0xE8710A, 0xFF9A45)
    public static let amber  = dyn("amber", 0xC98A00, 0xF5BE45)
    public static let green  = dyn("green", 0x2F9E6B, 0x4CC38A)
    public static let teal   = dyn("teal", 0x0F9488, 0x2DD4BF)
    public static let sky    = dyn("sky", 0x0284C7, 0x38BDF8)
    public static let blue   = dyn("blue", 0x2563EB, 0x6E9BFF)
    public static let indigo = dyn("indigo", 0x5B4FE0, 0x8E89FF)
    public static let purple = dyn("purple", 0x9333EA, 0xC084FC)
    public static let pink   = dyn("pink", 0xDB2777, 0xF472B6)
    public static let slate  = dyn("slate", 0x64748B, 0x94A3B8)

    /// 哈希兜底用的色板（不含 slate）
    private static let cycle: [NSColor] = [red, orange, amber, green, teal, sky, blue, indigo, purple, pink]

    /// 显式登记的颜色；不想上色的（更多、撤销/重做）登记成 nil
    private static let table: [String: NSColor?] = [
        // —— 浮动条（Lucide）——
        "copy": blue,
        "languages": indigo,
        "search": sky,
        "volume-2": orange,
        "square": red,              // 朗读中 → 停止
        "list-plus": green,
        "scissors": pink,
        "case-sensitive": purple,
        "hash": teal,
        "qr-code": slate,
        "eye-off": purple,
        "terminal": green,
        "printer": slate,
        "tv": indigo,
        "cast": indigo,
        "link": blue,
        "mail": sky,
        "calculator": orange,
        "clock": teal,
        "braces": amber,
        "binary": purple,
        "palette": pink,
        "folder-open": sky,
        "smartphone": green,
        "map-pin": red,
        "calendar": red,
        "arrow-down-up": green,
        "ruler": amber,
        "sparkles": purple,
        "puzzle": teal,
        "globe": sky,
        "ellipsis": nil,
        // —— 截屏 / 录屏条（SF Symbols）——
        "rectangle": red,
        "circle": orange,
        "arrow.up.right": pink,
        "scribble": purple,
        "textformat": blue,
        "checkerboard.rectangle": slate,
        "1.circle": teal,
        "arrow.uturn.backward": nil,
        "arrow.uturn.forward": nil,
        "arrow.up.and.down.text.horizontal": indigo,
        "record.circle": red,
        "record.circle.fill": red,
        "pin": orange,
        "text.viewfinder": teal,
        "square.and.arrow.down": blue,
        "xmark": red,
        "checkmark": green,
        "play.fill": green,
        "pause.fill": amber,
        "flag": pink,
        "flag.fill": pink,
        "eye.slash": slate,
        "stop.fill": red,
    ]

    /// 图标的语义色；未开启彩色或登记为不上色时返回 nil
    public static func color(for name: String) -> NSColor? {
        guard enabled else { return nil }
        if let hit = table[name] { return hit }
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return cycle[Int(h % UInt32(cycle.count))]
    }

    /// `color(for:)` 的便捷版：没有语义色时用 fallback
    public static func tint(_ name: String, fallback: NSColor) -> NSColor {
        color(for: name) ?? fallback
    }

    private static func dyn(_ name: String, _ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("popbar.icon." + name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return Theme.rgb(isDark ? dark : light, 0xFF)
        }
    }
}
