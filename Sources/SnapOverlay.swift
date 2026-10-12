import Cocoa

final class SnapOverlayWindow: NSPanel {
    let overlayView: SnapOverlayView

    init(shot: SnapDisplayShot, windowRects: [CGRect]) {
        overlayView = SnapOverlayView(shot: shot, windowRects: windowRects)
        super.init(contentRect: shot.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        setFrame(shot.screen.frame, display: false)
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SnapTextView: NSTextView {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch ch {
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": paste(nil)
        case "a": selectAll(nil)
        case "z": if mods.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        default: return false
        }
        return true
    }
}

final class SnapOverlayView: NSView, NSTextViewDelegate {
    let shot: SnapDisplayShot
    private let windowRects: [CGRect]          // 本屏局部坐标,前→后
    private(set) var selection: CGRect?
    private var hoverRect: CGRect?
    private var mouse = CGPoint.zero
    private var mouseInside = false

    private enum Drag { case none, new(CGPoint), move(CGPoint), resize(SnapHandle, CGRect), draw(SnapTool, CGPoint) }
    private var drag = Drag.none
    private var didDrag = false
    private var colorCopied = false
    private var toolbar: SnapToolbar?
    private var styleBar: SnapStyleBar?

    private var currentTool: SnapTool?
    private var annotations = SnapUndoStack<SnapAnnotation>()
    private var inProgress: SnapAnnotation?
    private var strokePoints: [CGPoint] = []
    private var style: SnapStyle
    private var textView: SnapTextView?
    private var textOrigin = CGPoint.zero
    private lazy var mosaicImage: CGImage? = SnapMosaic.make(shot.image, scale: shot.scale)

    private static let accent = NSColor(srgbRed: 0x1A / 255, green: 0xAD / 255, blue: 0x19 / 255, alpha: 1)
    private static let handleSize: CGFloat = 7

    init(shot: SnapDisplayShot, windowRects: [CGRect]) {
        self.shot = shot
        let cfg = ConfigStore.shared.config.snap
        let tier = Int(cfg.lastWidth)
        style = SnapStyle(color: SnapStyle.color(hex: cfg.lastColor) ?? .systemRed,
                          tier: (0...2).contains(tier) ? tier : 1)
        let origin = shot.screen.frame.origin
        let local = CGRect(origin: .zero, size: shot.screen.frame.size)
        self.windowRects = windowRects.compactMap {
            let r = $0.offsetBy(dx: -origin.x, dy: -origin.y).intersection(local)
            return r.isNull || r.isEmpty ? nil : r
        }
        super.init(frame: local)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isIdleSelected: Bool {
        if case .none = drag { return selection != nil }
        return false
    }

    private var isLocked: Bool { currentTool != nil || !annotations.items.isEmpty }

    var annotationItems: [SnapAnnotation] { annotations.items }
    var exportMosaic: CGImage? { annotations.items.contains { $0.isMosaic } ? mosaicImage : nil }

    private var liveMosaic: CGImage? {
        currentTool == .mosaic || annotations.items.contains { $0.isMosaic } ? mosaicImage : nil
    }

    /// 窗口显示前先算好悬停状态,避免首帧先画全屏变暗
    func prepare() {
        if let w = window {
            mouse = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            mouseInside = bounds.contains(mouse)
        }
        updateHover()
    }

    func didShow() {
        window?.makeFirstResponder(self)
    }

    func clear() {
        removeTextView()
        currentTool = nil
        annotations = SnapUndoStack()
        inProgress = nil
        selection = nil
        hoverRect = nil
        mouseInside = false
        drag = .none
        hideToolbar()
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(shot.image, in: bounds)

        let hole = selection ?? hoverRect
        let dim = NSBezierPath(rect: bounds)
        if let hole { dim.append(NSBezierPath(rect: hole)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()

        if let sel = selection, !(annotations.items.isEmpty && inProgress == nil) {
            ctx.saveGState()
            ctx.clip(to: sel)
            let mosaic = liveMosaic
            for a in annotations.items { a.draw(in: ctx, mosaicImage: mosaic, imageBounds: bounds) }
            inProgress?.draw(in: ctx, mosaicImage: mosaic, imageBounds: bounds)
            ctx.restoreGState()
        }

        if let hole {
            Self.accent.setStroke()
            let border = NSBezierPath(rect: hole)
            border.lineWidth = 2
            border.stroke()
        }
        if let sel = selection {
            if !isLocked { drawHandles(sel) }
            drawSizeLabel(sel)
        } else if let h = hoverRect {
            drawSizeLabel(h)
        }
        if showsMagnifier {
            let s = SnapMagnifier.sample(shot.image, scale: shot.scale, viewHeight: bounds.height, at: mouse)
            SnapMagnifier.draw(s, mouse: mouse, bounds: bounds, copied: colorCopied)
        }
    }

    private var showsMagnifier: Bool {
        guard ConfigStore.shared.config.snap.showMagnifier, mouseInside else { return false }
        switch drag {
        case .none: return selection == nil
        case .new, .resize: return true
        case .move, .draw: return false
        }
    }

    private func drawHandles(_ r: CGRect) {
        let s = Self.handleSize
        for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let h = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            NSColor.white.setFill()
            h.fill()
            Self.accent.setStroke()
            let b = NSBezierPath(rect: h)
            b.lineWidth = 1
            b.stroke()
        }
    }

    private func drawSizeLabel(_ r: CGRect) {
        let text = "\(Int((r.width * shot.scale).rounded())) × \(Int((r.height * shot.scale).rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let box = CGSize(width: size.width + 12, height: size.height + 4)
        var y = r.maxY + 6
        if y + box.height > bounds.maxY { y = r.maxY - box.height - 6 }
        let rect = CGRect(x: min(max(r.minX, 0), bounds.maxX - box.width), y: y, width: box.width, height: box.height)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 2), withAttributes: attrs)
    }

    // MARK: - 鼠标

    private func updateHover() {
        hoverRect = selection == nil && mouseInside
            ? SnapGeometry.windowAt(mouse, windows: windowRects) : nil
    }

    private func updateCursor() {
        guard mouseInside else { return }
        if let sel = selection {
            switch drag {
            case .move: NSCursor.closedHand.set(); return
            case let .resize(h, _): Self.cursor(for: h).set(); return
            default: break
            }
            if let t = toolbar, t.frame.contains(mouse) { NSCursor.arrow.set(); return }
            if let b = styleBar, b.frame.contains(mouse) { NSCursor.arrow.set(); return }
            if let tool = currentTool {
                if sel.contains(mouse) { (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set() }
                else { NSCursor.arrow.set() }
                return
            }
            if isLocked { NSCursor.arrow.set(); return }
            if let h = SnapGeometry.hitHandle(mouse, rect: sel) { Self.cursor(for: h).set() }
            else { NSCursor.arrow.set() }
        } else {
            NSCursor.crosshair.set()
        }
    }

    private static func cursor(for h: SnapHandle) -> NSCursor {
        switch h {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight, .topRight, .bottomLeft: return .crosshair
        case .inside: return .openHand
        }
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        mouseInside = true
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        updateHover()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        mouseInside = bounds.contains(mouse)
        updateHover()
        updateCursor()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        mouse = convert(event.locationInWindow, from: nil)
        didDrag = false
        if let tool = currentTool, let sel = selection {
            commitText()
            if sel.contains(mouse) { beginAnnotation(tool, at: clamp(mouse, to: sel), in: sel) }
            return
        }
        if let sel = selection {
            if isLocked {
                if sel.contains(mouse), event.clickCount >= 2 {
                    SnapController.shared.complete(from: self, action: .copy)
                }
                return
            }
            guard let h = SnapGeometry.hitHandle(mouse, rect: sel) else { return }
            if h == .inside {
                if event.clickCount >= 2 { SnapController.shared.complete(from: self, action: .copy); return }
                drag = .move(mouse)
            } else {
                drag = .resize(h, sel)
            }
            hideToolbar()
        } else {
            SnapController.shared.claim(self)
            drag = .new(mouse)
        }
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        switch drag {
        case let .new(anchor):
            if !didDrag, hypot(mouse.x - anchor.x, mouse.y - anchor.y) > 3 { didDrag = true }
            if didDrag { selection = SnapGeometry.rectFrom(anchor, mouse, bounds: bounds) }
        case let .move(last):
            if let sel = selection {
                selection = SnapGeometry.move(sel, by: CGVector(dx: mouse.x - last.x, dy: mouse.y - last.y), bounds: bounds)
            }
            drag = .move(mouse)
        case let .resize(h, base):
            selection = SnapGeometry.resize(base, handle: h, to: mouse, bounds: bounds)
        case let .draw(tool, start):
            guard let sel = selection else { return }
            updateAnnotation(tool, start: start, to: clamp(mouse, to: sel), shift: event.modifierFlags.contains(.shift))
        case .none:
            return
        }
        hoverRect = nil
        updateCursor()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if case .new = drag {
            if !didDrag { selection = hoverRect ?? bounds }
        }
        if case .none = drag { return }
        if case let .draw(tool, _) = drag {
            finishAnnotation(tool)
            drag = .none
            refreshToolbarState()
            needsDisplay = true
            return
        }
        drag = .none
        if let s = selection, s.width < 1 || s.height < 1 { selection = nil }
        hoverRect = nil
        updateHover()
        showToolbar()
        updateCursor()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if currentTool != nil {
            selectTool(nil)
            return
        }
        if !annotations.items.isEmpty { return }
        if selection != nil {
            selection = nil
            drag = .none
            hideToolbar()
            mouse = convert(event.locationInWindow, from: nil)
            updateHover()
            updateCursor()
            needsDisplay = true
        } else {
            SnapController.shared.cancel()
        }
    }

    // MARK: - 键盘

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textView != nil { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch ch {
        case "c" where mods == .command: target().commit(.copy)
        case "s" where mods == .command: target().commit(.save)
        case "z" where mods == .command: target().undo()
        case "z" where mods == [.command, .shift]: target().redo()
        default: return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: SnapController.shared.cancel()
        case 36, 76: target().commit(.copy)
        case 123, 124, 125, 126:
            let step: CGFloat = mods.contains(.shift) ? 10 : 1
            let d: CGVector
            switch event.keyCode {
            case 123: d = CGVector(dx: -step, dy: 0)
            case 124: d = CGVector(dx: step, dy: 0)
            case 125: d = CGVector(dx: 0, dy: -step)
            default:  d = CGVector(dx: 0, dy: step)
            }
            target().nudge(d)
        case 8 where mods.isEmpty: copyColor()
        default: super.keyDown(with: event)
        }
    }

    private func target() -> SnapOverlayView { SnapController.shared.selectionView ?? self }

    private func commit(_ action: SnapAction) {
        guard selection != nil else { return }
        SnapController.shared.complete(from: self, action: action)
    }

    private func nudge(_ d: CGVector) {
        guard isIdleSelected, !isLocked, let sel = selection else { return }
        selection = SnapGeometry.move(sel, by: d, bounds: bounds)
        layoutToolbar()
        needsDisplay = true
    }

    private func copyColor() {
        guard mouseInside else { return }
        let s = SnapMagnifier.sample(shot.image, scale: shot.scale, viewHeight: bounds.height, at: mouse)
        PasteboardGuard.write(s.hex)
        colorCopied = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.colorCopied = false
            self?.needsDisplay = true
        }
    }

    // MARK: - 工具条

    private func toolbarItems() -> [SnapToolbarItem] {
        let c = SnapController.shared
        func act(_ a: SnapAction) -> () -> Void { { [weak self] in self.map { c.complete(from: $0, action: a) } } }
        let toolInfo: [SnapTool: (String, String, NSColor)] = [
            .rect: ("rectangle", L10n.t("矩形", "Rectangle"), .systemBlue),
            .ellipse: ("circle", L10n.t("椭圆", "Ellipse"), .systemIndigo),
            .arrow: ("arrow.up.right", L10n.t("箭头", "Arrow"), .systemOrange),
            .pen: ("scribble", L10n.t("画笔", "Pen"), .systemPurple),
            .text: ("textformat", L10n.t("文字", "Text"), .systemTeal),
            .mosaic: ("checkerboard.rectangle", L10n.t("马赛克", "Mosaic"), .systemBrown),
            .number: ("1.circle", L10n.t("序号", "Number"), .systemPink),
        ]
        var items: [SnapToolbarItem] = SnapTool.allCases.map { tool in
            let (symbol, tip, tint) = toolInfo[tool]!
            return .button(id: tool.id, symbol: symbol, tooltip: tip, tint: tint,
                           action: { [weak self] in
                               guard let self else { return }
                               self.selectTool(self.currentTool == tool ? nil : tool)
                           })
        }
        items += [
            .separator,
            .button(id: "undo", symbol: "arrow.uturn.backward", tooltip: L10n.t("撤销", "Undo"), tint: .secondaryLabelColor,
                    action: { [weak self] in self?.undo() }),
            .button(id: "redo", symbol: "arrow.uturn.forward", tooltip: L10n.t("重做", "Redo"), tint: .secondaryLabelColor,
                    action: { [weak self] in self?.redo() }),
            .separator,
            .button(id: "scroll", symbol: "arrow.up.and.down.text.horizontal",
                    tooltip: L10n.t("长截图", "Scrolling Capture"), tint: .systemCyan,
                    action: { [weak self] in self.map { c.beginScroll(from: $0) } }),
            .button(id: "pin", symbol: "pin", tooltip: L10n.t("贴图", "Pin"), tint: .systemMint, action: act(.pin)),
            .button(id: "ocr", symbol: "text.viewfinder", tooltip: L10n.t("文字识别", "OCR"), tint: .systemGreen, action: act(.ocr)),
            .button(id: "save", symbol: "square.and.arrow.down", tooltip: L10n.t("保存", "Save"), tint: .systemBlue, action: act(.save)),
            .separator,
            .button(id: "cancel", symbol: "xmark", tooltip: L10n.t("取消", "Cancel"), tint: .systemRed,
                    action: { c.cancel() }),
            .button(id: "done", symbol: "checkmark", tooltip: L10n.t("完成并复制", "Done (Copy)"), tint: Self.accent,
                    action: act(.copy)),
        ]
        return items
    }

    private func showToolbar() {
        guard selection != nil else { return hideToolbar() }
        if toolbar == nil {
            let t = SnapToolbar(items: toolbarItems())
            addSubview(t)
            toolbar = t
            refreshToolbarState()
        }
        layoutToolbar()
    }

    private func hideToolbar() {
        BarTooltip.shared.hide()
        toolbar?.removeFromSuperview()
        toolbar = nil
        styleBar?.removeFromSuperview()
        styleBar = nil
    }

    private func layoutToolbar() {
        guard let t = toolbar, let sel = selection else { return }
        let size = t.frame.size
        let gap: CGFloat = 8
        var x = min(max(sel.maxX - size.width, 0), bounds.maxX - size.width)
        var y = sel.minY - gap - size.height
        if y < bounds.minY {
            y = sel.maxY + gap
            if y + size.height > bounds.maxY {
                x = max(sel.maxX - size.width - gap, 0)
                y = sel.minY + gap
            }
        }
        t.setFrameOrigin(CGPoint(x: x, y: y))
        guard let bar = styleBar else { return }
        let bs = bar.frame.size
        var by = t.frame.minY < sel.minY ? t.frame.minY - 6 - bs.height : t.frame.maxY + 6
        by = min(max(by, 0), bounds.maxY - bs.height)
        bar.setFrameOrigin(CGPoint(x: min(max(t.frame.maxX - bs.width, 0), bounds.maxX - bs.width), y: by))
    }

    private func refreshToolbarState() {
        toolbar?.setSelected(currentTool?.id)
        toolbar?.setEnabled("undo", annotations.canUndo)
        toolbar?.setEnabled("redo", annotations.canRedo)
        toolbar?.setEnabled("scroll", currentTool == nil && annotations.items.isEmpty)
    }

    private func undo() {
        commitText()
        annotations.undo()
        annotationsChanged()
    }

    private func redo() {
        commitText()
        annotations.redo()
        annotationsChanged()
    }

    private func annotationsChanged() {
        refreshToolbarState()
        updateCursor()
        needsDisplay = true
    }

    private func selectTool(_ tool: SnapTool?) {
        commitText()
        currentTool = tool
        styleBar?.removeFromSuperview()
        styleBar = nil
        if let tool, toolbar != nil {
            let bar = SnapStyleBar(style: style, showColors: tool != .mosaic,
                                   onSize: { [weak self] in self?.setStyle(tier: $0) },
                                   onColor: { [weak self] in self?.setStyle(color: $0) })
            addSubview(bar)
            styleBar = bar
        }
        refreshToolbarState()
        layoutToolbar()
        updateCursor()
        needsDisplay = true
    }

    private func setStyle(tier: Int? = nil, color: NSColor? = nil) {
        if let tier { style.tier = tier }
        if let color { style.color = color }
        styleBar?.refresh(style)
        if let tv = textView {
            tv.font = NSFont.systemFont(ofSize: style.fontSize, weight: .medium)
            tv.textColor = style.color
            tv.insertionPointColor = style.color
            resizeTextView()
        }
        var c = ConfigStore.shared.config
        c.snap.lastColor = style.hex
        c.snap.lastWidth = Double(style.tier)
        try? ConfigStore.shared.save(c)
    }

    // MARK: - 标注

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private func beginAnnotation(_ tool: SnapTool, at p: CGPoint, in sel: CGRect) {
        switch tool {
        case .number:
            let n = annotations.items.filter { $0.isNumber }.count + 1
            annotations.push(.number(n, p, style))
            refreshToolbarState()
            needsDisplay = true
        case .text:
            beginText(at: p)
        case .pen, .mosaic:
            strokePoints = [p]
            inProgress = tool == .pen ? .pen(strokePoints, style) : .mosaic(strokePoints, style)
            drag = .draw(tool, p)
            needsDisplay = true
        case .rect, .ellipse, .arrow:
            drag = .draw(tool, p)
        }
    }

    private func updateAnnotation(_ tool: SnapTool, start: CGPoint, to p: CGPoint, shift: Bool) {
        if !didDrag, hypot(p.x - start.x, p.y - start.y) > 3 { didDrag = true }
        switch tool {
        case .rect, .ellipse:
            guard didDrag else { return }
            let end = shift ? clamp(SnapGeometry.constrainSquare(from: start, to: p), to: selection ?? bounds) : p
            let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            inProgress = tool == .rect ? .rect(r, style) : .ellipse(r, style)
        case .arrow:
            guard didDrag else { return }
            inProgress = .arrow(start, shift ? clamp(SnapGeometry.snapAngle(from: start, to: p), to: selection ?? bounds) : p, style)
        case .pen:
            strokePoints.append(p)
            inProgress = .pen(strokePoints, style)
        case .mosaic:
            strokePoints.append(p)
            inProgress = .mosaic(strokePoints, style)
        case .text, .number:
            break
        }
        needsDisplay = true
    }

    private func finishAnnotation(_ tool: SnapTool) {
        defer { inProgress = nil; strokePoints = [] }
        guard let a = inProgress else { return }
        switch tool {
        case .rect, .ellipse, .arrow: if didDrag { annotations.push(a) }
        default: annotations.push(a)
        }
    }

    // MARK: - 文字

    private func beginText(at p: CGPoint) {
        let tv = SnapTextView(frame: .zero)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 100000, height: 100000)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.font = NSFont.systemFont(ofSize: style.fontSize, weight: .medium)
        tv.textColor = style.color
        tv.insertionPointColor = style.color
        tv.delegate = self
        tv.onEscape = { [weak self] in self?.commitText() }
        textOrigin = p
        addSubview(tv)
        textView = tv
        resizeTextView()
        window?.makeFirstResponder(tv)
    }

    func textDidChange(_ notification: Notification) { resizeTextView() }

    private func resizeTextView() {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let lineHeight = NSString("A").size(withAttributes: [.font: tv.font ?? NSFont.systemFont(ofSize: 14)]).height
        let w = max(used.width + 4, 20), h = max(used.height, lineHeight)
        tv.frame = CGRect(x: textOrigin.x, y: textOrigin.y - h, width: w, height: h)
    }

    func commitText() {
        guard let tv = textView else { return }
        let str = tv.string
        let textStyle = style
        if !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.push(.text(str, textOrigin, textStyle))
        }
        removeTextView()
        refreshToolbarState()
        needsDisplay = true
    }

    private func removeTextView() {
        guard let tv = textView else { return }
        textView = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)
    }
}
