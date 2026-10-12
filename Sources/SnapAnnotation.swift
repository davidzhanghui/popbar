import Cocoa
import CoreImage

enum SnapTool: CaseIterable {
    case rect, ellipse, arrow, pen, text, mosaic, number

    var id: String { String(describing: self) }
}

struct SnapStyle {
    var color: NSColor
    var tier: Int   // 0/1/2

    static let palette = ["#FF3B30", "#FFCC00", "#34C759", "#007AFF", "#FFFFFF", "#000000"]

    private var t: Int { min(max(tier, 0), 2) }
    var lineWidth: CGFloat { [2, 4, 6][t] }
    var fontSize: CGFloat { [14, 18, 24][t] }
    var numberDiameter: CGFloat { [20, 24, 30][t] }
    var brushWidth: CGFloat { [12, 20, 30][t] }

    static func color(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color]
    }
}

struct SnapUndoStack<T> {
    private(set) var items: [T] = []
    private var redoItems: [T] = []

    var canUndo: Bool { !items.isEmpty }
    var canRedo: Bool { !redoItems.isEmpty }

    mutating func push(_ item: T) {
        items.append(item)
        redoItems.removeAll()
    }

    mutating func undo() {
        if let last = items.popLast() { redoItems.append(last) }
    }

    mutating func redo() {
        if let last = redoItems.popLast() { items.append(last) }
    }
}

/// 所有坐标为覆盖视图局部坐标(左下原点,点),与选区同一空间
enum SnapAnnotation {
    case rect(CGRect, SnapStyle)
    case ellipse(CGRect, SnapStyle)
    case arrow(CGPoint, CGPoint, SnapStyle)
    case pen([CGPoint], SnapStyle)
    case text(String, CGPoint, SnapStyle)
    case mosaic([CGPoint], SnapStyle)
    case number(Int, CGPoint, SnapStyle)

    var isMosaic: Bool { if case .mosaic = self { return true } else { return false } }
    var isNumber: Bool { if case .number = self { return true } else { return false } }

    func draw(in ctx: CGContext, mosaicImage: CGImage?, imageBounds: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch self {
        case let .rect(r, s):
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.lineWidth)
            ctx.stroke(r)
        case let .ellipse(r, s):
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.lineWidth)
            ctx.strokeEllipse(in: r)
        case let .arrow(a, b, s):
            Self.drawArrow(ctx, a, b, s)
        case let .pen(pts, s):
            guard !pts.isEmpty else { return }
            if pts.count == 1 {
                ctx.setFillColor(s.color.cgColor)
                let w = s.lineWidth
                ctx.fillEllipse(in: CGRect(x: pts[0].x - w / 2, y: pts[0].y - w / 2, width: w, height: w))
                return
            }
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(Self.smoothPath(pts))
            ctx.strokePath()
        case let .text(str, p, s):
            let size = Self.textSize(str, s)
            Self.withGraphics(ctx) {
                (str as NSString).draw(with: CGRect(x: p.x, y: p.y - size.height, width: size.width, height: size.height),
                                       options: [.usesLineFragmentOrigin], attributes: s.textAttributes)
            }
        case let .mosaic(pts, s):
            guard let img = mosaicImage, let first = pts.first else { return }
            let path = CGMutablePath()
            path.move(to: first)
            if pts.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            pts.dropFirst().forEach { path.addLine(to: $0) }
            ctx.addPath(path)
            ctx.setLineWidth(s.brushWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.draw(img, in: imageBounds)
        case let .number(n, c, s):
            let d = s.numberDiameter
            ctx.setFillColor(s.color.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            let isLight = s.hex == "#FFFFFF" || s.hex == "#FFCC00"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: d * 0.55, weight: .bold),
                .foregroundColor: isLight ? NSColor.black : NSColor.white,
            ]
            let str = "\(n)"
            let size = str.size(withAttributes: attrs)
            Self.withGraphics(ctx) {
                str.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
            }
        }
    }

    static func textSize(_ str: String, _ style: SnapStyle) -> CGSize {
        let r = (str as NSString).boundingRect(with: CGSize(width: 100000, height: 100000),
                                               options: [.usesLineFragmentOrigin], attributes: style.textAttributes)
        return CGSize(width: ceil(r.width) + 1, height: ceil(r.height))
    }

    private static func withGraphics(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawArrow(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ s: SnapStyle) {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0 else { return }
        let head = min(s.lineWidth * 4 + 6, len)
        let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        let half = head * tan(.pi / 6)
        ctx.setStrokeColor(s.color.cgColor)
        ctx.setFillColor(s.color.cgColor)
        ctx.setLineWidth(s.lineWidth)
        ctx.setLineCap(.butt)
        ctx.move(to: a)
        ctx.addLine(to: base)
        ctx.strokePath()
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: pts[0])
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i - 1])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }
}

enum SnapMosaic {
    /// 整图像素化,马赛克笔刷从中取像素
    static func make(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIPixellate") else { return nil }
        f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(10 * scale, forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: ci.extent.midX, y: ci.extent.midY), forKey: kCIInputCenterKey)
        guard let out = f.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }
}
