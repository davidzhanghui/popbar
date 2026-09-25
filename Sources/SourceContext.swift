import Cocoa
import ApplicationServices

/// 一次"取词/触发"的完整上下文:文本、来源 App、AX 元素与选区信息。
/// 工具条动作(大小写/脱敏/Dev 替换等)靠这里保存的 element 与选区做就地改写。
struct SourceContext {
    enum Origin: String {
        case selection    // 划词取得,可就地替换
        case ocr          // 截图 OCR,没有原文位置
        case input        // 面板里手动输入
        case clipboard    // 剪贴板
        case other        // 截图工具等其他入口
    }

    var text: String
    var bounds: CGRect? = nil                // Cocoa 坐标(左下原点)
    var app: NSRunningApplication? = nil     // 触发时的前台 App
    var bundleID: String? = nil
    var appName: String? = nil
    var element: AXUIElement? = nil          // AX 路径取词时的聚焦元素
    var selectedRange: CFRange? = nil        // 选区在 AXValue 里的范围
    var origin: Origin = .selection

    var canReplace: Bool { origin == .selection }

    init(text: String, origin: Origin = .selection) {
        self.text = text
        self.origin = origin
        let app = NSWorkspace.shared.frontmostApplication
        self.app = app
        self.bundleID = app?.bundleIdentifier
        self.appName = app?.localizedName
    }

    /// 链式补字段
    func applying(_ mutate: (inout SourceContext) -> Void) -> SourceContext {
        var c = self
        mutate(&c)
        return c
    }
}
