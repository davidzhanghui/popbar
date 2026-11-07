import Cocoa
import SwiftUI

/// Lucide 线框图标：统一 1.75pt 线宽，作为模板图像按 `muted` / `accent` 等令牌着色。
/// 不再混用 SF Symbols 的实心图标。
public enum Lucide {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    /// 是否有这个图标
    public static func has(_ name: String) -> Bool { LucideData.bodies[name] != nil }

    /// 模板 NSImage；不存在的名字返回 `circle`，保证不会出现空白
    public static func image(_ name: String, size: CGFloat = 16, lineWidth: CGFloat = 1.75) -> NSImage {
        let key = "\(name)@\(size)@\(lineWidth)"
        if let img = cache[key] { return img }
        let body = LucideData.bodies[name] ?? LucideData.bodies["circle"] ?? ""
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(size)\" height=\"\(size)\" viewBox=\"0 0 24 24\" "
            + "fill=\"none\" stroke=\"#000\" stroke-width=\"\(lineWidth)\" stroke-linecap=\"round\" stroke-linejoin=\"round\">"
            + body + "</svg>"
        let img = NSImage(data: Data(svg.utf8)) ?? NSImage(size: NSSize(width: size, height: size))
        img.size = NSSize(width: size, height: size)
        img.isTemplate = true
        cache[key] = img
        return img
    }

    /// 已着色的非模板图像（菜单、状态栏以外需要固定颜色时用）
    public static func tinted(_ name: String, size: CGFloat = 16, color: NSColor) -> NSImage {
        let base = image(name, size: size)
        let out = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return out
    }
}

/// SwiftUI 图标视图
public struct Icon: View {
    let name: String
    let size: CGFloat
    let color: Color?

    public init(_ name: String, size: CGFloat = 15, color: Color? = nil) {
        self.name = name
        self.size = size
        self.color = color
    }

    public var body: some View {
        Image(nsImage: Lucide.image(name, size: size))
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(color ?? DS.muted)
    }
}
