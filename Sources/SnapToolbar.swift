import Cocoa

/// 工具条条目;阶段 C 的长截图按钮插在数组里 pin 之前即可
enum SnapToolbarItem {
    case button(id: String, symbol: String, tooltip: String, tint: NSColor, action: () -> Void)
    case separator
}

final class SnapToolbar: NSVisualEffectView {
    private var buttons: [String: BarButton] = [:]
    private var actions: [Int: () -> Void] = [:]

    init(items: [SnapToolbarItem]) {
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        var views: [NSView] = []
        var tag = 0
        for item in items {
            switch item {
            case let .button(id, symbol, tooltip, tint, action):
                let b = SnapBarButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
                        ?? NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: tooltip) ?? NSImage(),
                    target: self, action: #selector(dispatch(_:)))
                b.toolTip = tooltip
                b.contentTintColor = tint
                b.accentColor = tint
                b.imageScaling = .scaleProportionallyDown
                b.isBordered = false
                b.tag = tag
                b.widthAnchor.constraint(equalToConstant: 28).isActive = true
                b.heightAnchor.constraint(equalToConstant: 26).isActive = true
                buttons[id] = b
                actions[tag] = action
                tag += 1
                views.append(b)
            case .separator:
                let sep = NSBox()
                sep.boxType = .separator
                sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
                sep.heightAnchor.constraint(equalToConstant: 18).isActive = true
                views.append(sep)
            }
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.frame = CGRect(origin: .zero, size: stack.fittingSize)
        addSubview(stack)
        setFrameSize(stack.frame.size)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func dispatch(_ sender: NSButton) { actions[sender.tag]?() }

    func setSelected(_ id: String?) {
        for (k, b) in buttons { b.isHighlightedByKeyboard = k == id }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        buttons[id]?.isEnabled = on
        buttons[id]?.alphaValue = on ? 1 : 0.35
    }
}

/// 禁用时跳过悬停高亮与自绘提示
private final class SnapBarButton: BarButton {
    override func mouseEntered(with event: NSEvent) {
        if isEnabled { super.mouseEntered(with: event) }
    }
}

/// 样式条:3 档大小 + 6 色(马赛克不显示颜色)
final class SnapStyleBar: NSVisualEffectView {
    private var sizeViews: [SnapChoiceView] = []
    private var colorViews: [(hex: String, view: SnapChoiceView)] = []

    init(style: SnapStyle, showColors: Bool, onSize: @escaping (Int) -> Void, onColor: @escaping (NSColor) -> Void) {
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        var views: [NSView] = []
        for (i, d) in [6, 10, 14].enumerated() {
            let v = SnapChoiceView(kind: .dot(CGFloat(d))) { onSize(i) }
            sizeViews.append(v)
            views.append(v)
        }
        if showColors {
            let sep = NSBox()
            sep.boxType = .separator
            sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
            sep.heightAnchor.constraint(equalToConstant: 18).isActive = true
            views.append(sep)
            for hex in SnapStyle.palette {
                guard let c = SnapStyle.color(hex: hex) else { continue }
                let v = SnapChoiceView(kind: .swatch(c)) { onColor(c) }
                colorViews.append((hex, v))
                views.append(v)
            }
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.frame = CGRect(origin: .zero, size: stack.fittingSize)
        addSubview(stack)
        setFrameSize(stack.frame.size)
        refresh(style)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(_ style: SnapStyle) {
        for (i, v) in sizeViews.enumerated() { v.isChosen = i == min(max(style.tier, 0), 2) }
        for (hex, v) in colorViews { v.isChosen = hex == style.hex }
    }
}

final class SnapChoiceView: NSView {
    enum Kind { case dot(CGFloat), swatch(NSColor) }
    private let kind: Kind
    private let onClick: () -> Void
    var isChosen = false { didSet { needsDisplay = true } }

    init(kind: Kind, onClick: @escaping () -> Void) {
        self.kind = kind
        self.onClick = onClick
        super.init(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let d: CGFloat
        switch kind {
        case let .dot(size): d = size; NSColor.labelColor.setFill()
        case let .swatch(color): d = 14; color.setFill()
        }
        let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        NSBezierPath(ovalIn: r).fill()
        NSColor.separatorColor.setStroke()
        let edge = NSBezierPath(ovalIn: r)
        edge.lineWidth = 0.5
        edge.stroke()
        if isChosen {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}
