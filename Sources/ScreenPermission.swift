import Cocoa

/// 屏幕录制权限:截屏与截图翻译共用
enum ScreenPermission {
    /// 已授权返回 true;否则触发系统授权弹窗并提示用户去系统设置
    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()   // 触发系统授权弹窗
        let a = NSAlert()
        a.messageText = L10n.t("需要「屏幕录制」权限", "Screen Recording Permission Required")
        a.informativeText = L10n.t(
            "截屏、截图翻译和录屏需要读取屏幕内容。\n请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许 PopBar,然后重新使用本功能。",
            "Screenshot, screenshot translation and screen recording need to read the screen.\nPlease allow PopBar in System Settings → Privacy & Security → Screen Recording, then try again.")
        a.addButton(withTitle: L10n.t("打开设置", "Open Settings"))
        a.addButton(withTitle: L10n.t("取消", "Cancel"))
        NSApp.activateForUI()
        if a.runModal() == .alertFirstButtonReturn {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(u)
            }
        }
        return false
    }
}
