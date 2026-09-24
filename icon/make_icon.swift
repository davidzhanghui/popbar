import Cocoa

// 用法: swift icon/make_icon.swift <输出iconset目录> [预览png路径]
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon/PopBar.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw() {
    let S: CGFloat = 1024

    // ---- 背景:紫蓝渐变圆角方块 ----
    let bg = NSBezierPath(
        roundedRect: NSRect(x: S * 0.055, y: S * 0.055, width: S * 0.89, height: S * 0.89),
        xRadius: S * 0.21, yRadius: S * 0.21)
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.42, green: 0.40, blue: 0.99, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.72, green: 0.30, blue: 0.93, alpha: 1), 1.0))!
        .draw(in: bg, angle: -90)

    // ---- 选区高亮(在中间文本行下层) ----
    NSColor.white.withAlphaComponent(0.30).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: S * 0.14, y: S * 0.255, width: S * 0.72, height: S * 0.126),
        xRadius: S * 0.02, yRadius: S * 0.02).fill()

    // ---- 三行"文字" ----
    let lineH = S * 0.056
    let lineX = S * 0.18
    NSColor.white.withAlphaComponent(0.92).setFill()
    for (y, w) in [(0.16, 0.64), (0.29, 0.50), (0.42, 0.58)] as [(CGFloat, CGFloat)] {
        NSBezierPath(
            roundedRect: NSRect(x: lineX, y: S * y, width: S * w, height: lineH),
            xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }

    // ---- 浮动条气泡(带投影和向下指针) ----
    let pill = NSRect(x: S * 0.26, y: S * 0.56, width: S * 0.48, height: S * 0.16)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
    sh.shadowBlurRadius = S * 0.025
    sh.shadowOffset = NSSize(width: 0, height: -S * 0.012)
    sh.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: pill,
                 xRadius: pill.height * 0.35, yRadius: pill.height * 0.35).fill()
    let tri = NSBezierPath()
    let cx = pill.midX
    tri.move(to: NSPoint(x: cx - S * 0.035, y: pill.minY + 1))
    tri.line(to: NSPoint(x: cx + S * 0.035, y: pill.minY + 1))
    tri.line(to: NSPoint(x: cx, y: pill.minY - S * 0.055))
    tri.close()
    tri.fill()
    NSGraphicsContext.restoreGraphicsState()

    // ---- 气泡里 3 个彩色圆点(代表动作按钮) ----
    let d = pill.height * 0.42
    let cy = pill.midY - d / 2
    let dots: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1),  // 橙
        NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1),  // 绿
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),  // 蓝
    ]
    for (i, c) in dots.enumerated() {
        c.setFill()
        let x = pill.midX + CGFloat(i - 1) * (pill.width * 0.28) - d / 2
        NSBezierPath(ovalIn: NSRect(x: x, y: cy, width: d, height: d)).fill()
    }
}

func render(_ px: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.scaleBy(x: px / 1024, y: px / 1024)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    if let data = render(px) {
        try? data.write(to: URL(fileURLWithPath: outDir + "/" + name))
    }
}
if CommandLine.arguments.count > 2, let data = render(512) {
    try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("iconset written to \(outDir)")
