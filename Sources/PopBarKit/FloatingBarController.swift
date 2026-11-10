import Cocoa
import AVFoundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 浮动条：`[智能胶囊] │ 复制 翻译 搜索 朗读 待办 │ ···`
///
/// - 无边框非激活 NSPanel，颜色全部来自设计令牌，图标用 Lucide；
/// - 「···」在条下方展开 4 列「更多」面板，左对齐、宽度不小于浮动条；
/// - 定位走 ScreenPlacement：选区所在屏的 visibleFrame 内，优先在选区上方；
/// - 出现动画：120ms 淡入 + 上移 4pt。
final class FloatingBarController: NSObject {
    static let shared = FloatingBarController()

    static let barHeight: CGFloat = 38
    static let buttonSize = CGSize(width: 32, height: 30)

    private var panel: NSPanel?
    private var morePanel: NSPanel?
    private(set) var ctx = SourceContext(text: "")
    private var layout = BarLayout(capsule: nil, primary: [], more: [])
    /// 键盘模式下可聚焦的按钮：胶囊、常用、「···」
    private var focusables: [BarButton] = []
    private var speakButton: BarButton?
    private var moreButton: BarButton?
    private let speech = AVSpeechSynthesizer()
    private var hideWork: DispatchWorkItem?
    /// 朗读状态(显式标志:AVSpeechSynthesizer.isSpeaking 异步生效,刚 speak 完仍为 false)
    private(set) var isSpeaking = false
    /// 键盘模式:←/→ 移动高亮、Enter 执行
    private(set) var keyboardMode = false
    private var highlightIndex = -1

    var isVisible: Bool { panel?.isVisible ?? false }
    /// 浮动条与展开的「更多」面板合起来的范围(点在里面不算点击别处)
    var frame: CGRect {
        guard let p = panel else { return .zero }
        if let m = morePanel, m.isVisible { return p.frame.union(m.frame) }
        return p.frame
    }
    var windowID: Int { panel?.windowNumber ?? 0 }

    override init() {
        super.init()
        speech.delegate = self
    }

    /// 仅截图工具用:强制指定浅色/深色外观
    func setAppearance(_ name: NSAppearance.Name) {
        panel?.appearance = NSAppearance(named: name)
        morePanel?.appearance = NSAppearance(named: name)
    }

    // MARK: - Show / Hide

    func show(text: String, anchor: CGRect?) {
        show(ctx: SourceContext(text: text, origin: .other).applying { $0.bounds = anchor })
    }

    func show(ctx: SourceContext, keyboard: Bool = false) {
        stopSpeechSession()   // 新选区/新会话,上一段朗读作废
        hideWork?.cancel()
        closeMore()
        self.ctx = ctx
        keyboardMode = keyboard
        highlightIndex = -1
        if keyboard { KeyboardInterceptor.shared.install() } else { KeyboardInterceptor.shared.uninstall() }

        layout = MainActor.assumeIsolated { ActionRegistry.resolve(for: ctx) }
        guard !layout.all.isEmpty else { return }

        let content = buildBar()
        // 必须在赋 contentView 之前取尺寸:赋值时 AppKit 会把视图缩成窗口当前内容尺寸
        // (首次创建的面板是 .zero),之后再读就是 0×0,面板会以零尺寸"弹出"而看不见
        let size = content.frame.size
        let p = panel ?? makePanel()
        panel = p
        p.contentView = content
        let target = ScreenPlacement.frame(size: size, anchor: ctx.bounds, prefer: .above, gap: 8)
        present(p, at: target)
    }

    func hide() {
        hideWork?.cancel()
        keyboardMode = false
        KeyboardInterceptor.shared.uninstall()
        BarTooltip.shared.hide()
        stopSpeechSession()   // 浮动条是朗读的唯一取消入口,条收了朗读也停
        closeMore()
        panel?.orderOut(nil)
    }

    /// 环境性隐藏(点击别处/滚动/普通按键):朗读中保留浮动条作为停止入口
    func hideUnlessSpeaking() {
        guard !isSpeaking else { return }
        hide()
    }

    // MARK: - 构建

