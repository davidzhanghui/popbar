import Cocoa
import AVFoundation

/// 浮动工具条:无边框 NSPanel + 毛玻璃背景。
/// 动作全部由 ActionRegistry 提供——内置、上下文、AI、扩展统一渲染,
/// 超出 maxVisible 的收进「…」溢出菜单。
final class FloatingBarController: NSObject {
    static let shared = FloatingBarController()

    private var panel: NSPanel?
    private(set) var ctx = SourceContext(text: "")
    private var visibleActions: [BarAction] = []
    private var overflowActions: [BarAction] = []
    private var buttons: [BarButton] = []
    private let speech = AVSpeechSynthesizer()
    /// 键盘模式:←/→ 移动高亮、Enter 执行(M8)
    private(set) var keyboardMode = false
    private var highlightIndex = -1

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }
    var windowID: Int { panel?.windowNumber ?? 0 }

    /// 仅截图工具用:强制指定浅色/深色外观
    func setAppearance(_ name: NSAppearance.Name) {
        panel?.appearance = NSAppearance(named: name)
    }

    // MARK: - Show / Hide

    /// 兼容旧调用(截图工具等)
    func show(text: String, anchor: CGRect?) {
        show(ctx: SourceContext(text: text, origin: .other).applying { $0.bounds = anchor })
    }

    func show(ctx: SourceContext, keyboard: Bool = false) {
        self.ctx = ctx
        keyboardMode = keyboard
        highlightIndex = -1
        // #11 键盘模式装拦截 tap;非键盘模式确保摘除
        if keyboard { KeyboardInterceptor.shared.install() }
        else { KeyboardInterceptor.shared.uninstall() }
        let resolved = ActionRegistry.resolve(for: ctx)
        visibleActions = resolved.visible
        overflowActions = resolved.overflow
        guard !visibleActions.isEmpty || !overflowActions.isEmpty else { return }

        buttons = visibleActions.map { makeButton($0) }
        var views: [NSView] = buttons
        if !overflowActions.isEmpty {
            let more = BarButton(image: NSImage(systemSymbolName: "ellipsis",
                                                accessibilityDescription: L10n.t("更多", "More")) ?? NSImage(),
                                 target: self, action: #selector(showOverflowMenu(_:)))
            more.accentColor = .secondaryLabelColor
            more.contentTintColor = .secondaryLabelColor
            more.isBordered = false
            more.toolTip = L10n.t("更多动作", "More actions")
            more.imageScaling = .scaleProportionallyDown
            more.widthAnchor.constraint(equalToConstant: 28).isActive = true
            more.heightAnchor.constraint(equalToConstant: 26).isActive = true
            views.append(more)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        let fit = stack.fittingSize
        let pad: CGFloat = 8
        let size = CGSize(width: fit.width + pad * 2, height: fit.height + pad)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        stack.frame = NSRect(x: pad, y: pad / 2, width: fit.width, height: fit.height)
        effect.addSubview(stack)

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.acceptsMouseMovedEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel = p
        }
        panel?.contentView = effect
        panel?.setContentSize(size)

        // ---- 定位:优先放在选区上方,放不下则放下方 ----
        var origin: CGPoint
        if let a = ctx.bounds {
            origin = CGPoint(x: a.midX - size.width / 2, y: a.maxY + 6)
        } else {
            let m = NSEvent.mouseLocation
            origin = CGPoint(x: m.x - size.width / 2, y: m.y + 12)
        }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let f = screen?.visibleFrame {
            if origin.y + size.height > f.maxY {
                origin.y = ctx.bounds.map { $0.minY - size.height - 6 } ?? (f.maxY - size.height - 4)
            }
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        panel?.setFrameOrigin(origin)
        panel?.orderFront(nil)
    }

    func hide() {
        keyboardMode = false
        KeyboardInterceptor.shared.uninstall()
        BarTooltip.shared.hide()
        panel?.orderOut(nil)
    }

    // MARK: - 溢出菜单

    @objc private func showOverflowMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (i, action) in overflowActions.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(runOverflowItem(_:)),
                                  keyEquivalent: "")
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.target = self
            item.tag = i
            if let submenu = action.menu?(ctx) {
                item.action = nil
                item.submenu = submenu
            }
            menu.addItem(item)
        }
        // 菜单点击发生在工具条外,SelectionMonitor 会 hide()——ctx 不清空,动作照常执行
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func runOverflowItem(_ sender: NSMenuItem) {
        guard overflowActions.indices.contains(sender.tag) else { return }
        performAction(overflowActions[sender.tag])
    }

    // MARK: - 动作执行

    @objc private func runAction(_ sender: BarButton) {
        guard sender.actionIndex < visibleActions.count else { return }
        performAction(visibleActions[sender.actionIndex])
    }

    private func performAction(_ action: BarAction) {
        if let submenu = action.menu?(ctx) {
            // 有子菜单的动作:弹出该菜单
            submenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        UsageStats.shared.record(action.id, bundleID: ctx.bundleID)
        action.perform(ctx)
    }

    // MARK: - 键盘模式(M8)

    /// ←/→ 移动高亮;返回是否已处理
    func moveHighlight(_ delta: Int) -> Bool {
        guard keyboardMode, !visibleActions.isEmpty else { return false }
        highlightIndex = (highlightIndex + delta + visibleActions.count) % visibleActions.count
        for (i, b) in buttons.enumerated() {
            b.isHighlightedByKeyboard = (i == highlightIndex)
        }
        return true
    }

    func performHighlighted() -> Bool {
        guard keyboardMode, visibleActions.indices.contains(highlightIndex) else { return false }
        performAction(visibleActions[highlightIndex])
        return true
    }

    // MARK: - 信息条 / 忙碌条 / 结果条

    /// 把弹条内容临时换成一行文字(字数统计等),几秒后自动隐藏
    func showInfo(_ info: String) {
        showStrip(NSStackView(views: [stripLabel(info)]), height: 30, autoHide: 2.0)
    }

    /// 忙碌状态(AI 动作 replace 模式):转圈 + 文字 + 取消
    func showBusy(_ info: String, onCancel: @escaping () -> Void) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let cancel = ClosureButton(title: L10n.t("取消", "Cancel"), action: onCancel)
        cancel.isBordered = false
        cancel.font = .systemFont(ofSize: 11)
        cancel.contentTintColor = .secondaryLabelColor
        showStrip(NSStackView(views: [spinner, stripLabel(info), cancel]), height: 30, autoHide: nil)
    }

    /// 结果条(上下文识别):一行文本 + 可选按钮,悬停不消失,4s 后隐藏
    func showResult(_ text: String, buttons: [(String, () -> Void)] = []) {
        var views: [NSView] = [stripLabel(text)]
        for (title, handler) in buttons {
            let b = ClosureButton(title: title, action: handler)
            b.isBordered = false
            b.font = .systemFont(ofSize: 11, weight: .medium)
            b.contentTintColor = .systemBlue
            views.append(b)
        }
        showStrip(NSStackView(views: views), height: 30, autoHide: 4.0)
    }

    private func stripLabel(_ s: String) -> NSTextField {
        let label = NSTextField(labelWithString: s)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    private func showStrip(_ content: NSStackView, height: CGFloat, autoHide: TimeInterval?) {
        guard let panel else { return }
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        let fit = content.fittingSize
        let size = CGSize(width: fit.width + 28, height: height)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        content.frame = NSRect(x: 14, y: (size.height - fit.height) / 2,
                               width: fit.width, height: fit.height)
        effect.addSubview(content)

        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.contentView = effect
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: center.x - size.width / 2,
                                     y: center.y - size.height / 2))
        panel.orderFront(nil)   // hide() 之后调 showInfo 时也要能重新显示
        if let autoHide {
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide) { [weak self] in
                self?.hide()
            }
        }
    }

    // MARK: - 供动作调用的辅助

    func speak(_ text: String) {
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
            return
        }
        let utt = AVSpeechUtterance(string: text)
        if text.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil {
            utt.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        speech.speak(utt)
    }

    func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
        hide()
    }

    func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    private func makeButton(_ action: BarAction) -> BarButton {
        let b = BarButton(image: NSImage(), target: self, action: #selector(runAction(_:)))
        b.actionIndex = actionIndex(of: action)
        let img: NSImage
        if let swatch = action.swatchColor {
            img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                swatch.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
                NSColor.secondaryLabelColor.setStroke()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).stroke()
                return true
            }
        } else {
            img = NSImage(systemSymbolName: action.symbol,
                          accessibilityDescription: action.title) ?? NSImage()
        }
        b.image = img
        b.accentColor = action.color
        b.contentTintColor = action.color
        b.isBordered = false
        b.toolTip = action.title
        b.imageScaling = NSImageScaling.scaleProportionallyDown
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    private func actionIndex(of action: BarAction) -> Int {
        visibleActions.firstIndex { $0.id == action.id } ?? -1
    }
}

/// 支持悬停高亮的图标按钮:
/// mouseEntered 时显示圆角淡色底(取按钮主题色) + 手型光标。
/// .activeAlways 很关键——App 是 accessory 且面板不抢焦点,普通 tracking 不会生效。
final class BarButton: NSButton {
    var accentColor: NSColor = .labelColor
    var actionIndex = -1
    var isHighlightedByKeyboard = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    convenience init(image: NSImage, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 6
        setButtonType(.momentaryPushIn)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = accentColor.withAlphaComponent(0.18).cgColor
        NSCursor.pointingHand.push()
        // 原生 toolTip 在非激活面板里不弹,自己画一个
        if let tip = toolTip { BarTooltip.shared.show(tip, above: self) }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = isHighlightedByKeyboard
            ? accentColor.withAlphaComponent(0.28).cgColor : .clear
        NSCursor.pop()
        BarTooltip.shared.hide()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlightedByKeyboard {
            accentColor.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
