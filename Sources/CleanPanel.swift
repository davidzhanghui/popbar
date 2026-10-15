import Cocoa
import SwiftUI

/// 菜单栏「磁盘清理」:扫描缓存、日志、构建产物与卸载残留,勾选后移入废纸篓。
/// 外壳与系统监控面板一致;打开即自动扫描,关闭即取消。
@MainActor
final class CleanPanel {
    static let shared = CleanPanel()

    private var panel: KeyablePanel?
    private var model = CleanViewModel()
    private let panelSize = NSSize(width: 600, height: 700)

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowID: Int { panel?.windowNumber ?? 0 }
    var viewModel: CleanViewModel { model }

    /// 供 SelectionMonitor 判断:面板内的点击不触发划词取词
    static func contains(_ cocoaPoint: NSPoint) -> Bool {
        guard let p = shared.panel, p.isVisible else { return false }
        return p.frame.contains(cocoaPoint)
    }

    /// 仅截图工具使用:换成沙箱 home,文档配图里不出现个人目录
    func useHome(_ home: URL) { model = CleanViewModel(home: home) }

    func toggle() { isVisible ? close() : show() }

    func show() {
        let theme = PanelTheme.current
        let p = panel ?? makePanel()
        panel = p
        p.contentView = buildContent(theme: theme)
        if !p.isVisible { position(p) }
        NSApp.activateForUI()
        p.makeKeyAndOrderFront(nil)
        model.scan()
    }

    func close() {
        model.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: panelSize),
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
        let logo = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        logo.contentTintColor = theme.brandText
        logo.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let title = NSTextField(labelWithString: L10n.t("磁盘清理", "Disk Cleanup"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = theme.brandText
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
        for v in [logo, title, spring, close] { header.addArrangedSubview(v) }
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let host = FirstMouseHostingView(rootView: CleanView(vm: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(host)
        host.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        // 窗口高度固定,内容区纵向优先吃掉剩余空间,条目再少底栏也固定在窗口底部
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
        let h = min(panelSize.height, f.height - 16)
        p.setContentSize(NSSize(width: panelSize.width, height: h))
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                 y: max(f.minY + 8, f.maxY - size.height - 48)))
    }
}
