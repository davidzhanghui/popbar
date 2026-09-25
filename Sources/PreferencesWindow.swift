import Cocoa
import ServiceManagement

/// 「偏好设置」窗口:分组列表样式,每个改动立即写入 config.json 并生效。
/// 与「AI 翻译设置」不同——这里没有草稿态,不需要点保存。
final class PreferencesWindowController: NSObject {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var segs: [NSSegmentedControl] = []
    private var switches: [NSSwitch] = []

    private let lightTheme = PanelTheme(dark: false)
    private let darkTheme = PanelTheme(dark: true)
    private func dyn(_ l: NSColor, _ d: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
    }
    private var surfaceColor: NSColor { dyn(lightTheme.surface, darkTheme.surface) }
    private var borderTint: NSColor { dyn(lightTheme.surfaceBorder, darkTheme.surfaceBorder) }
    private var accentText: NSColor { dyn(lightTheme.brandText, darkTheme.brandText) }

    private var segKeys: [ObjectIdentifier: (key: String, values: [String])] = [:]
    private var switchKeys: [ObjectIdentifier: String] = [:]

    var isVisible: Bool { window?.isVisible ?? false }
    var frame: CGRect { window?.frame ?? .zero }

    // MARK: - 显示

    func show() {
        if window == nil { buildWindow() }
        rebuild()          // 语言切换后重建界面,文字即时生效
        syncControls()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        window = w
    }

    // MARK: - 界面

    private func rebuild() {
        guard let w = window else { return }
        w.title = L10n.t("偏好设置", "Preferences")
        segs.removeAll()
        switches.removeAll()
        segKeys.removeAll()
        switchKeys.removeAll()

        let root = NSView()
        let bg = GradientView(top: dyn(lightTheme.gradientTop, darkTheme.gradientTop),
                              bottom: dyn(lightTheme.gradientBottom, darkTheme.gradientBottom))
        bg.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bg.topAnchor.constraint(equalTo: root.topAnchor),
            bg.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 14
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            main.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        // 偏好
        main.addArrangedSubview(sectionHeader(L10n.t("偏好", "Preferences")))
        main.addArrangedSubview(card([
            row(L10n.t("外观", "Appearance"),
                L10n.t("浅色、深色,或跟随系统", "Light, Dark, or follow system"),
                seg("appearance", L10n.t("跟随系统", "System"), L10n.t("浅色", "Light"), L10n.t("深色", "Dark"),
                    values: ["system", "light", "dark"])),
            row(L10n.t("语言", "Language"),
                L10n.t("界面语言,立即生效", "UI language, applies instantly"),
                seg("language", L10n.t("跟随系统", "System"), "English", "中文",
                    values: ["system", "en", "zh"])),
            row(L10n.t("托盘图标", "Tray Icon"),
                L10n.t("左键点击菜单栏 PopBar 图标", "Left-click action on the menu bar icon"),
                seg("trayClick", L10n.t("菜单", "Menu"), L10n.t("输入翻译", "Input"), L10n.t("剪贴板翻译", "Clipboard"),
                    values: ["menu", "input", "clipboard"])),
            row(L10n.t("面板位置", "Panel Position"),
                L10n.t("翻译面板弹出的位置", "Where the translation panel appears"),
                seg("panelPosition", L10n.t("屏幕中上方", "Top Center"), L10n.t("跟随鼠标", "At Cursor"),
                    values: ["top", "cursor"])),
            row(L10n.t("划词触发", "Trigger"),
                L10n.t("弹出浮动工具条的方式", "How the floating bar appears"),
                seg("triggerMode", L10n.t("拖拽+双击", "Drag+Click"), L10n.t("仅拖拽", "Drag"), L10n.t("仅双击", "DblClick"),
                    values: ["both", "drag", "doubleClick"])),
            row(L10n.t("剪贴板取词", "Clipboard Fallback"),
                L10n.t("读不到选区时模拟 ⌘C 兜底", "Simulate ⌘C when selection can't be read"),
                toggle("clipboardFallback")),
            row(L10n.t("开机启动", "Launch at Login"),
                L10n.t("登录后自动运行 PopBar", "Start PopBar automatically after login"),
                toggle("launchAtLogin")),
        ]))

        // 关于
        main.addArrangedSubview(sectionHeader(L10n.t("关于", "About")))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let versionLabel = NSTextField(labelWithString: version)
        versionLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        let pathLabel = NSTextField(labelWithString:
            PopBarConfig.directoryURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let openButton = ClosureButton(title: L10n.t("打开", "Open")) {
            PopBarConfig.ensureExists()
            NSWorkspace.shared.activateFileViewerSelecting([PopBarConfig.fileURL])
        }
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        main.addArrangedSubview(card([
            row(L10n.t("版本", "Version"),
                L10n.t("当前版本", "Current version"),
                versionLabel),
            row(L10n.t("配置目录", "Config Folder"),
                L10n.t("provider、提示词与这些设置", "Providers, prompts and these preferences"),
                NSStackView(views: [pathLabel, openButton])),
        ]))

        for view in main.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        }
        root.widthAnchor.constraint(equalToConstant: 560).isActive = true
        w.contentView = root
        root.layoutSubtreeIfNeeded()
        w.setContentSize(NSSize(width: 560, height: root.fittingSize.height))
    }

