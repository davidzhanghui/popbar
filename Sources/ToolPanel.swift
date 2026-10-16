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

    /// 可钉住的面板(今日待办):未钉住时点别处就收起;钉住后常驻、Esc 不关、记住位置
    private let pinnable: Bool
    private(set) var pinned: Bool
    private let onPinChanged: (Bool) -> Void
    private var resignObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var lastAutoClose = Date.distantPast

    init(title: String, symbol: String, size: NSSize,
         pinnable: Bool = false, pinned: Bool = false,
         onPinChanged: @escaping (Bool) -> Void = { _ in },
         onShow: @escaping () -> Void = {}, content: @escaping () -> AnyView) {
        self.title = title
        self.symbol = symbol
        self.size = size
        self.pinnable = pinnable
        self.pinned = pinned
        self.onPinChanged = onPinChanged
        self.onShow = onShow
        self.makeContent = content
        Self.all.append(self)
    }

    private var frameKey: String { "PopBarToolPanelFrame.\(symbol)" }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 供 SelectionMonitor 判断:面板内的点击不触发划词取词
    static func anyContains(_ cocoaPoint: NSPoint) -> Bool {
        all.contains { $0.panel?.isVisible == true && $0.panel!.frame.contains(cocoaPoint) }
    }

    func toggle() {
        if isVisible { close(); return }
        // 未钉住的面板在失焦时已自动收起:紧接着的这次「再点一下菜单项」应当理解为关闭
        if pinnable && Date().timeIntervalSince(lastAutoClose) < 0.5 { return }
        show()
    }

    /// 全局点击检测:未钉住的面板,点到面板外就收起。
    /// 不依赖 resignKey——非激活面板从全局热键唤起时 App 并不在前台,失焦通知不可靠
    func dismissIfUnpinned(clickAt point: NSPoint) {
        guard pinnable, !pinned, let p = panel, p.isVisible, !p.frame.contains(point) else { return }
        lastAutoClose = Date()
        close()
    }

    /// 启动时恢复被钉住的面板:只露出来,不抢前台焦点
    func restorePinned() {
        guard pinnable, pinned, !isVisible else { return }
        let p = panel ?? makePanel()
        panel = p
        p.contentView = buildContent(theme: PanelTheme.current)
        position(p)
        p.orderFrontRegardless()
        onShow()
    }

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
                             styleMask: pinnable ? [.borderless, .nonactivatingPanel] : [.borderless],
                             backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in
            guard let self, !(self.pinnable && self.pinned) else { return }
            self.close()
        }
        if pinnable {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.pinned, self.isVisible else { return }
                    self.lastAutoClose = Date()
                    self.close()
                }
            }
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.pinned, let f = self.panel?.frame else { return }
                    UserDefaults.standard.set(NSStringFromRect(f), forKey: self.frameKey)
                }
            }
        }
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
        var headerViews: [NSView] = [logo, titleLabel, spring]
        if pinnable {
            var refreshPin: () -> Void = {}
            let pin = ClosureButton(title: "") { [weak self] in
                guard let self else { return }
                self.pinned.toggle()
                self.onPinChanged(self.pinned)
                refreshPin()
            }
            pin.isBordered = false
            pin.imagePosition = .imageOnly
            pin.widthAnchor.constraint(equalToConstant: 24).isActive = true
            pin.heightAnchor.constraint(equalToConstant: 22).isActive = true
            refreshPin = { [weak self, weak pin] in
                guard let self, let pin else { return }
                pin.image = NSImage(systemSymbolName: self.pinned ? "pin.fill" : "pin",
                                    accessibilityDescription: L10n.t("钉住", "Pin"))
                pin.contentTintColor = self.pinned ? theme.brandText : .secondaryLabelColor
                pin.toolTip = self.pinned ? L10n.t("取消钉住:点别处就收起", "Unpin: closes when you click elsewhere")
                                          : L10n.t("钉住:常驻桌面,点别处不收起", "Pin: stays on screen when you click elsewhere")
            }
            refreshPin()
            headerViews.append(pin)
        }
        headerViews.append(close)
        for v in headerViews { header.addArrangedSubview(v) }
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
        // 钉住过的面板回到上次的位置(位置仍在某块屏幕内才用)
        if pinnable, let saved = UserDefaults.standard.string(forKey: frameKey) {
            let r = NSRectFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                p.setFrameOrigin(r.origin)
                return
            }
        }
        let s = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: max(f.minY + 8, f.maxY - s.height - 48)))
    }
}