    /// 截图工具用:不显示窗口,只生成浮动条与「更多」面板的视图
    func makeViews(for ctx: SourceContext) -> (bar: NSView, more: NSView?) {
        self.ctx = ctx
        layout = MainActor.assumeIsolated { ActionRegistry.resolve(for: ctx) }
        let bar = buildBar()
        let more = layout.more.isEmpty ? nil : MoreGridView(actions: layout.more, minWidth: bar.frame.width) { _ in }
        return (bar, more)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }

    private func buildBar() -> NSView {
        focusables = []
        speakButton = nil
        var views: [NSView] = []

        if let cap = layout.capsule {
            let b = CapsuleButton(action: cap, target: self, selector: #selector(runFocusable(_:)))
            b.tag = 0
            focusables.append(b)
            views.append(b)
            if !layout.primary.isEmpty || !layout.more.isEmpty { views.append(Separator()) }
        }
        for a in layout.primary {
            let b = iconButton(icon: a.id == "builtin.speak" && isSpeaking ? "square" : a.icon, title: a.title, swatch: a.swatchColor)
            b.tag = focusables.count
            b.target = self
            b.action = #selector(runFocusable(_:))
            if a.id == "builtin.speak" { speakButton = b }
            focusables.append(b)
            views.append(b)
        }
        if !layout.more.isEmpty {
            if !layout.primary.isEmpty { views.append(Separator()) }
            let b = iconButton(icon: "ellipsis", title: L10n.t("更多", "More"), swatch: nil)
            b.tag = focusables.count
            b.target = self
            b.action = #selector(runFocusable(_:))
            moreButton = b
            focusables.append(b)
            views.append(b)
        } else {
            moreButton = nil
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        let fit = stack.fittingSize
        let size = CGSize(width: ceil(fit.width), height: Self.barHeight)
        let root = ThemedBox(frame: NSRect(origin: .zero, size: size), radius: Theme.Radius.panel)
        stack.frame = NSRect(x: 0, y: (size.height - fit.height) / 2, width: size.width, height: fit.height)
        root.addSubview(stack)
        return root
    }

    private func iconButton(icon: String, title: String, swatch: NSColor?) -> BarButton {
        let b = BarButton(frame: NSRect(origin: .zero, size: Self.buttonSize))
        if let swatch {
            b.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                swatch.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
                Theme.border.setStroke()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).stroke()
                return true
            }
        } else {
            b.image = Lucide.image(icon, size: 16)
            b.contentTintColor = Theme.text2
        }
        b.tooltipText = title
        b.setAccessibilityLabel(title)
        b.widthAnchor.constraint(equalToConstant: Self.buttonSize.width).isActive = true
        b.heightAnchor.constraint(equalToConstant: Self.buttonSize.height).isActive = true
        return b
    }

