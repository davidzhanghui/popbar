import Cocoa
import ScreenCaptureKit
import PopBarCore
import PopBarPlatform
import PopBarDesign

struct SnapDisplayShot {
    let screen: NSScreen
    let image: CGImage
    let scale: CGFloat
}

enum SnapCapture {
    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    /// 抓取所有显示器的原生像素截图;只排除截屏/录屏工具自身的界面,
    /// Deck、翻译面板、二维码、贴图等 PopBar 窗口和普通窗口一样进画面
    static func captureAll() async throws -> [SnapDisplayShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = await CaptureChrome.excludedWindows()
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
                    let filter = SCContentFilter(display: display, excludingWindows: excluded)
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

    /// 屏幕上可吸附的窗口(Cocoa 全局坐标),前→后排序。
    /// 带上 windowID —— 选区正好落在一个窗口上时,录屏可以按窗口录并跟随窗口移动。
    /// 其它 App 只取普通层(layer 0);PopBar 自己的 Deck / 翻译面板等浮窗(floating 层)也参与吸附,
    /// 否则 Deck 在最前时框选会直接穿透到它下面的窗口。截屏/录屏工具自身的界面不参与。
    @MainActor
    static func windows() -> [(rect: CGRect, id: CGWindowID)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let pid = getpid()
        let chrome = CaptureChrome.windowNumbers()
        let ownMaxLayer = Int(CGWindowLevelForKey(.floatingWindow))
        return info.compactMap { w in
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let own = (w[kCGWindowOwnerPID as String] as? Int32) == pid
            guard let number = w[kCGWindowNumber as String] as? CGWindowID,
                  own ? (0...ownMaxLayer).contains(layer) && !chrome.contains(Int(number)) : layer == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.width >= 20, r.height >= 20 else { return nil }
            return (Screen.cocoaRect(from: r), number)
        }
    }

    @MainActor static func windowRects() -> [CGRect] { windows().map(\.rect) }
}

/// 截屏/录屏工具自身的界面(选区遮罩、滚动截图框、录制红框/控制条/倒计时、摄像头预览、悬停提示)。
/// 这些窗口必须从画面里排除;PopBar 的其它窗口(Deck、翻译面板、浮动条、二维码、贴图…)
/// 属于用户想截/想录的内容,不排除。
enum CaptureChrome {
    private static let identifier = NSUserInterfaceItemIdentifier("popbar.capture-chrome")

    /// 创建工具界面窗口时调用一次
    @MainActor
    static func mark(_ window: NSWindow) {
        window.identifier = identifier
    }

    @MainActor
    static func windowNumbers() -> Set<Int> {
        Set(NSApp.windows.filter { $0.identifier == identifier && $0.windowNumber > 0 }.map(\.windowNumber))
    }

    /// 要排除的 SCWindow。注意要用 onScreenWindowsOnly: false 重新取一份内容:
    /// 过滤器建好后才 orderFront 的工具窗口(录制红框、控制条、隐藏中的悬停提示)
    /// 此刻还不在屏幕上,只查在屏窗口会漏掉,之后就被录进去了
    static func excludedWindows() async -> [SCWindow] {
        let ids = await MainActor.run { windowNumbers() }
        guard !ids.isEmpty,
              let all = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [] }
        return all.windows.filter { ids.contains(Int($0.windowID)) }
    }
}
