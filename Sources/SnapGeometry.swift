import CoreGraphics

enum SnapHandle {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside
}

/// 截屏选区几何(纯逻辑,坐标均为左下原点的视图坐标)
enum SnapGeometry {
    static func hitHandle(_ p: CGPoint, rect: CGRect, tolerance: CGFloat = 6) -> SnapHandle? {
        let r = rect.standardized
        let nearL = abs(p.x - r.minX) <= tolerance
        let nearR = abs(p.x - r.maxX) <= tolerance
        let nearB = abs(p.y - r.minY) <= tolerance
        let nearT = abs(p.y - r.maxY) <= tolerance
        let withinX = p.x >= r.minX - tolerance && p.x <= r.maxX + tolerance
        let withinY = p.y >= r.minY - tolerance && p.y <= r.maxY + tolerance
        if nearT && nearL { return .topLeft }
        if nearT && nearR { return .topRight }
        if nearB && nearR { return .bottomRight }
        if nearB && nearL { return .bottomLeft }
        if nearT && withinX { return .top }
        if nearB && withinX { return .bottom }
        if nearL && withinY { return .left }
        if nearR && withinY { return .right }
        return r.contains(p) ? .inside : nil
    }

    static func resize(_ rect: CGRect, handle: SnapHandle, to p: CGPoint, bounds: CGRect) -> CGRect {
        let r = rect.standardized
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        let x = min(max(p.x, bounds.minX), bounds.maxX)
        let y = min(max(p.y, bounds.minY), bounds.maxY)
        switch handle {
        case .topLeft:      minX = x; maxY = y
        case .top:          maxY = y
        case .topRight:     maxX = x; maxY = y
        case .right:        maxX = x
        case .bottomRight:  maxX = x; minY = y
        case .bottom:       minY = y
        case .bottomLeft:   minX = x; minY = y
        case .left:         minX = x
        case .inside:       break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    static func move(_ rect: CGRect, by d: CGVector, bounds: CGRect) -> CGRect {
        var r = rect.standardized
        r.origin.x = min(max(r.origin.x + d.dx, bounds.minX), max(bounds.minX, bounds.maxX - r.width))
        r.origin.y = min(max(r.origin.y + d.dy, bounds.minY), max(bounds.minY, bounds.maxY - r.height))
        return r
    }

    static func rectFrom(_ a: CGPoint, _ b: CGPoint, bounds: CGRect) -> CGRect {
        let ax = min(max(a.x, bounds.minX), bounds.maxX), ay = min(max(a.y, bounds.minY), bounds.maxY)
        let bx = min(max(b.x, bounds.minX), bounds.maxX), by = min(max(b.y, bounds.minY), bounds.maxY)
        return CGRect(x: min(ax, bx), y: min(ay, by), width: abs(ax - bx), height: abs(ay - by))
    }

    /// 视图坐标(左下原点,点) → CGImage 像素坐标(左上原点)
    static func pixelRect(_ r: CGRect, viewHeight: CGFloat, scale: CGFloat) -> CGRect {
        let s = r.standardized
        let x0 = (s.minX * scale).rounded(), x1 = (s.maxX * scale).rounded()
        let y0 = ((viewHeight - s.maxY) * scale).rounded(), y1 = ((viewHeight - s.minY) * scale).rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// windows 按前→后排序,返回第一个包含 p 的
    static func windowAt(_ p: CGPoint, windows: [CGRect]) -> CGRect? {
        windows.first { $0.contains(p) }
    }

    /// Shift:矩形/椭圆约束为正方形/正圆,保持拖动方向
    static func constrainSquare(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let m = max(abs(dx), abs(dy))
        return CGPoint(x: a.x + (dx < 0 ? -m : m), y: a.y + (dy < 0 ? -m : m))
    }

    /// Shift:箭头吸附到最近的 45° 方向,长度不变
    static func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0 else { return b }
        let step = CGFloat.pi / 4
        let ang = (atan2(b.y - a.y, b.x - a.x) / step).rounded() * step
        return CGPoint(x: a.x + len * cos(ang), y: a.y + len * sin(ang))
    }
}
