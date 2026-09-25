import Cocoa

enum Actions {
    /// 向前台应用发送 Cmd+<key> 组合键(剪切/粘贴等)
    static func postKeyCombo(key: CGKeyCode, flags: CGEventFlags = .maskCommand) {
        postHotkey(key: key, modifierKey: 55, flags: flags)   // kVK_Command = 0x37
    }

    /// 完整模拟"修饰键按下 → 主键按下/抬起 → 修饰键抬起"的全套事件。
    /// 比只给主键事件打 flags 更可靠:有些全局热键监听依赖修饰键的 flagsChanged。
    static func postHotkey(key: CGKeyCode, modifierKey: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        postFlagsChanged(src, key: modifierKey, down: true, flags: flags)

        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)

        postFlagsChanged(src, key: modifierKey, down: false, flags: [])
    }

    private static func postFlagsChanged(_ src: CGEventSource?, key: CGKeyCode,
                                         down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
        else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}
