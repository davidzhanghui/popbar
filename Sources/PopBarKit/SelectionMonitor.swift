import Cocoa
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 通过 CGEventTap(只监听)观察全局鼠标/键盘事件,判断"划词"行为
final class SelectionMonitor {
    static let shared = SelectionMonitor()
    private init() {}

    var enabled = true
    private(set) var tapInstalled = false

    private var eventTap: CFMachPort?
    private var downPoint = CGPoint.zero
    private var didDrag = false
    private var clickState: Int64 = 0
    private var downInsideBar = false
    private var downInsidePanel = false
    /// #11 shift+方向键选区的去抖计数
    private var keyboardSelToken = 0

    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let m = Unmanaged<SelectionMonitor>.fromOpaque(refcon).takeUnretainedValue()
                m.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon)

        guard let eventTap,
              let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else {
            tapInstalled = false
            return
        }
        tapInstalled = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // 系统超时禁用 tap 时重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // 全局快捷键已交给 HotkeyManager(Carbon 注册,系统吞键),这里不再逐个比对按键
        // 倒计时里的 Esc = 取消(倒计时面板不接收键盘,只能在这里拦)
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53,
           MainActor.assumeIsolated({ RecordSession.shared.isCountingDown }) {
            Task { @MainActor in RecordSession.shared.cancelCountdown() }
            return
        }
        if SnapController.shared.isScrolling {
            if type == .keyDown {
                switch event.getIntegerValueField(.keyboardEventKeycode) {
                case 53: DispatchQueue.main.async { SnapController.shared.cancelScroll() }
                case 36, 76: DispatchQueue.main.async { SnapController.shared.completeScroll(.copy) }
                default: break
                }
            }
            return
        }
        if SnapController.shared.isActive { return }
        guard enabled, !ConfigStore.shared.config.selectionPaused else { return }

        switch type {
        case .leftMouseDown:
            let cocoaLoc = Screen.cocoaPoint(from: event.location)
            let translation = TranslationPanelController.shared
            let insideTranslation = translation.isVisible && translation.frame.contains(cocoaLoc)
            if translation.isVisible && !insideTranslation && !translation.isPinned { translation.close() }
            // 翻译面板、Deck、钉住的今日窗、贴图等 PopBar 自己窗口里的拖选/点击都不触发取词
            downInsidePanel = insideTranslation || SnapPinWindow.contains(cocoaLoc) || Self.insideOwnWindow(cocoaLoc)
            downInsideBar = FloatingBarController.shared.isVisible
                && FloatingBarController.shared.frame.contains(cocoaLoc)
            downPoint = event.location
            didDrag = false
            clickState = event.getIntegerValueField(.mouseEventClickState)
            if !downInsideBar && !downInsidePanel && FloatingBarController.shared.isVisible {
                FloatingBarController.shared.hideUnlessSpeaking()
            }

        case .leftMouseDragged:
            if !didDrag,
               hypot(event.location.x - downPoint.x, event.location.y - downPoint.y) > 4 {
                didDrag = true
            }

        case .leftMouseUp:
            if downInsidePanel {        // 在翻译面板内选择文字/点按钮:不触发取词
                downInsidePanel = false
                return
            }
            if downInsideBar {          // 点在浮动条上:交给按钮处理,不再触发取词
                downInsideBar = false
                return
            }
            // 按应用规则:不弹出 / 仅快捷键 的 App 里鼠标划词完全不触发(连取词都不做)
            let config = ConfigStore.shared.config
            let frontmost = NSWorkspace.shared.frontmostApplication
            if let rule = config.appRule(for: frontmost?.bundleIdentifier),
               rule.mode == .disabled || rule.mode == .hotkeyOnly { return }

            let triggered: Bool
            switch config.triggerMode {
            case .drag:        triggered = didDrag
            case .doubleClick: triggered = clickState >= 2
            case .both:        triggered = didDrag || clickState >= 2
            }
            if triggered {
                let delay = Double(config.selectionDelayMs) / 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.fetch(app: frontmost, keyboard: false)
                }
            }

        case .rightMouseDown, .otherMouseDown:
            if SnapPinWindow.contains(Screen.cocoaPoint(from: event.location)) { return }
            let translation = TranslationPanelController.shared
            if translation.isVisible {
                if translation.frame.contains(Screen.cocoaPoint(from: event.location)) { return }
                if !translation.isPinned { translation.close() }
            }
            if FloatingBarController.shared.isVisible {
                FloatingBarController.shared.hideUnlessSpeaking()
            }

        case .scrollWheel:
            // 面板内的滚动交给面板自己处理
            let translation = TranslationPanelController.shared
            let point = Screen.cocoaPoint(from: event.location)
            if translation.isVisible, translation.frame.contains(point) { return }
            if SnapPinWindow.contains(point) || Self.insideOwnWindow(point) { return }
            if FloatingBarController.shared.isVisible {
                FloatingBarController.shared.hideUnlessSpeaking()
            }

        case .keyDown:
            // 面板是 key window,按键(含 Esc 关闭、Cmd+C 复制)由它处理,不要隐藏
            if TranslationPanelController.shared.isVisible { return }
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            // 键盘选区触发:shift+方向/Home/End/PgUp/PgDn 后用防抖判选
            if ConfigStore.shared.config.triggerMode == .both,
               event.flags.contains(.maskShift),
               [123, 124, 125, 126, 115, 116, 119, 121].contains(Int(code)) {
                keyboardSelToken += 1
                let token = keyboardSelToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard self?.keyboardSelToken == token else { return }
                    self?.fetchSelectionAndShow(keyboard: false)
                }
                return
            }
            // 键盘模式下按键由拦截 tap 处理,不隐藏工具条
            if FloatingBarController.shared.isVisible,
               FloatingBarController.shared.keyboardMode { return }
            if FloatingBarController.shared.isVisible {
                // 朗读中:Esc 停止朗读并收条,其他按键不打断朗读
                if FloatingBarController.shared.isSpeaking {
                    if Int(code) == 53 {
                        DispatchQueue.main.async { FloatingBarController.shared.hide() }
                    }
                    return
                }
                FloatingBarController.shared.hide()
            }

        default:
            break
        }
    }

    /// 快捷键 / 键盘选区:取词并显示工具条;keyboard=true 进入键盘模式(←→ 切换、回车执行)
    func fetchSelectionAndShow(keyboard: Bool) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        // 不弹出的 App 连快捷键也不响应;「仅快捷键」的 App 正是走这里
        if let rule = ConfigStore.shared.config.appRule(for: frontmost?.bundleIdentifier),
           rule.mode == .disabled { return }
        // 键盘选区自动触发也受「暂停划词」约束;显式按快捷键不受
        if !keyboard && ConfigStore.shared.config.selectionPaused { return }
        fetch(app: frontmost, keyboard: keyboard)
    }

    private func fetch(app: NSRunningApplication?, keyboard: Bool) {
        let minChars = ConfigStore.shared.config.minChars
        SelectionService.fetch { result in
            guard let result else { return }
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, keyboard || trimmed.count >= minChars else { return }
            var ctx = SourceContext(text: result.text, origin: .selection)
            ctx.bounds = result.bounds
            ctx.element = result.element
            ctx.selectedRange = result.range
            if let app {
                ctx.app = app
                ctx.bundleID = app.bundleIdentifier
                ctx.appName = app.localizedName
            }
            FloatingBarController.shared.show(ctx: ctx, keyboard: keyboard)
        }
    }

    /// 点在 PopBar 自己的可交互窗口里(Deck、钉住的今日窗、结果卡片、剪贴板速选…)
    /// 只认该点最上层的窗口:被别的 App 挡住的 Deck 等窗口不算(否则 Deck 留在后台时,
    /// 它矩形范围内的划词全部失效)
    private static func insideOwnWindow(_ point: CGPoint) -> Bool {
        let barID = FloatingBarController.shared.windowID
        let topmost = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard topmost != barID else { return false }
        return NSApp.windows.contains { w in
            w.windowNumber == topmost && w.isVisible && !w.ignoresMouseEvents
        }
    }
}
