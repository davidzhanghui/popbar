import Cocoa

/// 浮动类窗口（浮动条、翻译面板、结果卡片、剪贴板速选）共用的定位逻辑。
///
/// 先确定锚点（有选区用选区，没有就用鼠标位置），再用锚点所在的屏幕选屏，
/// 最后在该屏的 `visibleFrame` 里调整——不再退回 `NSScreen.main`，
/// 修复多显示器时浮动条出现在另一块屏的问题。参考：Decklet `win.rs` 的 `place_near` / `place_below`。
public enum ScreenPlacement {
    public enum Preference {
        /// 优先放在锚点上方，放不下再放下方（浮动条）
        case above
        /// 优先放在锚点下方，放不下再放上方（翻译面板：不挡原文）
        case below
    }

    /// 纯函数版本，便于单测：screens 是各屏的 (frame, visibleFrame)，Cocoa 坐标
    public static func frame(size: CGSize, anchor: CGRect, prefer: Preference, gap: CGFloat = 6,
                             margin: CGFloat = 4, screens: [(frame: CGRect, visible: CGRect)]) -> CGRect {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = screens.first { $0.frame.contains(center) }
            ?? screens.first { $0.frame.intersects(anchor) }
            ?? screens.min { distance($0.frame, center) < distance($1.frame, center) }
        let vf = screen?.visible ?? CGRect(origin: .zero, size: CGSize(width: 10000, height: 10000))

        var x = anchor.midX - size.width / 2
        let aboveY = anchor.maxY + gap
        let belowY = anchor.minY - gap - size.height
        let fitsAbove = aboveY + size.height <= vf.maxY - margin
        let fitsBelow = belowY >= vf.minY + margin
        var y: CGFloat
        switch prefer {
        case .above: y = fitsAbove ? aboveY : (fitsBelow ? belowY : vf.maxY - margin - size.height)
        case .below: y = fitsBelow ? belowY : (fitsAbove ? aboveY : vf.minY + margin)
        }
        x = min(max(x, vf.minX + margin), vf.maxX - size.width - margin)
        y = min(max(y, vf.minY + margin), vf.maxY - size.height - margin)
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    /// 选区矩形是否可用来定位（正尺寸且落在某块屏幕上）
    public static func isUsable(_ rect: CGRect) -> Bool {
        guard rect.width >= 1, rect.height >= 1,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(rect) }
    }

    /// 按当前屏幕布局定位；anchor 为 nil / 无效时用鼠标位置
    public static func frame(size: CGSize, anchor: CGRect?, prefer: Preference, gap: CGFloat = 6) -> CGRect {
        let a: CGRect = {
            if let anchor, isUsable(anchor) { return anchor }
            let m = NSEvent.mouseLocation
            return CGRect(x: m.x, y: m.y - 8, width: 1, height: 16)
        }()
        return frame(size: size, anchor: a, prefer: prefer, gap: gap,
                     screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) })
    }

    /// 锚点所在屏幕（没有命中时取离得最近的）
    public static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.min { distance($0.frame, point) < distance($1.frame, point) }
    }

    static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}
