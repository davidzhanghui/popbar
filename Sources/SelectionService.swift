import Cocoa
import ApplicationServices

/// 获取当前选中文字与选区位置:
/// 1. 优先走 Accessibility API(无侵入)
/// 2. 失败则降级为"备份剪贴板 → 模拟 Cmd+C → 读剪贴板 → 还原剪贴板"
/// 安全输入框(密码框)两种路径都不取词。
enum SelectionService {
    struct Result {
        let text: String
        let bounds: CGRect?          // Cocoa 坐标(左下原点)
        var element: AXUIElement? = nil
        var range: CFRange? = nil
        var viaPasteboard = false
    }

    static func fetch(completion: @escaping (Result?) -> Void) {
        if let r = axSelection(), !r.text.isEmpty {
            completion(r)
            return
        }
        // 密码框:AX 读不到选区时也不允许 ⌘C 兜底
        if let el = focusedElement(), isSecureField(el) {
            completion(nil)
            return
        }
        // 「剪贴板取词」关闭时不模拟 Cmd+C(避免打扰剪贴板)
        guard ConfigStore.shared.config.clipboardFallback else {
            completion(nil)
            return
        }
        copyViaPasteboard { text in
            if let t = text, !t.isEmpty {
                completion(Result(text: t, bounds: nil, viaPasteboard: true))
            } else {
                completion(nil)
            }
        }
    }

    /// 系统当前聚焦的 AX 元素
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        return (focusedRef as! AXUIElement)
    }

    /// 密码框等安全输入控件
    static func isSecureField(_ el: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXSubrole" as CFString, &ref) == .success,
           let sub = ref as? String, sub == "AXSecureTextField" { return true }
        ref = nil
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref) == .success,
           let role = ref as? String, role == "AXSecureTextField" { return true }
        return false
    }

    /// AX 选中文本(按字面比较,首尾空白差异忽略)
    static func axSelectedText(_ el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el,
                kAXSelectedTextAttribute as CFString, &ref) == .success else { return nil }
        return (ref as? String) ?? (ref as? NSAttributedString).map { $0.string }
    }

    // MARK: - Accessibility

    private static func axSelection() -> Result? {
        guard let el = focusedElement() else { return nil }
        if isSecureField(el) { return nil }

        // 为 Chrome / Electron 类应用开启 EnhancedUserInterface,否则读不到选区
        var pid: pid_t = 0
        if AXUIElementGetPid(el, &pid) == .success {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appEl,
                "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }

        guard let t = axSelectedText(el) else { return nil }

        var bounds: CGRect? = nil
        var range: CFRange? = nil
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el,
                kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef {
            var cfRange = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) {
                range = cfRange
            }
            var bRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el,
                    "AXBoundsForRange" as CFString, rangeRef, &bRef) == .success,
               let bRef {
                var r = CGRect.zero
                if AXValueGetValue(bRef as! AXValue, .cgRect, &r) {
                    bounds = Screen.cocoaRect(from: r)
                }
            }
        }

        return Result(text: t, bounds: bounds, element: el, range: range)
    }


    // MARK: - Pasteboard fallback

    private static func copyViaPasteboard(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let backup = snapshotPasteboard(pb)
        let oldCount = pb.changeCount
        Actions.postKeyCombo(key: 8)   // kVK_ANSI_C,模拟 Cmd+C

        DispatchQueue.global(qos: .userInitiated).async {
            var result: String? = nil
            var changed = false
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline {
                if pb.changeCount != oldCount {
                    changed = true
                    result = pb.string(forType: .string)
                    break
                }
                usleep(15_000)
            }
            DispatchQueue.main.async {
                PasteboardGuard.declareOwn(pb.changeCount)   // ⌘C 写入属于自身行为
                if changed { PasteboardGuard.restore(pb, backup) }  // 剪贴板被动过才还原
                completion(result)
            }
        }
    }

    /// 把剪贴板内容物化成 (type, Data) 快照。
    /// 不能直接保存 NSPasteboardItem 再 writeObjects 回去——
    /// 懒加载/promise 类型的 item 会让 writeObjects: 抛 NSException 导致崩溃。
    static func snapshotPasteboard(_ pb: NSPasteboard) -> [[String: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [String: Data] = [:]
            for t in item.types {
                if let d = item.data(forType: t) { dict[t.rawValue] = d }
            }
            return dict
        }
    }

    static func restorePasteboard(_ pb: NSPasteboard, _ snapshot: [[String: Data]]) {
        pb.clearContents()
        let items = snapshot.filter { !$0.isEmpty }.map { dict -> NSPasteboardItem in
            let it = NSPasteboardItem()
            for (t, d) in dict {
                it.setData(d, forType: NSPasteboard.PasteboardType(t))
            }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
