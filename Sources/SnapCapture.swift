import Cocoa
import ScreenCaptureKit

struct SnapDisplayShot {
    let screen: NSScreen
    let image: CGImage
    let scale: CGFloat
}

enum SnapCapture {
    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    /// 抓取所有显示器的原生像素截图,排除 PopBar 自己的窗口
    static func captureAll() async throws -> [SnapDisplayShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.processID == getpid() }
        let targets: [(SCDisplay, NSScreen)] = content.displays.compactMap { d in
            guard let s = NSScreen.screens.first(where: {
                ($0.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value == d.displayID
            }) else { return nil }
            return (d, s)
        }
        return try await withThrowingTaskGroup(of: SnapDisplayShot.self) { group in
            for (display, screen) in targets {
                let scale = screen.backingScaleFactor
                let size = screen.frame.size
                group.addTask {
                    let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                    let cfg = SCStreamConfiguration()
                    cfg.width = Int(size.width * scale)
                    cfg.height = Int(size.height * scale)
                    cfg.showsCursor = false
                    cfg.captureResolution = .best
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    return SnapDisplayShot(screen: screen, image: img, scale: scale)
                }
            }
            var shots: [SnapDisplayShot] = []
            for try await s in group { shots.append(s) }
            return shots
        }
    }

    /// 屏幕上的普通窗口(Cocoa 全局坐标),前→后排序。
    /// 带上 windowID —— 选区正好落在一个窗口上时,录屏可以按窗口录并跟随窗口移动。
    static func windows() -> [(rect: CGRect, id: CGWindowID)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let pid = getpid()
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != pid,
                  let number = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.width >= 20, r.height >= 20 else { return nil }
            return (Screen.cocoaRect(from: r), number)
        }
    }

    static func windowRects() -> [CGRect] { windows().map(\.rect) }
}
