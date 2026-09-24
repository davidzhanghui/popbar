import Cocoa
import ScreenCaptureKit

// 截图工具:真实显示浮动条并用 ScreenCaptureKit 抓窗口图像(含毛玻璃材质)。
// 用法: ./build/shot <浅色输出.png> <深色输出.png>
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let lightPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/popbar-bar-light.png"
let darkPath  = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "docs/popbar-bar-dark.png"

func capture(_ path: String) async {
    let wid = CGWindowID(FloatingBarController.shared.windowID)
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
