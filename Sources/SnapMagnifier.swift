import Cocoa

/// 像素放大镜:从冻结的原生像素图里取小块放大,并读取光标下的颜色
struct SnapMagnifier {
    static let boxSize: CGFloat = 120
    static let cells = 15
    static let textHeight: CGFloat = 38

    struct Sample {
        let zoom: CGImage?
        let pixel: (x: Int, y: Int)
        let rgb: (r: Int, g: Int, b: Int)
        var hex: String { String(format: "#%02X%02X%02X", rgb.r, rgb.g, rgb.b) }
    }

    /// point 为视图坐标(左下原点);返回其对应的像素坐标、颜色与放大图
    static func sample(_ image: CGImage, scale: CGFloat, viewHeight: CGFloat, at point: CGPoint) -> Sample {
        let px = min(max(Int(point.x * scale), 0), image.width - 1)
        let py = min(max(Int((viewHeight - point.y) * scale), 0), image.height - 1)
        let n = cells, mid = n / 2
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Sample(zoom: nil, pixel: (px, py), rgb: (0, 0, 0))
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: mid - px, y: mid - (image.height - 1 - py),
                                   width: image.width, height: image.height))
        var rgb = (r: 0, g: 0, b: 0)
        if let p = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            let o = (mid * n + mid) * 4
            rgb = (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
        }
        return Sample(zoom: ctx.makeImage(), pixel: (px, py), rgb: rgb)
    }

    /// 在 mouse 附近绘制放大镜,靠近屏幕边缘时翻到另一侧
    static func draw(_ s: Sample, mouse: CGPoint, bounds: CGRect, copied: Bool) {
        let total = CGSize(width: boxSize, height: boxSize + textHeight)
        var origin = CGPoint(x: mouse.x + 20, y: mouse.y - 20 - total.height)
        if origin.x + total.width > bounds.maxX { origin.x = mouse.x - 20 - total.width }
        if origin.y < bounds.minY { origin.y = mouse.y + 20 }
        let box = CGRect(origin: CGPoint(x: origin.x, y: origin.y + textHeight), size: CGSize(width: boxSize, height: boxSize))

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: total), xRadius: 6, yRadius: 6).fill()

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.clip()
        if let z = s.zoom {
            ctx.interpolationQuality = .none
            ctx.draw(z, in: box)
        }
        ctx.restoreGState()

        let cell = boxSize / CGFloat(cells)
        let center = CGRect(x: box.midX - cell / 2, y: box.midY - cell / 2, width: cell, height: cell)
        NSColor.white.withAlphaComponent(0.5).setFill()
        CGRect(x: box.minX, y: center.midY - 0.5, width: boxSize, height: 1).fill()
        CGRect(x: center.midX - 0.5, y: box.minY, width: 1, height: boxSize).fill()
        NSColor(srgbRed: 0.1, green: 0.68, blue: 0.1, alpha: 1).setStroke()
        let ring = NSBezierPath(rect: center)
        ring.lineWidth = 1.5
        ring.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let line1 = "(\(s.pixel.x), \(s.pixel.y))"
        let line2 = copied ? L10n.t("已复制 ", "Copied ") + s.hex
                           : "RGB(\(s.rgb.r),\(s.rgb.g),\(s.rgb.b))  \(s.hex)"
        line1.draw(at: CGPoint(x: origin.x + 6, y: origin.y + 20), withAttributes: attrs)
        line2.draw(at: CGPoint(x: origin.x + 6, y: origin.y + 5), withAttributes: attrs)
    }
}
