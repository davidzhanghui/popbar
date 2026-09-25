import Cocoa

/// #11 键盘触发与键盘操作:
/// - 全局快捷键(默认 ctrl+opt+space)唤起工具条,进入「键盘模式」
/// - 键盘模式期间临时安装可拦截的 event tap:
///   ←/→ 移动高亮、Enter 执行、Esc 关闭;超时或关闭后自动摘除,避免键盘失灵
enum Hotkey {
    /// "ctrl+opt+space" → (flags, keyCode);keyCode 用 CGKeyCode 数值
    static func parse(_ s: String) -> (flags: CGEventFlags, key: CGKeyCode)? {
        var flags: CGEventFlags = []
        var keyName = ""
        for part in s.lowercased().components(separatedBy: "+") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "shift", "⇧": flags.insert(.maskShift)
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            default: keyName = part.trimmingCharacters(in: .whitespaces)
            }
        }
        guard let key = keyCodes[keyName] else { return nil }
        return (flags, key)
    }

    static let keyCodes: [String: CGKeyCode] = [
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "`": 50, "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42,
        ";": 41, "'": 39, ",": 43, ".": 47, "/": 44,
    ]

    /// 事件是否匹配快捷键(flags 只需包含声明的修饰键)
    static func matches(_ event: CGEvent, _ spec: (flags: CGEventFlags, key: CGKeyCode)) -> Bool {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == spec.key else { return false }
        let f = event.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        return f == spec.flags
    }
}

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
