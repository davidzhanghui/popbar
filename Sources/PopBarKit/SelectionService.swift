import Cocoa
import ApplicationServices
import PopBarCore
import PopBarPlatform
import PopBarDesign

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

    private static let axQueue = DispatchQueue(label: "popbar.ax.selection", qos: .userInteractive)
    private static let genLock = NSLock()
    nonisolated(unsafe) private static var generation: UInt64 = 0
    /// 防止连续划词并发进入 copyViaPasteboard 互相覆盖剪贴板（仅主线程读写）
    nonisolated(unsafe) private static var isCopyingViaPasteboard = false
    /// AX 取词总预算：前台 App 卡住时最多等这么久，过期即放弃本次取词（不再模拟 ⌘C）
    static let axBudget: TimeInterval = 0.4
    private enum AXOutcome { case found(String, CGRect?, AXUIElement, CFRange?), secure, none, cancelled }

    private static func nextGeneration() -> UInt64 {
        genLock.withLock {
            generation &+= 1
            return generation
        }
    }

    private static func isCurrent(_ gen: UInt64) -> Bool {
        genLock.withLock { generation == gen }
    }

    /// 作废在途取词请求（用户点击别处、滚动或发起新划词时调用）
    static func cancelPending() {
        _ = nextGeneration()
    }

    static func fetch(expectedPID: pid_t? = nil, completion: @escaping (Result?) -> Void) {
        let gen = nextGeneration()
        let allowFallback = ConfigStore.shared.config.clipboardFallback   // 主线程读配置
        var finished = false                                               // 只在主线程读写
        let budget = DispatchWorkItem {
            guard !finished else { return }
            finished = true
            if isCurrent(gen) { cancelPending() }
            completion(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + axBudget, execute: budget)
        axQueue.async {
            guard isCurrent(gen) else {
                DispatchQueue.main.async {
                    guard !finished else { return }
                    finished = true
                    budget.cancel()
                    completion(nil)
                }
                return
            }
            let outcome = axOutcome(gen: gen)
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                budget.cancel()
                guard isCurrent(gen) else { completion(nil); return }
                if let pid = expectedPID,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                    completion(nil)
                    return
                }
                switch outcome {
                case .found(let t, let raw, let el, let range):
                    let b = raw.map { Screen.cocoaRect(from: $0) }.flatMap { ScreenPlacement.isUsable($0) ? $0 : nil }
                    completion(Result(text: t, bounds: b, element: el, range: range))
                case .secure, .cancelled:
                    completion(nil)
                case .none:
                    guard allowFallback, !isCopyingViaPasteboard else { completion(nil); return }
                    isCopyingViaPasteboard = true
                    copyViaPasteboard { text in
                        isCopyingViaPasteboard = false
                        guard isCurrent(gen) else { completion(nil); return }
                        if let pid = expectedPID,
                           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                            completion(nil)
                            return
                        }
                        if let t = text, !t.isEmpty { completion(Result(text: t, bounds: nil, viaPasteboard: true)) }
                        else { completion(nil) }
                    }
                }
            }
        }
    }

    /// 系统当前聚焦的 AX 元素
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXSupport.systemWide()   // 带 0.25 秒消息超时:卡死的 App 不再拖住主线程
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let el = focusedRef as! AXUIElement
        AXSupport.applyTimeout(el)
        return el
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

    private static func axOutcome(gen: UInt64) -> AXOutcome {
        guard isCurrent(gen) else { return .cancelled }
        guard let el = focusedElement() else { return .none }
        guard isCurrent(gen) else { return .cancelled }
        if isSecureField(el) { return .secure }
        guard isCurrent(gen) else { return .cancelled }

        // Chrome / Electron 类应用需要 AXManualAccessibility 才暴露选区;每个进程只设一次。
        // 不再设 AXEnhancedUserInterface:它会让部分 App 的窗口动画、布局异常。
        var pid: pid_t = 0
        if AXUIElementGetPid(el, &pid) == .success {
            _ = AXSupport.enableManualAccessibility(pid: pid)
        }

        guard isCurrent(gen) else { return .cancelled }
        guard let t = axSelectedText(el), !t.isEmpty else { return .none }
        guard isCurrent(gen) else { return .cancelled }

        var rawBounds: CGRect? = nil
        var range: CFRange? = nil
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el,
                kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef {
            var cfRange = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) {
                range = cfRange
            }
            if isCurrent(gen) {
                var bRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(el,
                        "AXBoundsForRange" as CFString, rangeRef, &bRef) == .success,
                   let bRef {
                    var r = CGRect.zero
                    if AXValueGetValue(bRef as! AXValue, .cgRect, &r) {
                        rawBounds = r
                    }
                }
            }
        }

        return .found(t, rawBounds, el, range)
    }


    // MARK: - Pasteboard fallback

    /// 模拟 ⌘C 兜底:先完整快照剪贴板(超过 20MB 或拿不到就放弃兜底,宁可不取词也不丢用户剪贴板),
    /// 读到文字后原样还原,还原时带上 Transient / AutoGenerated 标记,剪贴板管理器不会记下这次写入。
    private static func copyViaPasteboard(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        guard let backup = PasteboardSnapshot.take(pb) else {
            completion(nil)
            return
        }
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
                if changed {                                 // 剪贴板被动过才还原
                    PasteboardGuard.declareOwn(backup.restore(to: pb))
                }
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
