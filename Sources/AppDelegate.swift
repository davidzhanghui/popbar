import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let monitor = SelectionMonitor()
    /// 打开菜单栏菜单时记录的前台 App(「在此 App 中禁用」用);
    /// accessory 应用点菜单栏图标不会改变 frontmostApplication
    private var menuFrontApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()
        ConfigStore.shared.start()
        applyConfigSideEffects()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged),
                                               name: ConfigStore.didChange, object: nil)
        let trusted = promptAccessibility()
        monitor.start()
        if !trusted || !monitor.tapInstalled {
            showPermissionAlert()
        }
        // #20 智能建议:启动 60s 后,每周最多问一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            UsageStats.shared.maybeSuggest()
        }
    }

    /// 偏好改动即时生效:外观、开机启动
    @objc private func configChanged() { applyConfigSideEffects() }

    private func applyConfigSideEffects() {
        let c = ConfigStore.shared.config
        switch c.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
        let enabled = SMAppService.mainApp.status == .enabled
        if c.launchAtLogin != enabled {
            try? c.launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
        ClipboardHistory.shared.applyConfig()   // #8 启停轮询
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 用 AppIcon 做菜单栏图标,失败则回退 SF 符号
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            icon.size = NSSize(width: 18, height: 18)
            item.button?.image = icon
        } else {
            item.button?.image = NSImage(systemSymbolName: "cursorarrow.rays",
                                         accessibilityDescription: "PopBar")
        }
        // 不走 item.menu 自动弹菜单——左键行为可配置(菜单/输入翻译/剪贴板翻译),
        // 右键始终弹菜单
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu(); return }
        switch ConfigStore.shared.config.trayClick {
        case "input":     TranslateTriggers.input()
        case "clipboard": TranslateTriggers.clipboard()
        default:          showStatusMenu()
        }
    }

    private func showStatusMenu() {
        guard let item = statusItem else { return }
        menuFrontApp = NSWorkspace.shared.frontmostApplication
        // 临时挂回 item.menu 再 performClick,让系统按菜单栏菜单弹出;
        // 手动 popUp 会画成下拉列表样式,顶部带一个多余的箭头
        item.menu = buildStatusMenu()
        item.button?.performClick(nil)
        // performClick 返回后菜单已弹出,下一轮 runloop 摘掉恢复自定义点击分发
        DispatchQueue.main.async { item.menu = nil }
    }

    /// 每次弹出前重建,语言偏好即时生效
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: L10n.t("启用划词弹条", "Selection Bar"),
                                action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = monitor.enabled ? .on : .off
        menu.addItem(toggle)

        // #2 在『当前 App』中禁用/启用划词弹条
        if let app = menuFrontApp,
           let bid = app.bundleIdentifier,
           bid != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? bid
            let disabled = ConfigStore.shared.config.appRule(for: bid)?.mode == "disabled"
            let ruleItem = NSMenuItem(
                title: disabled ? L10n.t("在「\(name)」中启用弹条", "Enable in \(name)")
                                : L10n.t("在「\(name)」中禁用弹条", "Disable in \(name)"),
                action: #selector(toggleAppRule(_:)), keyEquivalent: "")
            ruleItem.target = self
            ruleItem.representedObject = app
            menu.addItem(ruleItem)
        }

        menu.addItem(.separator())
        for (title, sel) in [
            (L10n.t("截图翻译(OCR)", "Screenshot Translate"), #selector(screenshotTranslateAction)),
            (L10n.t("输入翻译", "Input Translate"), #selector(inputTranslateAction)),
            (L10n.t("剪贴板翻译", "Clipboard Translate"), #selector(clipboardTranslateAction)),
        ] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        // #8 剪贴板历史(enabled 时)
        if let hist = ClipboardHistory.shared.menuItem() {
            hist.target = self
            menu.addItem(hist)
        }

        menu.addItem(.separator())

        let translate = NSMenuItem(title: L10n.t("AI 翻译设置…", "AI Translation…"),
                                   action: #selector(openTranslateConfigAction), keyEquivalent: "")
        translate.target = self
        menu.addItem(translate)

        let prefs = NSMenuItem(title: L10n.t("偏好设置…", "Preferences…"),
                               action: #selector(openPreferencesAction), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let ax = NSMenuItem(title: L10n.t("辅助功能设置…", "Accessibility…"),
                            action: #selector(openAXSettings), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.t("退出 PopBar", "Quit PopBar"),
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// accessory 应用默认没有主菜单,文本框里的 ⌘C/⌘V/⌘A/⌘Z 都依赖 Edit 菜单分发
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.t("关闭窗口", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: L10n.t("退出 PopBar", "Quit PopBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L10n.t("编辑", "Edit"))
        edit.addItem(withTitle: L10n.t("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L10n.t("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.t("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.t("复制", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.t("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.t("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: - 权限

    @discardableResult
    private func promptAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func showPermissionAlert() {
        let a = NSAlert()
        a.messageText = L10n.t("需要「辅助功能」权限", "Accessibility Permission Required")
        a.informativeText = L10n.t(
            "PopBar 需要监听鼠标划词并读取选中文字。\n请在 系统设置 → 隐私与安全性 → 辅助功能 中允许 PopBar,然后重新启动应用。",
            "PopBar needs to watch mouse selection and read selected text.\nPlease allow PopBar in System Settings → Privacy & Security → Accessibility, then relaunch.")
        a.addButton(withTitle: L10n.t("打开设置", "Open Settings"))
        a.addButton(withTitle: L10n.t("稍后", "Later"))
        NSApp.activateForUI()          // 登录项启动时 App 不在前台,弹窗会被盖住
        if a.runModal() == .alertFirstButtonReturn {
            openAXSettings()
        }
    }

    // MARK: - 菜单动作

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        monitor.enabled = !monitor.enabled
        sender.state = monitor.enabled ? .on : .off
        if !monitor.enabled {
            FloatingBarController.shared.hide()
            TranslationPanelController.shared.close()
        }
    }

    /// 菜单栏快捷开关:在当前 App 中禁用/启用弹条
    @objc private func toggleAppRule(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication,
              let bid = app.bundleIdentifier else { return }
        var c = ConfigStore.shared.config
        if let i = c.appRules.firstIndex(where: { $0.bundleID == bid }) {
            if c.appRules[i].mode == "disabled" {
                c.appRules.remove(at: i)   // 重新启用=删掉规则
            } else {
                c.appRules[i].mode = "disabled"
            }
        } else {
            c.appRules.append(AppRule(bundleID: bid,
                                      name: app.localizedName ?? bid, mode: "disabled"))
        }
        try? ConfigStore.shared.save(c)
    }

    @objc private func openTranslateConfigAction() {
        AppDelegate.openTranslateConfig()
    }

    @objc private func screenshotTranslateAction() { TranslateTriggers.screenshot() }
    @objc private func inputTranslateAction() { TranslateTriggers.input() }
    @objc private func clipboardTranslateAction() { TranslateTriggers.clipboard() }

    @objc private func openPreferencesAction() {
        PreferencesWindowController.shared.show()
    }

    /// 打开 AI 翻译设置窗口
    static func openTranslateConfig() {
        SettingsWindowController.shared.show()
    }

    @objc private func openAXSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
