import Cocoa
import ScreenCaptureKit
import WebKit

// 截图工具:真实显示浮动条并用 ScreenCaptureKit 抓窗口图像(含毛玻璃材质)。
// 用法: ./build/shot <浅色输出.png> <深色输出.png>
//       ./build/shot --monitor [输出目录]  生成系统监控面板图(浅色 popbar-monitor.png)与进程详情图(popbar-monitor-detail.png),只展示系统自带进程
//       ./build/shot --snap [输出目录]   生成截屏功能展示图(离线合成,不需要屏幕录制权限)
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let lightPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/popbar-bar-light.png"
let darkPath  = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "docs/popbar-bar-dark.png"

func capture(_ path: String, windowID: Int = FloatingBarController.shared.windowID) async {
    let wid = CGWindowID(windowID)
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let win = content.windows.first(where: { $0.windowID == wid }) else {
            print("window not found"); return
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        cfg.captureResolution = .best
        cfg.width = Int(win.frame.width) * 2
        cfg.height = Int(win.frame.height) * 2
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: cfg)
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    } catch {
        print("capture error: \(error)")
    }
}

// MARK: - 截屏功能展示图

final class Snapshotter: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done?.resume()
        done = nil
    }
}

/// 离屏渲染 docs/index.html 作为定格背景;失败则回退到纯色渐变
@MainActor func makeBackdrop(size: NSSize) async -> CGImage {
    let indexURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("docs/index.html")
    if FileManager.default.fileExists(atPath: indexURL.path) {
        let host = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size))
        host.contentView = webView
        host.alphaValue = 0
        host.orderFront(nil)
        let nav = Snapshotter()
        webView.navigationDelegate = nav
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        await withCheckedContinuation { nav.done = $0 }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let img = await withCheckedContinuation({ (c: CheckedContinuation<NSImage?, Never>) in
            webView.takeSnapshot(with: nil) { img, _ in c.resume(returning: img) }
        }), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
    }
    // 回退:深色渐变 + 占位文字
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                               pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [.init(srgbRed: 0.12, green: 0.13, blue: 0.18, alpha: 1),
                        .init(srgbRed: 0.22, green: 0.24, blue: 0.33, alpha: 1)])!
        .draw(in: CGRect(origin: .zero, size: NSSize(width: size.width * 2, height: size.height * 2)), angle: -60)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

func savePNG(_ cg: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: cg)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(cg.width)x\(cg.height)")
    }
}

/// 缩放 CGImage 到目标像素尺寸
func scaled(_ cg: CGImage, to size: CGSize) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                               pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: cg, size: size).draw(in: CGRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage ?? cg
}

