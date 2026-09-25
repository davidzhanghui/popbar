import Cocoa

/// 工具条按钮的悬停提示。
/// 系统自带的 `NSButton.toolTip` 在 `.nonactivatingPanel`(不抢焦点)的窗口里不会弹出,
/// 所以这里用一个不接收鼠标事件的浮动小窗自绘提示;跟随系统明暗与圆角风格。
final class BarTooltip {
    static let shared = BarTooltip()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    private init() {}

    /// 在 anchor(某个按钮)上方显示提示;同一 anchor 重复调用只更新文字
    func show(_ text: String, above anchor: NSView) {
        guard !text.isEmpty, let win = anchor.window else { return }
        hideWork?.cancel()

        let p = panel ?? makePanel()
        let field = label!
        field.stringValue = text
        field.sizeToFit()

        let padding: CGFloat = 8
        let size = NSSize(width: field.frame.width + padding * 2,
                          height: field.frame.height + 7)
        field.frame = NSRect(x: padding, y: 3.5, width: field.frame.width, height: field.frame.height)

        // 按钮在屏幕上的位置:面板上方居中;超出屏幕就落到下方
        let buttonRect = win.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var origin = NSPoint(x: buttonRect.midX - size.width / 2, y: buttonRect.maxY + 6)
        let screen = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if origin.y + size.height > screen.maxY { origin.y = buttonRect.minY - size.height - 6 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)

        p.setContentSize(size)
        p.setFrameOrigin(origin)
        p.orderFront(nil)
        panel = p
    }

    /// 鼠标离开按钮/工具条隐藏时调用
    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    /// 延迟显示:悬停 0.35s 才弹,避免扫过一排按钮时闪一堆提示
    func show(_ text: String, above anchor: NSView, after delay: TimeInterval = 0.35) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor, anchor.window != nil else { return }
            self.show(text, above: anchor)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 20),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu                 // 浮在浮动条之上
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true          // 提示不抢鼠标,避免和按钮 tracking 打架
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: p.contentView?.bounds ?? .zero)
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11, weight: .medium)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        bg.addSubview(field)
        p.contentView = bg
        label = field
        panel = p
        return p
    }
}
