import Cocoa

/// 长截图时标出捕获区域的虚线框:不接收鼠标,滚轮穿透到下面的应用
final class SnapScrollBorderWindow: NSPanel {
    init(rect: CGRect) {
        super.init(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = SnapScrollBorderView()
    }
}

private final class SnapScrollBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0x1A / 255, green: 0xAD / 255, blue: 0x19 / 255, alpha: 1).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}

/// 长截图控制面板:拼接预览 + 状态 + 操作按钮;不抢键盘焦点
final class SnapScrollPanel: NSPanel {
    private let selection: CGRect
    private let screenFrame: CGRect
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let actionBar: SnapToolbar
    private let root = NSVisualEffectView()
    private let panelWidth: CGFloat = 190
    private var previewSize = CGSize.zero

    init(selection: CGRect, screen: NSScreen, onAction: @escaping (SnapAction?) -> Void) {
        self.selection = selection
        screenFrame = screen.frame
        actionBar = SnapToolbar(items: [
            .button(id: "done", symbol: "checkmark", tooltip: L10n.t("完成并复制", "Done (Copy)"),
                    tint: NSColor(srgbRed: 0x1A / 255, green: 0xAD / 255, blue: 0x19 / 255, alpha: 1),
                    action: { onAction(.copy) }),
            .button(id: "save", symbol: "square.and.arrow.down", tooltip: L10n.t("保存", "Save"), tint: .systemBlue,
                    action: { onAction(.save) }),
            .button(id: "ocr", symbol: "text.viewfinder", tooltip: L10n.t("文字识别", "OCR"), tint: .systemGreen,
                    action: { onAction(.ocr) }),
            .button(id: "cancel", symbol: "xmark", tooltip: L10n.t("取消", "Cancel"), tint: .systemRed,
                    action: { onAction(nil) }),
        ])
        super.init(contentRect: CGRect(x: 0, y: 0, width: 190, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        root.material = .popover
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignBottom
        [imageView, label, actionBar].forEach { root.addSubview($0) }
        contentView = root
        relayout()
    }

    override var canBecomeKey: Bool { false }

    func update(preview: CGImage?, scale: CGFloat, status: String) {
        label.stringValue = status
        if let p = preview {
            imageView.image = NSImage(cgImage: p, size: CGSize(width: CGFloat(p.width) / scale, height: CGFloat(p.height) / scale))
            let maxH = screenFrame.height - 80 - 90
            let s = min(160 / CGFloat(p.width), maxH / CGFloat(p.height), 1)
            previewSize = CGSize(width: max(CGFloat(p.width) * s, 1), height: max(CGFloat(p.height) * s, 1))
        }
        relayout()
    }

    private func relayout() {
        let pad: CGFloat = 8
        let tb = actionBar.frame.size
        let height = previewSize.height + (previewSize.height > 0 ? pad : 0) + 18 + pad + tb.height + pad * 2
        actionBar.setFrameOrigin(CGPoint(x: (panelWidth - tb.width) / 2, y: pad))
        label.frame = CGRect(x: pad, y: pad + tb.height + pad, width: panelWidth - pad * 2, height: 16)
        imageView.frame = CGRect(x: (panelWidth - previewSize.width) / 2, y: label.frame.maxY + pad,
                                 width: previewSize.width, height: previewSize.height)
        root.frame = CGRect(x: 0, y: 0, width: panelWidth, height: height)
        let size = CGSize(width: panelWidth, height: height)
        var x = selection.maxX + 10
        if x + size.width > screenFrame.maxX { x = selection.minX - 10 - size.width }
        var y = min(selection.maxY - size.height, screenFrame.maxY - 40 - size.height)
        y = max(y, screenFrame.minY + 10)
        if x < screenFrame.minX {
            x = max(selection.maxX - size.width - 8, screenFrame.minX)
            y = selection.minY + 8
        }
        setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
    }
}