@MainActor func runSnap(outDir: String) async {
    guard let screen = NSScreen.main else { print("no screen"); return }
    let size = screen.frame.size
    let backdrop = await makeBackdrop(size: size)
    let shot = SnapDisplayShot(screen: screen, image: backdrop,
                               scale: CGFloat(backdrop.width) / size.width)
    let win = SnapOverlayWindow(shot: shot, windowRects: [])
    win.alphaValue = 0                      // 离屏合成:窗口真实存在但不可见
    win.orderFront(nil)
    let view = win.overlayView
    view.prepare()

    func ev(_ type: NSEvent.EventType, _ p: CGPoint, _ click: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: win.windowNumber, context: nil,
                           eventNumber: 0, clickCount: click, pressure: 1)!
    }
    func dragPath(_ a: CGPoint, _ b: CGPoint) {
        view.mouseDown(with: ev(.leftMouseDown, a))
        for i in 1...6 {
            let p = CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 6,
                            y: a.y + (b.y - a.y) * CGFloat(i) / 6)
            view.mouseDragged(with: ev(.leftMouseDragged, p))
        }
        view.mouseUp(with: ev(.leftMouseUp, b))
    }
    func tap(_ p: CGPoint) {
        view.mouseDown(with: ev(.leftMouseDown, p))
        view.mouseUp(with: ev(.leftMouseUp, p))
    }
    func buttons() -> [NSButton] {
        var out: [NSButton] = []
        func walk(_ v: NSView) { v.subviews.forEach { walk($0) }; if let b = v as? NSButton { out.append(b) } }
        view.subviews.forEach { walk($0) }
        return out
    }
    func tool(_ index: Int) { buttons()[index].performClick(nil) }

    let w = size.width, h = size.height
    // 1. 拖出选区(视图坐标,原点在左下)
    dragPath(CGPoint(x: 0.14 * w, y: 0.76 * h), CGPoint(x: 0.86 * w, y: 0.22 * h))
    guard let sel = view.selection else { print("selection failed"); return }
    func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: sel.minX + sel.width * fx, y: sel.minY + sel.height * fy)
    }
    // 2. 标注:矩形 + 箭头 + 马赛克 + 序号(按钮顺序 = SnapTool.allCases)
    tool(0)   // rect
    dragPath(at(0.04, 0.62), at(0.34, 0.94))
    tool(2)   // arrow
    dragPath(at(0.42, 0.30), at(0.66, 0.78))
    tool(5)   // mosaic:盖在文字上,让像素化一眼可见
    dragPath(at(0.50, 0.33), at(0.97, 0.50))
    tool(6)   // number:单击落一个序号,工具仍选中
    tap(at(0.10, 0.42))
    tap(at(0.80, 0.62))
    view.rightMouseDown(with: ev(.rightMouseDown, at(0.5, 0.5)))   // 取消工具选中

    // 3. 渲染整个视图树(定格图 + 暗层 + 选区 + 标注 + 工具条)
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let full = rep.cgImage else { print("render failed"); return }
    let px = CGFloat(full.width) / w        // 视图点 → 像素

    // 全屏版(缩到 1x 点尺寸,体积适合网页)
    savePNG(scaled(full, to: CGSize(width: w, height: h)), outDir + "/popbar-snap.png")

    // 特写版:选区 + 工具条区域,保留原始像素
    var crop = sel
    for sub in view.subviews where sub is SnapToolbar || sub is SnapStyleBar {
        crop = crop.union(sub.frame)
    }
    crop = crop.insetBy(dx: -90, dy: -90).intersection(view.bounds)
    let pix = CGRect(x: crop.minX * px, y: (h - crop.maxY) * px,
                     width: crop.width * px, height: crop.height * px).integral
    if let c = full.cropping(to: pix) {
        savePNG(c, outDir + "/popbar-snap-detail.png")
    }
}

// MARK: - 入口

if CommandLine.arguments.contains("--monitor") {
    let idx = CommandLine.arguments.firstIndex(of: "--monitor")!
    let outDir = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "docs"
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        Task { @MainActor in
            NSApp.appearance = NSAppearance(named: .aqua)
            let monitor = SystemMonitorPanel.shared
            // 只留系统自带进程与 PopBar 自己,文档图里不出现个人安装的应用
            let allowed: Set<String> = ["WindowServer", "Finder", "Dock", "SystemUIServer", "ControlCenter",
                                        "loginwindow", "launchd", "mds_stores", "mds", "coreaudiod",
                                        "Spotlight", "Safari", "Terminal", "Activity Monitor", "Notes",
                                        "Mail", "Preview", "cfprefsd", "distnoted", "trustd", "PopBar",
                                        "kernel_task", "fseventsd", "powerd", "airportd", "bluetoothd",
                                        "WindowManager", "NotificationCenter", "Siri", "diskarbitrationd"]
            monitor.groupFilter = { allowed.contains($0.name) }
            monitor.show()
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // 等采样稳定、曲线有数据
            await capture(outDir + "/popbar-monitor.png", windowID: monitor.windowID)
            // 进程详情:选系统自带的 Finder,避免出现个人应用
            monitor.openDetail(named: "Finder")
            try? await Task.sleep(nanoseconds: 3_500_000_000)   // 等 launchctl / lsof 采集完成
            await capture(outDir + "/popbar-monitor-detail.png", windowID: monitor.windowID)
            NSApp.terminate(nil)
        }
    }
    app.run()
} else if CommandLine.arguments.contains("--snap") {
    let idx = CommandLine.arguments.firstIndex(of: "--snap")!
    let outDir = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "docs"
    DispatchQueue.main.async {
        Task { await runSnap(outDir: outDir); NSApp.terminate(nil) }
    }
    app.run()
} else {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        let c = FloatingBarController.shared
        c.show(text: "PopBar 划词弹条", anchor: nil)
        c.setAppearance(.aqua)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task {
                await capture(lightPath)
                c.setAppearance(.darkAqua)
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture(darkPath)
                NSApp.terminate(nil)
            }
        }
    }
    app.run()
}
