import Cocoa
import ServiceManagement

/// 「偏好设置」窗口:分组列表样式,每个改动立即写入 config.json 并生效。
/// 与「AI 翻译设置」不同——这里没有草稿态,不需要点保存。
final class PreferencesWindowController: NSObject, NSTextFieldDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var segs: [NSSegmentedControl] = []
    private var switches: [NSSwitch] = []
    private var textFields: [NSTextField] = []
    private var textFieldKeys: [ObjectIdentifier: String] = [:]

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

    /// 当前 tab 序号、各 tab 的滚动视图(切换时显隐)与顶部 tab 栏
    private var tabIndex = 0
    private var tabScrolls: [NSScrollView] = []
    private var tabHeights: [CGFloat] = []
    private var tabBarControl: NSSegmentedControl?

    var isVisible: Bool { window?.isVisible ?? false }
    var frame: CGRect { window?.frame ?? .zero }

    // MARK: - 显示

    func show() {
        if window == nil { buildWindow() }
        rebuild()          // 语言切换后重建界面,文字即时生效
        syncControls()
        NSApp.activateForUI()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = EscClosableWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
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
        textFields.removeAll()
        textFieldKeys.removeAll()

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

        // 顶部 tab 栏;每个 tab 一份独立滚动内容,切换时显隐
        let tabs: [(String, [NSView])] = [
            (L10n.t("通用", "General"), generalTab()),
            (L10n.t("功能", "Features"), featuresTab()),
            (L10n.t("工具条", "Toolbar"), toolbarTab()),
            (L10n.t("关于", "About"), aboutTab()),
        ]
        let tabBar = NSSegmentedControl(labels: tabs.map { $0.0 }, trackingMode: .selectOne,
                                        target: self, action: #selector(tabChanged(_:)))
        tabBar.selectedSegment = min(tabIndex, tabs.count - 1)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBarControl = tabBar
        root.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
        ])

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 12),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        tabScrolls = []
        tabHeights = []
        for (i, tab) in tabs.enumerated() {
            let (scroll, contentH) = contentScroll(tab.1)
            host.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: host.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            scroll.isHidden = i != tabIndex
            tabScrolls.append(scroll)
            tabHeights.append(contentH)
        }

        root.widthAnchor.constraint(equalToConstant: 560).isActive = true
        w.contentView = root
        root.layoutSubtreeIfNeeded()
        applyWindowHeight()
    }

    // MARK: - 各 tab 内容

    private func generalTab() -> [NSView] {
        [sectionHeader(L10n.t("偏好", "Preferences")), card([
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
            row(L10n.t("敏感信息", "Privacy Guard"),
                L10n.t("发给第三方 AI 前检查手机号/密钥等", "Check sensitive info before sending to AI"),
                seg("privacyGuard", L10n.t("询问", "Ask"), L10n.t("自动脱敏", "Auto-mask"), L10n.t("关闭", "Off"),
                    values: ["ask", "mask", "off"])),
            row(L10n.t("开机启动", "Launch at Login"),
                L10n.t("登录后自动运行 PopBar", "Start PopBar automatically after login"),
                toggle("launchAtLogin")),
        ])]
    }

    /// 功能(M5/M8):剪贴板历史、OCR、使用统计、快捷键
    private func featuresTab() -> [NSView] {
        let hotkeyField = NSTextField()
        hotkeyField.placeholderString = "ctrl+opt+space"
        hotkeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hotkeyField.delegate = self
        textFieldKeys[ObjectIdentifier(hotkeyField)] = "hotkeys.showBar"
        textFields.append(hotkeyField)
        return [sectionHeader(L10n.t("功能", "Features")), card([
            row(L10n.t("剪贴板历史", "Clipboard History"),
                L10n.t("记录最近剪贴板,菜单栏可选粘贴;跳过密码类标记",
                       "Recent clipboard items from the menu; skips concealed types"),
                toggle("clipHistory")),
            row(L10n.t("历史持久化", "Persist History"),
                L10n.t("重启后保留剪贴板历史(默认仅内存)",
                       "Keep clipboard history across restarts (memory-only by default)"),
                toggle("clipPersist")),
            row(L10n.t("OCR 结果", "OCR Result"),
                L10n.t("截图识别后弹翻译面板还是完整工具条",
                       "After screenshot OCR: translate panel or full action bar"),
                seg("ocrAfter", L10n.t("翻译面板", "Panel"), L10n.t("工具条", "Bar"),
                    values: ["panel", "bar"])),
            row(L10n.t("使用统计", "Usage Stats"),
                L10n.t("只记动作次数,不记文本;用于排序建议",
                       "Counts actions only, never text; powers ordering suggestions"),
                toggle("usageEnabled")),
            row(L10n.t("唤起快捷键", "Bar Hotkey"),
                L10n.t("格式 ctrl+opt+space;键盘选中后按它呼出工具条",
                       "Format: ctrl+opt+space; press after selecting via keyboard"),
                hotkeyField),
        ])]
    }

    /// 工具条(#3)与应用规则(#2)
    private func toolbarTab() -> [NSView] {
        [sectionHeader(L10n.t("工具条", "Toolbar")), ToolbarPrefsCard(),
         sectionHeader(L10n.t("应用规则", "Per-App Rules")), AppRulesPrefsCard()]
    }

    private func aboutTab() -> [NSView] {
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
        return [sectionHeader(L10n.t("关于", "About")), card([
            row(L10n.t("版本", "Version"),
                L10n.t("当前版本", "Current version"),
                versionLabel),
            row(L10n.t("配置目录", "Config Folder"),
                L10n.t("provider、提示词与这些设置", "Providers, prompts and these preferences"),
                NSStackView(views: [pathLabel, openButton])),
        ])]
    }

    /// 一个 tab 的内容装进滚动视图,行数超出可用高度时滚动;返回视图与内容高度
    private func contentScroll(_ views: [NSView]) -> (NSScrollView, CGFloat) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 14
        main.translatesAutoresizingMaskIntoConstraints = false
        for v in views {
            main.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        }
        // 内容高度:各块高度之和 + 块间距 + 上下留白。行高已固定,这里算出来就是准确值,
        // 不能等布局收敛后再量(卡片高度要过几轮才稳定)
        let contentH = views.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, views.count - 1)) * main.spacing + 32

        // flipped 容器:内容从顶部开始排,高度显式给出
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(main)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalToConstant: 560),
            doc.heightAnchor.constraint(equalToConstant: contentH),
            main.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            main.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            main.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            main.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
        ])
        return (scroll, contentH)
    }

    /// 高度取「当前 tab 内容高度」与「屏幕可用高度 - 40」中较小者;切换 tab 时顶部位置不动
    private func applyWindowHeight() {
        guard let w = window, tabHeights.indices.contains(tabIndex) else { return }
        // tab 栏与上下留白不参与滚动
        let chrome = 14 + (tabBarControl?.frame.height ?? 24) + 12
        let maxH = (NSScreen.main?.visibleFrame.height ?? 800) - 40
        let contentH = min(max(tabHeights[tabIndex] + chrome, 240), maxH)
        // setFrame 用的是含标题栏的窗口尺寸,所以要换算一次
        let frameH = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: contentH)).height
        var f = w.frame
        f.origin.y = f.maxY - frameH
        f.size.height = frameH
        w.setFrame(f, display: true, animate: false)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        tabIndex = max(0, min(sender.selectedSegment, tabScrolls.count - 1))
        for (i, s) in tabScrolls.enumerated() { s.isHidden = i != tabIndex }
        applyWindowHeight()
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
        // 行高显式给定:竖向堆栈自报的 fittingSize 会把行压小,导致卡片最后一行被裁
        let natural = max(labels.fittingSize.height, control.fittingSize.height) + 20
        r.heightAnchor.constraint(equalToConstant: natural).isActive = true
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
            case "privacyGuard":  current = c.privacy.guardMode
            case "ocrAfter":      current = c.ocr.after
            default: continue
            }
            s.selectedSegment = max(0, values.firstIndex(of: current) ?? 0)
        }
        for s in switches {
            switch switchKeys[ObjectIdentifier(s)] {
            case "clipboardFallback": s.state = c.clipboardFallback ? .on : .off
            case "clipHistory":  s.state = c.clipboardHistory.enabled ? .on : .off
            case "clipPersist":  s.state = c.clipboardHistory.persist ? .on : .off
            case "usageEnabled": s.state = c.usage.enabled ? .on : .off
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
        case "ocrAfter":      c.ocr.after = v
        case "privacyGuard":  c.privacy.guardMode = v
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
        case "clipHistory":   c.clipboardHistory.enabled = sender.state == .on
        case "clipPersist":   c.clipboardHistory.persist = sender.state == .on
        case "usageEnabled":  c.usage.enabled = sender.state == .on
        default: return
        }
        try? ConfigStore.shared.save(c)
    }

    /// 文本输入框(唤起快捷键):提交即写配置
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let key = textFieldKeys[ObjectIdentifier(field)] else { return }
        var c = ConfigStore.shared.config
        switch key {
        case "hotkeys.showBar":
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty || Hotkey.parse(v) != nil {
                c.hotkeys.showBar = v.isEmpty ? "ctrl+opt+space" : v
            } else {
                field.stringValue = c.hotkeys.showBar
                NSSound.beep()
                return
            }
        default: return
        }
        try? ConfigStore.shared.save(c)
    }
}
