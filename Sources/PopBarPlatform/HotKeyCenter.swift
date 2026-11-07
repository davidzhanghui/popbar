import Carbon.HIToolbox
import Cocoa
import PopBarCore

/// 全局快捷键：Carbon `RegisterEventHotKey`。
///
/// 与以前「CGEventTap 只监听」的做法相比：
/// - 系统会吞掉按键，不再漏给前台 App（终端里不会多出字符，中文输入法下不会切换输入法）；
/// - 不需要辅助功能权限；
/// - 注册失败（被系统或别的 App 占用）当场知道，设置页据此标红。
///
/// 参考：soffes/HotKey、Decklet `decklet-sys/src/hotkeys.rs`（经由 global-hotkey，同一系统 API）。
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    private struct Entry {
        let id: String
        let combo: KeyCombo
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    /// 录制快捷键时暂停：所有组合临时注销，录完再恢复
    public private(set) var isSuspended = false
    private var suspendedSpecs: [(String, KeyCombo, () -> Void)] = []
    /// 最近一次 `register` 失败的动作 id
    public private(set) var failures: Set<String> = []

    private init() {}

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            HotKeyCenter.shared.fire(hk.id)
            return noErr
        }, 1, &spec, nil, &eventHandler)
        if status != noErr { eventHandler = nil }
    }

    private func fire(_ id: UInt32) {
        guard let e = entries[id] else { return }
        DispatchQueue.main.async { e.handler() }
    }

    /// 注册一个组合；成功返回 true。同一个 id 重复注册会先注销旧的。
    @discardableResult
    public func register(id: String, combo: KeyCombo, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        if isSuspended {
            suspendedSpecs.append((id, combo, handler))
            return true
        }
        installHandlerIfNeeded()
        let hid = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x50504252) /* 'PPBR' */, id: hid)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers),
                                         hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            failures.insert(id)
            return false
        }
        failures.remove(id)
        entries[hid] = Entry(id: id, combo: combo, ref: ref, handler: handler)
        return true
    }

    public func unregister(id: String) {
        for (k, e) in entries where e.id == id {
            UnregisterEventHotKey(e.ref)
            entries.removeValue(forKey: k)
        }
        suspendedSpecs.removeAll { $0.0 == id }
        failures.remove(id)
    }

    public func unregisterAll() {
        for e in entries.values { UnregisterEventHotKey(e.ref) }
        entries.removeAll()
        suspendedSpecs.removeAll()
        failures.removeAll()
    }

    /// 当前已注册的 [动作 id: 组合]
    public var registered: [String: KeyCombo] {
        Dictionary(entries.values.map { ($0.id, $0.combo) }, uniquingKeysWith: { a, _ in a })
    }

    /// 录制器开始录制时调用：注销全部，录制中按下的组合不会触发动作
    public func suspend() {
        guard !isSuspended else { return }
        suspendedSpecs = entries.values.map { ($0.id, $0.combo, $0.handler) }
        for e in entries.values { UnregisterEventHotKey(e.ref) }
        entries.removeAll()
        isSuspended = true
    }

    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        let specs = suspendedSpecs
        suspendedSpecs = []
        for (id, combo, h) in specs { register(id: id, combo: combo, handler: h) }
    }

    public static func carbonModifiers(_ m: KeyModifiers) -> UInt32 {
        var out: UInt32 = 0
        if m.contains(.command) { out |= UInt32(cmdKey) }
        if m.contains(.option) { out |= UInt32(optionKey) }
        if m.contains(.control) { out |= UInt32(controlKey) }
        if m.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }

    /// NSEvent 的修饰键 → KeyModifiers（录制器用）
    public static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    /// 菜单项展示用的 (keyEquivalent, modifierMask)
    public static func menuEquivalent(_ spec: String) -> (key: String, mask: NSEvent.ModifierFlags)? {
        guard let c = KeyCombo(spec) else { return nil }
        let key: String
        switch c.keyCode {
        case 49: key = " "
        case 36: key = "\r"
        case 48: key = "\t"
        case 53: key = "\u{1b}"
        default:
            guard let name = KeyCombo.names[c.keyCode] else { return nil }
            if name.count == 1 {
                key = name
            } else if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...12).contains(n),
                      let u = Unicode.Scalar(0xF703 + n) {
                key = String(Character(u))
            } else { return nil }
        }
        var mask: NSEvent.ModifierFlags = []
        if c.modifiers.contains(.control) { mask.insert(.control) }
        if c.modifiers.contains(.option) { mask.insert(.option) }
        if c.modifiers.contains(.shift) { mask.insert(.shift) }
        if c.modifiers.contains(.command) { mask.insert(.command) }
        return (key, mask)
    }
}
