import Cocoa

/// 贴图窗口:把截图悬浮在屏幕上
final class SnapPinWindow: NSPanel {
    private static var open: [SnapPinWindow] = []

    let image: CGImage
    let scale: CGFloat
    private let baseSize: CGSize
    private var zoom: CGFloat = 1
    private let label = NSTextField(labelWithString: "")
    private var fadeWork: DispatchWorkItem?

    /// frame 为 Cocoa 全局坐标
    static func show(image: CGImage, scale: CGFloat, frame: CGRect) {
        let w = SnapPinWindow(image: image, scale: scale, frame: frame)
        open.append(w)
        NSApp.activateForUI()
        w.makeKeyAndOrderFront(nil)
    }

    static func contains(_ cocoaPoint: CGPoint) -> Bool {
        open.contains { $0.frame.contains(cocoaPoint) }
    }

    private init(image: CGImage, scale: CGFloat, frame: CGRect) {
        self.image = image
        self.scale = scale
        baseSize = frame.size
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = SnapPinView(window: self)
        contentView = v
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        label.alphaValue = 0
        v.addSubview(label)
        makeFirstResponder(v)
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        Self.open.removeAll { $0 === self }
        super.close()
    }

    func zoom(by factor: CGFloat, at p: CGPoint) {
        let f = frame
        let newZoom = min(max(zoom * factor, 0.1), 5)
        guard newZoom != zoom else { return }
        zoom = newZoom
        let size = CGSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
        let fx = (p.x - f.minX) / f.width, fy = (p.y - f.minY) / f.height
        setFrame(CGRect(x: p.x - fx * size.width, y: p.y - fy * size.height,
                        width: size.width, height: size.height), display: true)
        showZoomLabel()
    }

    private func showZoomLabel() {
        label.stringValue = " \(Int((zoom * 100).rounded()))% "
        label.sizeToFit()
        label.setFrameOrigin(CGPoint(x: (frame.width - label.frame.width) / 2, y: frame.height - label.frame.height - 6))
        label.alphaValue = 1
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self?.label.animator().alphaValue = 0 }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

final class SnapPinView: NSView {
    private unowned let pin: SnapPinWindow

    init(window: SnapPinWindow) {
        pin = window
        super.init(frame: CGRect(origin: .zero, size: window.frame.size))
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(pin.image, in: bounds)
        NSColor(srgbRed: 0x1A / 255, green: 0xAD / 255, blue: 0x19 / 255, alpha: 1).setStroke()
        let b = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        b.lineWidth = 1
        b.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { pin.close() } else { super.mouseDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        let factor = event.hasPreciseScrollingDeltas ? 1 + max(min(dy * 0.005, 0.1), -0.1) : (dy > 0 ? 1.1 : 1 / 1.1)
        pin.zoom(by: factor, at: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { pin.close() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "c" else { return false }
        copyImage()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, to menu: NSMenu, tag: Int = 0) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.tag = tag
            menu.addItem(i)
        }
        add(L10n.t("复制", "Copy"), #selector(copyImage), to: m)
        add(L10n.t("保存", "Save"), #selector(saveImage), to: m)
        add(L10n.t("文字识别", "OCR"), #selector(ocrImage), to: m)
        let opacity = NSMenu()
        for pct in [100, 80, 60, 40] { add("\(pct)%", #selector(setOpacity(_:)), to: opacity, tag: pct) }
        let parent = NSMenuItem(title: L10n.t("透明度", "Opacity"), action: nil, keyEquivalent: "")
        parent.submenu = opacity
        m.addItem(parent)
        m.addItem(.separator())
        add(L10n.t("关闭", "Close"), #selector(closePin), to: m)
        return m
    }

    @objc private func copyImage() { SnapOutput.copy(pin.image, scale: pin.scale) }
    @objc private func saveImage() { SnapOutput.save(pin.image) }
    @objc private func ocrImage() { SnapOutput.ocr(pin.image) }
    @objc private func closePin() { pin.close() }
    @objc private func setOpacity(_ item: NSMenuItem) { pin.alphaValue = CGFloat(item.tag) / 100 }
}