    /// 120ms 淡入 + 上移 4pt
    private func present(_ p: NSPanel, at target: CGRect) {
        let wasVisible = p.isVisible
        guard !wasVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            p.setFrame(target, display: true)
            p.alphaValue = 1
            p.orderFront(nil)
            return
        }
        p.setFrame(target.offsetBy(dx: 0, dy: -4), display: false)
        p.alphaValue = 0
        p.orderFront(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(target, display: true)
        }
    }

    // MARK: - 「更多」面板

    private func toggleMore() {
        if let m = morePanel, m.isVisible { closeMore() } else { openMore() }
    }

    private func openMore() {
        guard let bar = panel, !layout.more.isEmpty else { return }
        let grid = MoreGridView(actions: layout.more, minWidth: bar.frame.width) { [weak self] a in
            self?.perform(a, from: nil)
        }
        let size = grid.frame.size
        let m = morePanel ?? makePanel()
        morePanel = m
        m.appearance = bar.appearance
        m.contentView = grid
        // 左对齐浮动条，放在条下方；放不下时放到条上方
        let barFrame = bar.frame
        var origin = CGPoint(x: barFrame.minX, y: barFrame.minY - 6 - size.height)
        if let vf = ScreenPlacement.screen(containing: CGPoint(x: barFrame.midX, y: barFrame.midY))?.visibleFrame {
            if origin.y < vf.minY + 4 { origin.y = barFrame.maxY + 6 }
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        }
        m.setFrame(CGRect(origin: origin, size: size), display: true)
        m.alphaValue = 1
        m.orderFront(nil)
        moreButton?.isActiveState = true
    }

    private func closeMore() {
        morePanel?.orderOut(nil)
        moreButton?.isActiveState = false
    }

    // MARK: - 动作执行

    @objc private func runFocusable(_ sender: BarButton) {
        activate(index: sender.tag, from: sender)
    }

    private func activate(index: Int, from view: NSView?) {
        guard focusables.indices.contains(index) else { return }
        let b = focusables[index]
        if b === moreButton { toggleMore(); return }
        let offset = layout.capsule == nil ? 0 : 1
        if layout.capsule != nil && index == 0, let cap = layout.capsule { perform(cap, from: b); return }
        let i = index - offset
        guard layout.primary.indices.contains(i) else { return }
        perform(layout.primary[i], from: b)
    }

    private func perform(_ action: BarAction, from view: NSView?) {
        if let submenu = action.menu?(ctx) {
            closeMore()
            if let view {
                submenu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
            } else {
                submenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
            return
        }
        UsageStats.shared.record(action.id, bundleID: ctx.bundleID)
        if action.id != "builtin.speak" { closeMore() }
        action.perform(ctx)
    }

    // MARK: - 键盘模式

    /// ←/→ 移动高亮;返回是否已处理
    func moveHighlight(_ delta: Int) -> Bool {
        guard keyboardMode, !focusables.isEmpty else { return false }
        highlightIndex = (highlightIndex + delta + focusables.count) % focusables.count
        for (i, b) in focusables.enumerated() { b.isHighlightedByKeyboard = i == highlightIndex }
        return true
    }

    func performHighlighted() -> Bool {
        guard keyboardMode, focusables.indices.contains(highlightIndex) else { return false }
        activate(index: highlightIndex, from: focusables[highlightIndex])
        return true
    }

    // MARK: - 信息条 / 忙碌条 / 结果条

    /// 把浮动条临时换成一行文字(字数统计等),2 秒后自动隐藏
    func showInfo(_ info: String) {
        showStrip([stripLabel(info)], autoHide: 2.0)
    }

    /// 忙碌状态(AI 动作 replace 模式):转圈 + 文字 + 取消
    func showBusy(_ info: String, onCancel: @escaping () -> Void) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
        showStrip([spinner, stripLabel(info), stripButton(L10n.t("取消", "Cancel"), onCancel)], autoHide: nil)
    }

    /// 结果条:一行文本 + 可选按钮,4 秒后隐藏
    func showResult(_ text: String, buttons: [(String, () -> Void)] = []) {
        showStrip([stripLabel(text)] + buttons.map { stripButton($0.0, $0.1) }, autoHide: 4.0)
    }

    private func stripLabel(_ s: String) -> NSTextField {
        let label = NSTextField(labelWithString: s)
        label.font = .systemFont(ofSize: Theme.FontSize.body, weight: .medium)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func stripButton(_ title: String, _ handler: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: handler)
        b.isBordered = false
        b.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .semibold)
        b.contentTintColor = Theme.accent
        return b
    }

    private func showStrip(_ views: [NSView], autoHide: TimeInterval?) {
        closeMore()
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        var fit = stack.fittingSize
        fit.width = min(fit.width, 460)
        let size = CGSize(width: ceil(fit.width) + 28, height: Self.barHeight)
        let root = ThemedBox(frame: NSRect(origin: .zero, size: size), radius: Theme.Radius.panel)
        stack.frame = NSRect(x: 14, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height)
        root.addSubview(stack)

        let p = panel ?? makePanel()
        panel = p
        // 保持中心不动;条从未出现过时按鼠标位置定位
        let target: CGRect
        if p.isVisible {
            let c = CGPoint(x: p.frame.midX, y: p.frame.midY)
            var r = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
            if let vf = ScreenPlacement.screen(containing: c)?.visibleFrame {
                r.origin.x = min(max(r.origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            }
            target = r
        } else {
            target = ScreenPlacement.frame(size: size, anchor: ctx.bounds, prefer: .above, gap: 8)
        }
        p.contentView = root
        present(p, at: target)
        hideWork?.cancel()
        if let autoHide {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: w)
        }
    }

    // MARK: - 供动作调用的辅助

    func speak(_ text: String) {
        if isSpeaking || speech.isSpeaking {
            stopSpeechSession()
            return
        }
        let utt = AVSpeechUtterance(string: text)
        SpeakVoice.apply(utt, fallbackLanguage: LanguageDetect.voiceLanguage(text))
        isSpeaking = true
        setSpeakIcon(true)
        speech.speak(utt)
    }

    private func stopSpeechSession() {
        guard isSpeaking else { return }
        isSpeaking = false
        speech.stopSpeaking(at: .immediate)
    }

    private func speechEnded() {
        isSpeaking = false
        setSpeakIcon(false)
    }

    /// 朗读中把按钮图标换成停止,给用户明确的「再点一次停止」提示
    private func setSpeakIcon(_ speaking: Bool) {
        guard let b = speakButton else { return }
        b.image = Lucide.image(speaking ? "square" : "volume-2", size: 16)
        b.tooltipText = speaking ? L10n.t("停止朗读", "Stop Speaking") : L10n.t("朗读", "Speak")
    }

    func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
        hide()
    }

    func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

