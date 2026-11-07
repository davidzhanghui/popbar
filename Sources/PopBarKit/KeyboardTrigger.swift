import Cocoa
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 键盘操作浮动条:
/// - 全局快捷键(默认 ⌃⌥B,由 HotkeyManager 注册)唤起浮动条,进入「键盘模式」
/// - 键盘模式期间临时安装可拦截的 event tap:
///   ←/→ 移动高亮、Enter 执行、Esc 关闭;超时或关闭后自动摘除,避免键盘失灵
/// 键盘模式的拦截 tap:存在时间短暂(工具条键盘模式期间),
/// 回调只处理方向/回车/Esc,其余原样放行;挂掉或超时就摘除。
final class KeyboardInterceptor {
    static let shared = KeyboardInterceptor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var safetyTimer: Timer?

    private init() {}

    var installed: Bool { tap != nil }

    /// 安装拦截 tap;maxAge 秒后强制摘除兜底
    func install(maxAge: TimeInterval = 30) {
        uninstall()
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,           // 可拦截:返回 nil 即吞掉事件
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let k = Unmanaged<KeyboardInterceptor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // tap 被系统禁用:兜底恢复 + 摘除,不阻塞键盘
                    k.uninstall()
                    return Unmanaged.passUnretained(event)
                }
                return k.handle(event: event)
                    ? nil                                  // 吞掉
                    : Unmanaged.passUnretained(event)      // 放行
            },
            userInfo: refcon)
        guard let tap,
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            self.tap = nil
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        safetyTimer = Timer.scheduledTimer(withTimeInterval: maxAge, repeats: false) { [weak self] _ in
            self?.uninstall()
        }
    }

    func uninstall() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
    }

    /// 返回 true = 已处理(吞掉事件)
    private func handle(event: CGEvent) -> Bool {
        let bar = FloatingBarController.shared
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        switch code {
        case 123: return bar.moveHighlight(-1)         // ←
        case 124: return bar.moveHighlight(1)          // →
        case 36, 76: return bar.performHighlighted()   // Enter
        case 53:                                       // Esc
            bar.hide()
            return true
        default:
            return false
        }
    }
}
