import Cocoa
import SwiftUI

/// 菜单栏小工具面板的通用外壳(毛玻璃 + 淡紫渐变 + 品牌色标题 + 关闭钮),
/// 与系统监控 / 磁盘清理面板一致。系统维护、启动项面板共用。
@MainActor
final class ToolPanel {
    private static var all: [ToolPanel] = []

    private var panel: KeyablePanel?
    private let title: String
    private let symbol: String
    private let size: NSSize
    private let makeContent: () -> AnyView
    private let onShow: () -> Void

    init(title: String, symbol: String, size: NSSize,
         onShow: @escaping () -> Void = {}, content: @escaping () -> AnyView) {
        self.title = title
        self.symbol = symbol
        self.size = size
        self.onShow = onShow
        self.makeContent = content
        Self.all.append(self)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 供 SelectionMonitor 判断:面板内的点击不触发划词取词
    static func anyContains(_ cocoaPoint: NSPoint) -> Bool {
        all.contains { $0.panel?.isVisible == true && $0.panel!.frame.contains(cocoaPoint) }
    }

    func toggle() { isVisible ? close() : show() }

    func show() {
        let theme = PanelTheme.current
        let p = panel ?? makePanel()
        panel = p
        p.contentView = buildContent(theme: theme)
        if !p.isVisible { position(p) }
        NSApp.activateForUI()
        p.makeKeyAndOrderFront(nil)
        onShow()
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in self?.close() }
        return p
    }

    private func buildContent(theme: PanelTheme) -> NSView {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = theme.surfaceBorder.cgColor

        let tint = GradientView(top: theme.gradientTop, bottom: theme.gradientBottom)
        tint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tint)

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let logo = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        logo.contentTintColor = theme.brandText
        logo.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = theme.brandText
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        let close = ClosureButton(title: "") { [weak self] in self?.close() }
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("关闭 (Esc)", "Close (Esc)"))
        close.imagePosition = .imageOnly
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = L10n.t("关闭 (Esc)", "Close (Esc)")
        close.widthAnchor.constraint(equalToConstant: 24).isActive = true
        close.heightAnchor.constraint(equalToConstant: 22).isActive = true
        for v in [logo, titleLabel, spring, close] { header.addArrangedSubview(v) }
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let host = FirstMouseHostingView(rootView: makeContent())
        host.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(host)
        host.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        host.setContentHuggingPriority(.init(1), for: .vertical)

        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.topAnchor.constraint(equalTo: root.topAnchor),
            tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        return root
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let h = min(size.height, f.height - 16)
        p.setContentSize(NSSize(width: size.width, height: h))
        let s = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: max(f.minY + 8, f.maxY - s.height - 48)))
    }
}
