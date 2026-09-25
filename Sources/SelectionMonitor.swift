import Cocoa

/// 通过 CGEventTap 监听全局鼠标/键盘事件,判断"划词"行为
final class SelectionMonitor {
    var enabled = true
    private(set) var tapInstalled = false

    private var eventTap: CFMachPort?
    private var downPoint = CGPoint.zero
    private var didDrag = false
    private var clickState: Int64 = 0
    private var downInsideBar = false
    private var downInsidePanel = false

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
        guard enabled else { return }

        switch type {
        case .leftMouseDown:
            let cocoaLoc = Screen.cocoaPoint(from: event.location)
            let translation = TranslationPanelController.shared
            let insideTranslation = translation.isVisible && translation.frame.contains(cocoaLoc)
            if translation.isVisible && !insideTranslation && !translation.isPinned { translation.close() }
            // 翻译面板、设置窗口里的拖选/点击都属于 PopBar 自己,不触发取词
            downInsidePanel = insideTranslation || Self.insideSettings(cocoaLoc)
            downInsideBar = FloatingBarController.shared.isVisible
                && FloatingBarController.shared.frame.contains(cocoaLoc)
            downPoint = event.location
            didDrag = false
            clickState = event.getIntegerValueField(.mouseEventClickState)
            if !downInsideBar && !downInsidePanel && FloatingBarController.shared.isVisible {
                FloatingBarController.shared.hide()
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
            let mode = ConfigStore.shared.config.triggerMode
            let triggered: Bool
            switch mode {
            case "drag":        triggered = didDrag
            case "doubleClick": triggered = clickState >= 2
            default:            triggered = didDrag || clickState >= 2
            }
            if triggered {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    SelectionService.fetch { result in
                        guard let result,
                              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { return }
                        FloatingBarController.shared.show(text: result.text, anchor: result.bounds)
                    }
                }
            }

        case .rightMouseDown, .otherMouseDown:
            let translation = TranslationPanelController.shared
            if translation.isVisible {
                if translation.frame.contains(Screen.cocoaPoint(from: event.location)) { return }
                if !translation.isPinned { translation.close() }
            }
            if FloatingBarController.shared.isVisible {
                FloatingBarController.shared.hide()
            }

        case .scrollWheel:
            // 面板内的滚动交给面板自己处理
            let translation = TranslationPanelController.shared
            let point = Screen.cocoaPoint(from: event.location)
            if translation.isVisible, translation.frame.contains(point) { return }
            if Self.insideSettings(point) { return }
            if FloatingBarController.shared.isVisible {
                FloatingBarController.shared.hide()
            }

        case .keyDown:
            // 面板是 key window,按键(含 Esc 关闭、Cmd+C 复制)由它处理,不要隐藏
            if TranslationPanelController.shared.isVisible { return }
            if FloatingBarController.shared.isVisible {
                FloatingBarController.shared.hide()
            }

        default:
            break
        }
    }

    private static func insideSettings(_ point: CGPoint) -> Bool {
        let settings = SettingsWindowController.shared
        if settings.isVisible && settings.frame.contains(point) { return true }
        let prefs = PreferencesWindowController.shared
        return prefs.isVisible && prefs.frame.contains(point)
    }
}