// MARK: - 视图

/// 浮动类窗口的外壳：surface 底 + 1px 描边 + 圆角；颜色随外观切换重新解析
class ThemedBox: NSView {
    private let radius: CGFloat
    var fill: NSColor = Theme.surface { didSet { needsDisplay = true } }

    init(frame: NSRect, radius: CGFloat) {
        self.radius = radius
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.resolve(fill, in: effectiveAppearance)
        layer?.borderColor = Theme.resolve(Theme.border, in: effectiveAppearance)
        layer?.borderWidth = 1
    }
}

/// 竖分隔线
private final class Separator: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 9, height: 18))
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 9).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let line = CALayer()
        line.frame = CGRect(x: 4, y: 0, width: 1, height: 18)
        line.backgroundColor = Theme.resolve(Theme.border, in: effectiveAppearance)
        layer?.addSublayer(line)
    }
}

/// 浮动条图标按钮：悬停 hover 底、按下 active 底、键盘高亮 accentSoft 底。
/// .activeAlways 很关键——App 是 accessory 且面板不抢焦点,普通 tracking 不会生效。
class BarButton: NSButton {
    var tooltipText: String?
    private var hovering = false { didSet { needsDisplay = true } }
    var isHighlightedByKeyboard = false { didSet { needsDisplay = true } }
    /// 「···」展开时保持按下态
    var isActiveState = false { didSet { needsDisplay = true } }
    /// 截屏 / 录屏工具条沿用的主题色(只影响图标着色,悬停底统一用 hover 令牌)
    var accentColor: NSColor?

    convenience init(image: NSImage, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        imageScaling = .scaleProportionallyDown
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        wantsLayer = true
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        // 原生 toolTip 在非激活面板里不弹,自己画一个
        if let tip = tooltipText ?? toolTip { BarTooltip.shared.show(tip, above: self) }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        BarTooltip.shared.hide()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor? = isHighlightedByKeyboard ? Theme.accentSoft
            : (isHighlighted || isActiveState) ? Theme.active
            : hovering ? Theme.hover : nil
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Theme.Radius.button, yRadius: Theme.Radius.button).fill()
        }
        super.draw(dirtyRect)
    }
}

