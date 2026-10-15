import Cocoa
import SwiftUI

/// 菜单栏「系统监控」:弹出 CPU / GPU / 内存 / 电池 / 磁盘 / 网络 / 温度 / 进程的实时面板。
/// 外壳与翻译面板一致(毛玻璃 + 淡紫渐变 + 品牌色标题);采样只在面板可见时运行,
/// 关闭即停,不影响 PopBar 空闲时 CPU ≈ 0 的特性。
/// 面板不在前台时,第一次点击也直接生效(否则点进程行只是把窗口激活,要点两次)
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class SystemMonitorPanel {
    static let shared = SystemMonitorPanel()

    private var panel: KeyablePanel?
    private let model = SystemMonitorModel()
    private let panelSize = NSSize(width: 640, height: 720)

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowID: Int { panel?.windowNumber ?? 0 }
    /// 仅截图工具使用,见 SystemMonitorModel.groupFilter
    var groupFilter: ((ProcessGroup) -> Bool)? {
        get { model.groupFilter }
        set { model.groupFilter = newValue }
    }

    /// 供 SelectionMonitor 判断:面板内的点击不触发划词取词
    static func contains(_ cocoaPoint: NSPoint) -> Bool {
        guard let p = shared.panel, p.isVisible else { return false }
        return p.frame.contains(cocoaPoint)
    }

    /// 菜单项:已打开则关闭,否则打开
    func toggle() {
        isVisible ? close() : show()
    }

    /// 仅截图工具使用:打开指定应用名的进程详情
    func openDetail(named name: String) {
        guard let g = model.snap.groups.first(where: { $0.name == name }) else { return }
        model.openDetail(g)
    }

    func show() {
        let theme = PanelTheme.current
        let p = panel ?? makePanel()
        panel = p
        p.contentView = buildContent(theme: theme)
        if !p.isVisible { position(p) }
        model.start()
        NSApp.activateForUI()
        p.makeKeyAndOrderFront(nil)
    }

    /// Esc:详情窗开着先关详情,再按一次才关面板(搜索框聚焦时的 Esc 也走这里)
    private func handleEscape() {
        if model.detailKey != nil { model.closeDetail() } else { close() }
    }

    func close() {
        model.closeDetail()
        model.stop()
        panel?.orderOut(nil)
    }

    // MARK: - 构建

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
        p.onEscape = { [weak self] in self?.handleEscape() }
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
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        // 头部:图标 + 标题 + 关闭
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let logo = NSImageView(image: NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                                              accessibilityDescription: nil) ?? NSImage())
        logo.contentTintColor = theme.brandText
        logo.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let title = NSTextField(labelWithString: L10n.t("系统监控", "System Monitor"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = theme.brandText
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        let close = ClosureButton(title: "") { [weak self] in self?.close() }
        close.image = NSImage(systemSymbolName: "xmark",
                              accessibilityDescription: L10n.t("关闭 (Esc)", "Close (Esc)"))
        close.imagePosition = .imageOnly
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = L10n.t("关闭 (Esc)", "Close (Esc)")
        close.widthAnchor.constraint(equalToConstant: 24).isActive = true
        close.heightAnchor.constraint(equalToConstant: 22).isActive = true
        for v in [logo, title, spring, close] { header.addArrangedSubview(v) }
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let host = FirstMouseHostingView(rootView: SystemMonitorView(vm: model, onClose: { [weak self] in self?.handleEscape() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(host)
        host.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: 640).isActive = true

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

    /// 屏幕居中偏上,与翻译面板的默认位置一致
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
