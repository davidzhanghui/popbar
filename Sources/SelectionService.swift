import Cocoa
import ApplicationServices

/// 获取当前选中文字与选区位置:
/// 1. 优先走 Accessibility API(无侵入)
/// 2. 失败则降级为"备份剪贴板 → 模拟 Cmd+C → 读剪贴板 → 还原剪贴板"
enum SelectionService {
    struct Result {
        let text: String
        let bounds: CGRect?   // Cocoa 坐标(左下原点)
    }

    static func fetch(completion: @escaping (Result?) -> Void) {
        if let r = axSelection(), !r.text.isEmpty {
            completion(r)
            return
        }
        copyViaPasteboard { text in
            if let t = text, !t.isEmpty {
                completion(Result(text: t, bounds: nil))
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - Accessibility

    private static func axSelection() -> Result? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }

        let el = focusedRef as! AXUIElement

        // 为 Chrome / Electron 类应用开启 EnhancedUserInterface,否则读不到选区
        var pid: pid_t = 0
        if AXUIElementGetPid(el, &pid) == .success {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appEl,
                "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el,
                kAXSelectedTextAttribute as CFString, &textRef) == .success else {
            return nil
        }

        let text: String?
        if let s = textRef as? String {
            text = s
        } else if let a = textRef as? NSAttributedString {
            text = a.string
        } else {
            text = nil
        }
        guard let t = text else { return nil }

        var bounds: CGRect? = nil
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el,
                kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef {
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
        return Result(text: t, bounds: bounds)
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
                if changed { restorePasteboard(pb, backup) }  // 剪贴板被动过才还原
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
