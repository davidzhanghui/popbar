import Cocoa

extension NSApplication {
    /// PopBar 是 accessory(LSUIElement)应用,平时没有前台身份。
    /// 自己创建的窗口/弹窗即使 `makeKeyAndOrderFront`,也只会排在当前前台 App 的窗口后面,
    /// 看起来就是「点了没反应」。展示任何自建窗口或弹窗之前都先调用这里切到前台。
    func activateForUI() {
        if #available(macOS 14.0, *) { activate() }
        else { activate(ignoringOtherApps: true) }
    }
}

/// 普通 NSWindow 不响应 Esc;设置/偏好这类窗口用 Esc→close。
/// close() 会走 windowShouldClose,设置窗口的未保存提示照常生效。
final class EscClosableWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }   // Esc
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { close() }
}