    private func sectionHeader(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabelColor
        let wrap = NSView()
        wrap.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14).isActive = true
        l.topAnchor.constraint(equalTo: wrap.topAnchor).isActive = true
        l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor).isActive = true
        return wrap
    }

    /// 一行:左标题+副标题,右控件
    private func row(_ title: String, _ subtitle: String, _ control: NSView) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        let s = NSTextField(labelWithString: subtitle)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [t, s])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        // 弹性 spacer 吸收所有剩余宽度,把控件顶到卡片右缘,保证所有行右对齐
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        spring.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let r = NSStackView(views: [labels, spring, control])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 12
        r.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return r
    }

    /// 卡片:多行 + 行间分隔线
    private func card(_ rows: [NSView]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 0
        for (i, r) in rows.enumerated() {
            col.addArrangedSubview(r)
            r.leadingAnchor.constraint(equalTo: col.leadingAnchor).isActive = true
            r.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
            if i < rows.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                col.addArrangedSubview(sep)
                sep.leadingAnchor.constraint(equalTo: col.leadingAnchor, constant: 14).isActive = true
                sep.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
            }
        }
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = borderTint
        box.fillColor = surfaceColor
        box.contentViewMargins = .zero
        col.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(col)
        if let host = box.contentView {
            NSLayoutConstraint.activate([
                col.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                col.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                col.topAnchor.constraint(equalTo: host.topAnchor),
                col.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        return box
    }

    private func seg(_ key: String, _ titles: String..., values: [String]) -> NSSegmentedControl {
        let s = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: self,
                                   action: #selector(segChanged(_:)))
        s.controlSize = .regular
        segs.append(s)
        segKeys[ObjectIdentifier(s)] = (key, values)
        return s
    }

    private func toggle(_ key: String) -> NSSwitch {
        let s = NSSwitch()
        s.controlSize = .small
        s.target = self
        s.action = #selector(switchChanged(_:))
        switches.append(s)
        switchKeys[ObjectIdentifier(s)] = key
        return s
    }

    // MARK: - 控件 ↔ 配置

    private func syncControls() {
        let c = ConfigStore.shared.config
        for s in segs {
            guard let (key, values) = segKeys[ObjectIdentifier(s)] else { continue }
            let current: String
            switch key {
            case "appearance":    current = c.appearance
            case "language":      current = c.language
            case "trayClick":     current = c.trayClick
            case "panelPosition": current = c.panelPosition
            case "triggerMode":   current = c.triggerMode
            default: continue
            }
            s.selectedSegment = max(0, values.firstIndex(of: current) ?? 0)
        }
        for s in switches {
            switch switchKeys[ObjectIdentifier(s)] {
            case "clipboardFallback": s.state = c.clipboardFallback ? .on : .off
            case "launchAtLogin":
                // 以系统实际登录项状态为准(用户可能在系统设置里关过)
                s.state = SMAppService.mainApp.status == .enabled ? .on : .off
            default: break
            }
        }
    }

    @objc private func segChanged(_ sender: NSSegmentedControl) {
        guard let (key, values) = segKeys[ObjectIdentifier(sender)],
              sender.selectedSegment >= 0, sender.selectedSegment < values.count else { return }
        var c = ConfigStore.shared.config
        let v = values[sender.selectedSegment]
        switch key {
        case "appearance":    c.appearance = v
        case "language":      c.language = v
        case "trayClick":     c.trayClick = v
        case "panelPosition": c.panelPosition = v
        case "triggerMode":   c.triggerMode = v
        default: return
        }
        try? ConfigStore.shared.save(c)
        if key == "language" {          // 本窗口的文字也要跟着换
            rebuild()
            syncControls()
        }
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        guard let key = switchKeys[ObjectIdentifier(sender)] else { return }
        var c = ConfigStore.shared.config
        switch key {
        case "clipboardFallback":
            c.clipboardFallback = sender.state == .on
        case "launchAtLogin":
            c.launchAtLogin = sender.state == .on
            do {
                if c.launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
                c.launchAtLogin = sender.state == .on
            }
        default: return
        }
        try? ConfigStore.shared.save(c)
    }
}