/// 智能胶囊：识别结果的一键操作，accentSoft 底 + 图标 + 简短说明
final class CapsuleButton: BarButton {
    init(action: BarAction, target: AnyObject, selector: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = selector
        let text = action.title.count > 22 ? String(action.title.prefix(21)) + "…" : action.title
        title = text
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.FontSize.caption, weight: .semibold),
            .foregroundColor: Theme.accent,
        ])
        if let swatch = action.swatchColor {
            image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                swatch.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
                return true
            }
        } else {
            image = Lucide.image(action.icon, size: 14)
        }
        contentTintColor = Theme.accent
        imagePosition = .imageLeading
        imageHugsTitle = true
        tooltipText = action.title
        setAccessibilityLabel(action.title)
        let w = min(ceil(attributedTitle.size().width) + 40, 200)
        widthAnchor.constraint(equalToConstant: w).isActive = true
        heightAnchor.constraint(equalToConstant: FloatingBarController.buttonSize.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: Theme.Radius.button, yRadius: Theme.Radius.button)
        Theme.accentSoft.setFill()
        path.fill()
        if isHighlightedByKeyboard || isHighlighted {
            Theme.accent.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        // 背景已自绘，跳过 BarButton 的 hover 底
        let cell = self.cell as? NSButtonCell
        cell?.drawInterior(withFrame: bounds, in: self)
    }
}

/// 「更多」面板：4 列网格，每格图标 + 名称；宽度不小于浮动条
final class MoreGridView: ThemedBox {
    static let columns = 4
    static let cell = CGSize(width: 76, height: 56)
    static let padding: CGFloat = 8

    private let actions: [BarAction]
    private let onPick: (BarAction) -> Void

    /// 网格尺寸：列数固定 4，列宽在浮动条更宽时均分拉伸
    static func size(count: Int, minWidth: CGFloat) -> (size: CGSize, cellWidth: CGFloat) {
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let natural = CGFloat(columns) * cell.width + padding * 2
        let width = max(natural, minWidth)
        let cellW = (width - padding * 2) / CGFloat(columns)
        return (CGSize(width: ceil(width), height: CGFloat(rows) * cell.height + padding * 2), cellW)
    }

    init(actions: [BarAction], minWidth: CGFloat, onPick: @escaping (BarAction) -> Void) {
        self.actions = actions
        self.onPick = onPick
        let (size, cellW) = Self.size(count: actions.count, minWidth: minWidth)
        super.init(frame: NSRect(origin: .zero, size: size), radius: Theme.Radius.panel)
        for (i, a) in actions.enumerated() {
            let row = i / Self.columns, col = i % Self.columns
            let b = MoreCell(action: a)
            b.tag = i
            b.target = self
            b.action = #selector(pick(_:))
            b.frame = NSRect(x: Self.padding + CGFloat(col) * cellW,
                             y: size.height - Self.padding - CGFloat(row + 1) * Self.cell.height,
                             width: cellW, height: Self.cell.height)
            addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pick(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        onPick(actions[sender.tag])
    }
}

private final class MoreCell: BarButton {
    init(action: BarAction) {
        super.init(frame: .zero)
        let label = action.title.count > 8 ? String(action.title.prefix(7)) + "…" : action.title
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.FontSize.small),
            .foregroundColor: Theme.text2,
        ])
        if let swatch = action.swatchColor {
            image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                swatch.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
                return true
            }
        } else {
            image = Lucide.image(action.icon, size: 18)
        }
        contentTintColor = Theme.text2
        imagePosition = .imageAbove
        tooltipText = action.title
        setAccessibilityLabel(action.title)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 朗读状态回调

extension FloatingBarController: AVSpeechSynthesizerDelegate {
    /// delegate 回调不保证在主线程,统一转一手再动 UI
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speechEnded() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speechEnded() }
    }
}

/// 朗读声音/语速的统一取值:优先用设置里选的声音,未设置或已卸载时回落调用方的自动逻辑
enum SpeakVoice {
    static func configured() -> AVSpeechSynthesisVoice? {
        let id = ConfigStore.shared.config.speak.voice
        guard !id.isEmpty else { return nil }
        return AVSpeechSynthesisVoice(identifier: id)
    }

    static func apply(_ utterance: AVSpeechUtterance, fallbackLanguage: String?) {
        if let v = configured() {
            utterance.voice = v
        } else if let lang = fallbackLanguage {
            utterance.voice = AVSpeechSynthesisVoice(language: lang)
        }
        let r = ConfigStore.shared.config.speak.rate
        if r != 1.0 {
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(r)
        }
    }
}
