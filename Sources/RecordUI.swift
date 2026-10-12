import Cocoa

/// 录制区域红框:.nonactivatingPanel + 不接收鼠标。
/// 本进程窗口已被 SCContentFilter 排除,所以它不会出现在录制画面里。
final class RecordBorderWindow: NSPanel {
    private let borderView: RecordBorderView

    init(rect: CGRect) {
        borderView = RecordBorderView()
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
        contentView = borderView
    }

    override var canBecomeKey: Bool { false }

    func setPaused(_ on: Bool) { borderView.paused = on }

    /// 跟随窗口录制时,红框要跟着窗口走
    func move(to rect: CGRect) {
        setFrame(rect.insetBy(dx: -3, dy: -3), display: true)
    }
}

private final class RecordBorderView: NSView {
    var paused = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        (paused ? NSColor.systemOrange : NSColor.systemRed).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.stroke()
        if paused {
            // 暂停时整个边框铺一层淡橙色,让状态一眼可辨
            NSColor.systemOrange.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5)).fill()
        }
    }
}

/// 倒计时:在录制区上盖一层淡暗 + 大号倒数。
/// 本进程窗口已被 SCContentFilter 排除,倒计时画面不会进片子。
final class RecordCountdownPanel: NSPanel {
    private let numberLabel = NSTextField(labelWithString: "3")
    private let hintLabel = NSTextField(labelWithString: "")

    init(rect: CGRect, seconds: Int) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 96, weight: .bold)
        numberLabel.textColor = .white
        numberLabel.alignment = .center
        numberLabel.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.6)
            s.shadowBlurRadius = 12
            return s
        }()

        hintLabel.stringValue = L10n.t("Esc 或再按一次快捷键取消", "Esc or press the hotkey again to cancel")
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        hintLabel.alignment = .center

        let col = NSStackView(views: [numberLabel, hintLabel])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false

        let root = RecordCountdownView()
        root.addSubview(col)
        NSLayoutConstraint.activate([
            col.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            col.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        contentView = root
        _ = seconds
    }

    override var canBecomeKey: Bool { false }

    func setNumber(_ n: Int) { numberLabel.stringValue = "\(n)" }
}

private final class RecordCountdownView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.stroke()
    }
}

/// 录制控制面板:计时 + 暂停/标记/隐藏/停止。不抢键盘焦点,点击不改变前台 App
final class RecordPanel: NSPanel {
    private let selection: CGRect
    private let screenFrame: CGRect
    private let root = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "00:00")
    private let pauseButton: NSButton
    private let markerButton: NSButton
    private let width: CGFloat = 232

    init(selection: CGRect, screen: NSScreen,
         onPause: @escaping () -> Void,
         onMarker: @escaping () -> Void,
         onHide: @escaping () -> Void,
         onStop: @escaping () -> Void) {
        self.selection = selection
        screenFrame = screen.frame
        pauseButton = Self.makeButton(symbol: "pause.fill", tooltip: L10n.t("暂停", "Pause"), tint: .systemOrange)
        markerButton = Self.makeButton(symbol: "flag", tooltip: L10n.t("打标记点", "Add marker"), tint: .systemTeal)
        super.init(contentRect: CGRect(x: 0, y: 0, width: 232, height: 62),
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

        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor

        let dot = NSImageView(image: NSImage(systemSymbolName: "record.circle.fill",
                                             accessibilityDescription: nil) ?? NSImage())
        dot.contentTintColor = .systemRed

        let title = NSStackView(views: [dot, label])
        title.orientation = .horizontal
        title.spacing = 5
        title.alignment = .centerY

        let hide = Self.makeButton(symbol: "eye.slash", tooltip: L10n.t("隐藏面板", "Hide Panel"), tint: .secondaryLabelColor)
        let stop = Self.makeButton(symbol: "stop.fill", tooltip: L10n.t("停止录屏", "Stop Recording"), tint: .systemRed)
        pauseAction = onPause
        markerAction = onMarker
        hideAction = onHide
        stopAction = onStop
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        markerButton.target = self
        markerButton.action = #selector(markerTapped)
        hide.target = self
        hide.action = #selector(hideTapped)
        stop.target = self
        stop.action = #selector(stopTapped)

        let bar = NSStackView(views: [pauseButton, markerButton, hide, stop])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.distribution = .fillEqually

        let col = NSStackView(views: [title, bar])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 6
        col.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        root.addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            col.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            col.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            col.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            bar.widthAnchor.constraint(equalTo: col.widthAnchor),
        ])
        contentView = root
        root.autoresizingMask = [.width, .height]
        root.frame = CGRect(x: 0, y: 0, width: width, height: 62)
        relayout()
    }

    private var pauseAction: () -> Void = {}
    private var markerAction: () -> Void = {}
    private var hideAction: () -> Void = {}
    private var stopAction: () -> Void = {}
    private var isPaused = false
    private var markerCount = 0

    override var canBecomeKey: Bool { false }

    func update(duration: TimeInterval, paused: Bool) {
        label.stringValue = RecordUtil.durationText(duration)
        guard paused != isPaused else { return }
        isPaused = paused
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: nil)
        pauseButton.toolTip = paused ? L10n.t("继续", "Resume") : L10n.t("暂停", "Pause")
    }

    /// 标记点个数:按钮换成实心并显示计数
    func setMarkerCount(_ n: Int) {
        markerCount = n
        markerButton.image = NSImage(systemSymbolName: n > 0 ? "flag.fill" : "flag",
                                    accessibilityDescription: nil)
        markerButton.toolTip = n > 0
            ? L10n.t("已打 \(n) 个标记点", "\(n) marker(s)")
            : L10n.t("打标记点", "Add marker")
    }

    @objc private func pauseTapped() { pauseAction() }
    @objc private func markerTapped() { markerAction() }
    @objc private func hideTapped() { hideAction() }
    @objc private func stopTapped() { stopAction() }

    private static func makeButton(symbol: String, tooltip: String, tint: NSColor) -> NSButton {
        // BarButton 悬停时用 BarTooltip 自绘提示(非激活面板里原生 toolTip 不弹)
        let b = BarButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(),
                          target: nil, action: nil)
        b.accentColor = tint
        b.toolTip = tooltip
        b.contentTintColor = tint
        b.isBordered = false
        b.imageScaling = .scaleProportionallyDown
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    private func relayout() {
        let size = CGSize(width: width, height: 62)
        root.frame = CGRect(origin: .zero, size: size)
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
