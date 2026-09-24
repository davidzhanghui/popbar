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
            downInsideBar = FloatingBarController.shared.isVisible
                && FloatingBarController.shared.frame.contains(cocoaLoc)
            downPoint = event.location
            didDrag = false
            clickState = event.getIntegerValueField(.mouseEventClickState)
            if !downInsideBar && FloatingBarController.shared.isVisible {
                FloatingBarController.shared.hide()
            }

        case .leftMouseDragged:
            if !didDrag,
               hypot(event.location.x - downPoint.x, event.location.y - downPoint.y) > 4 {
                didDrag = true
            }

        case .leftMouseUp:
            if downInsideBar {          // 点在浮动条上:交给按钮处理,不再触发取词
                downInsideBar = false
                return
            }
            if didDrag || clickState >= 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    SelectionService.fetch { result in
                        guard let result,
                              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { return }
                        FloatingBarController.shared.show(text: result.text, anchor: result.bounds)
                    }
                }
            }

        case .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown:
            if FloatingBarController.shared.isVisible {
                FloatingBarController.shared.hide()
            }

        default:
            break
        }
    }
}
