import Foundation

/// 修饰键集合（与 AppKit / Carbon 无关，Platform 层负责映射）
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let shift   = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// 一个快捷键组合：修饰键 + 虚拟键码（kVK_*）。配置里写成 "ctrl+opt+b"。
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public var modifiers: KeyModifiers
    public var keyCode: UInt16

    public init(modifiers: KeyModifiers, keyCode: UInt16) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    /// "ctrl+opt+space" → KeyCombo；无法解析返回 nil（空串也返回 nil）
    public init?(_ spec: String) {
        var mods: KeyModifiers = []
        var keyName = ""
        let trimmed = spec.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        for raw in trimmed.components(separatedBy: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "shift", "⇧": mods.insert(.shift)
            case "cmd", "command", "⌘": mods.insert(.command)
            case "": keyName = "+"    // "cmd++" 之类：最后一段为空
            default: keyName = part
            }
        }
        guard let code = KeyCombo.keyCodes[keyName] else { return nil }
        self.modifiers = mods
        self.keyCode = code
    }

    /// 配置里的写法："ctrl+opt+b"
    public var spec: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(KeyCombo.names[keyCode] ?? "?")
        return parts.joined(separator: "+")
    }

    /// 给人看的写法："⌃⌥B"
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + KeyCombo.displayKey(keyCode)
    }

    public var description: String { display }

    /// 把配置字符串转成展示写法；空或无法解析时原样返回
    public static func display(_ spec: String) -> String {
        KeyCombo(spec)?.display ?? spec
    }

    static func displayKey(_ code: UInt16) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 53: return "⎋"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let n = names[code] ?? "?"
            return n.count == 1 ? n.uppercased() : n.uppercased()
        }
    }

    public static let keyCodes: [String: UInt16] = [
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53, "delete": 51,
        "left": 123, "right": 124, "down": 125, "up": 126,
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

    /// keyCode → 规范名（反查表，别名取最短的那个）
    public static let names: [UInt16: String] = {
        var m: [UInt16: String] = [:]
        for (name, code) in keyCodes {
            if let old = m[code], old.count <= name.count, !(old == "enter" && name == "return") { continue }
            m[code] = name
        }
        m[36] = "return"; m[53] = "esc"
        return m
    }()
}

// MARK: - 冲突检测

/// 快捷键配置的问题：设置页录制器据此当场标红
public enum HotkeyIssue: Equatable, Sendable {
    /// 写法无法解析
    case invalid
    /// 和另一个动作重复（关联值是另一个动作的 id）
    case duplicate(String)
    /// 系统已占用（关联值是占用者说明）
    case systemReserved(String)
    /// 系统拒绝注册（Carbon 返回错误，多半被别的 App 占了）
    case registrationFailed
}

public enum HotkeyAnalysis {
    /// 常见的系统保留组合；Carbon 注册这些组合要么失败、要么和系统抢键
    public static let systemReserved: [KeyCombo: (String, String)] = {
        var m: [KeyCombo: (String, String)] = [:]
        func add(_ s: String, _ zh: String, _ en: String) { if let k = KeyCombo(s) { m[k] = (zh, en) } }
        add("cmd+space", "聚焦搜索", "Spotlight")
        add("ctrl+space", "上一个输入法", "Previous input source")
        add("ctrl+opt+space", "下一个输入法", "Next input source")
        add("cmd+tab", "切换 App", "App Switcher")
        add("cmd+shift+3", "系统截屏", "Screenshot")
        add("cmd+shift+4", "系统截屏", "Screenshot")
        add("cmd+shift+5", "系统截屏", "Screenshot")
        add("cmd+q", "退出 App", "Quit")
        add("cmd+w", "关闭窗口", "Close Window")
        add("ctrl+up", "调度中心", "Mission Control")
        add("ctrl+down", "应用程序窗口", "App Exposé")
        return m
    }()

    /// bindings: [(动作 id, 配置字符串)]，空串表示未设置、不参与检测。
    /// 返回每个有问题的动作 id 对应的问题；重复时双方都会被标出来。
    public static func issues(_ bindings: [(id: String, spec: String)]) -> [String: HotkeyIssue] {
        var result: [String: HotkeyIssue] = [:]
        var firstOwner: [KeyCombo: String] = [:]
        for b in bindings {
            let s = b.spec.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            guard let combo = KeyCombo(s) else { result[b.id] = .invalid; continue }
            if let owner = firstOwner[combo] {
                result[b.id] = .duplicate(owner)
                if result[owner] == nil { result[owner] = .duplicate(b.id) }
                continue
            }
            firstOwner[combo] = b.id
            if let r = systemReserved[combo] {
                result[b.id] = .systemReserved(L10n.t(r.0, r.1))
            } else if combo.modifiers.isEmpty || combo.modifiers == [.shift] {
                // 没有修饰键的全局热键会吞掉正常输入
                result[b.id] = .invalid
            }
        }
        return result
    }

    /// 解析结果缓存：配置变化时解析一次，生成 [KeyCombo: 动作 id]；无效 / 重复的不进表
    public static func table(_ bindings: [(id: String, spec: String)]) -> [KeyCombo: String] {
        var t: [KeyCombo: String] = [:]
        for b in bindings {
            guard let c = KeyCombo(b.spec), t[c] == nil, !c.modifiers.isEmpty else { continue }
            t[c] = b.id
        }
        return t
    }
}
