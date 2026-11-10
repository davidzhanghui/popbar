import Cocoa
import ServiceManagement
import PopBarCore
import PopBarPlatform
import PopBarDesign

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// 录制前的菜单栏图标,停止后还原
    private var baseStatusImage: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()
        ConfigStore.shared.start()
        MainActor.assumeIsolated {
            applyConfigSideEffects()
            ModuleRegistry.shared.apply()
            HotkeyManager.shared.apply(force: true)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged),
                                               name: ConfigStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordStateChanged),
                                               name: RecordSession.stateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordTicked(_:)),
                                               name: RecordSession.ticked, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pomodoroTicked),
                                               name: Pomodoro.ticked, object: nil)
        SelectionMonitor.shared.start()

        // 首次启动、或划词必需的权限缺失：打开 Deck 的欢迎与权限页（代替以前的阻塞弹窗）
        // 输入监控：CGEventTap 听拖拽/双击；只有辅助功能时 ⌃⌥B 能弹条，鼠标划词不会
        let needsWelcome = !ConfigStore.shared.config.onboarded
            || !AXSupport.isTrusted
            || !CGPreflightListenEventAccess()
            || !SelectionMonitor.shared.tapInstalled
        if needsWelcome {
            MainActor.assumeIsolated { DeckController.shared.show(page: .welcome) }
        }
        // 智能建议:启动 60s 后,每周最多问一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            UsageStats.shared.maybeSuggest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecordSession.shared.stopSynchronously()   // 退出时仍在录制:同步收尾,保证文件可播放
        ClipboardHistory.shared.save()             // persist 开启时兜底写盘
        MainActor.assumeIsolated { ModuleRegistry.shared.stopAll() }
    }

    /// Dock / Finder 再次打开 App:直接打开 Deck
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { DeckController.shared.show() }
        return true
    }

    /// 配置改动即时生效:外观、开机启动、模块开关、快捷键
    @objc private func configChanged() {
        MainActor.assumeIsolated {
            applyConfigSideEffects()
            let before = ModuleRegistry.shared.enabledIDs
            ModuleRegistry.shared.apply()
            if before != ModuleRegistry.shared.enabledIDs { DeckController.shared.modulesChanged() }
            HotkeyManager.shared.apply()
            if ConfigStore.shared.config.selectionPaused { FloatingBarController.shared.hide() }
        }
    }

    @MainActor private func applyConfigSideEffects() {
        let c = ConfigStore.shared.config
        switch c.appearance {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:  NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
        let enabled = SMAppService.mainApp.status == .enabled
        if c.launchAtLogin != enabled {
            try? c.launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
        if ModuleRegistry.shared.isEnabled("clipboard") { ClipboardHistory.shared.applyConfig() }
        if ModuleRegistry.shared.isEnabled("today") { Pomodoro.shared.applyConfig() }
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 用 AppIcon 做菜单栏图标,失败则回退 Lucide
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            icon.size = NSSize(width: 18, height: 18)
            item.button?.image = icon
        } else {
            item.button?.image = Lucide.image("text-cursor-input", size: 16)
        }
        baseStatusImage = item.button?.image
        // 不走 item.menu 自动弹菜单——左键行为可配置,右键始终弹菜单
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        MainActor.assumeIsolated {
            if NSApp.currentEvent?.type == .rightMouseUp {
                showStatusMenu()
                return
            }
            switch ConfigStore.shared.config.trayClick {
            case .input:     TranslateTriggers.input()
            case .clipboard: TranslateTriggers.clipboard()
            case .deck:      DeckController.shared.toggle()
            case .menu:      showStatusMenu()
            }
        }
    }

    @MainActor private func showStatusMenu() {
        guard let item = statusItem else { return }
        // 临时挂回 item.menu 再 performClick,让系统按菜单栏菜单弹出;
        // 手动 popUp 会画成下拉列表样式,顶部带一个多余的箭头
        item.menu = buildStatusMenu()
        item.button?.performClick(nil)
        DispatchQueue.main.async { item.menu = nil }
    }

    /// 菜单栏菜单只留高频入口(≤10 项),其余都在 Deck 里:
    /// 打开 Deck / 截屏 / 录屏(停止录制) / 暂停划词 / 设置… / 退出
    @MainActor private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let hk = ConfigStore.shared.config.hotkeys
        menu.addItem(AppRouter.menuItem(L10n.t("打开 Deck", "Open Deck"), hotkey: hk.deck) { DeckController.shared.show() })
        menu.addItem(AppRouter.menuItem(L10n.t("输入翻译", "Type to Translate"), hotkey: hk.inputTranslate) {
            TranslateTriggers.input()
        })
        let moduleItems = ModuleRegistry.shared.enabled.flatMap { $0.menuItems() }
        if !moduleItems.isEmpty {
            menu.addItem(.separator())
            moduleItems.forEach { menu.addItem($0) }
        }
        if RecordSession.shared.isRecording && RecordSession.shared.hasHiddenPanel {
            menu.addItem(AppRouter.menuItem(L10n.t("显示录制面板", "Show Recording Panel")) { RecordSession.shared.showPanel() })
        }
        menu.addItem(.separator())
        let paused = ConfigStore.shared.config.selectionPaused
        let pause = AppRouter.menuItem(L10n.t("暂停划词", "Pause Selection")) {
            var c = ConfigStore.shared.config
            c.selectionPaused.toggle()
            try? ConfigStore.shared.save(c)
        }
        pause.state = paused ? .on : .off
        menu.addItem(pause)
        let settings = AppRouter.menuItem(L10n.t("设置…", "Settings…")) { AppRouter.openSettings() }
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = AppRouter.menuItem(L10n.t("退出 PopBar", "Quit PopBar")) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
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

    // MARK: - 菜单栏指示

    @objc @MainActor private func pomodoroTicked() {
        guard let item = statusItem, let button = item.button, !RecordSession.shared.isRecording else { return }
        let p = Pomodoro.shared
        if p.started {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = (p.phase == .focus ? "" : "☕ ") + PomodoroMath.format(p.remaining)
        } else {
            button.title = ""
        }
    }

    /// 录制中把菜单栏图标换成红点 + mm:ss 计时
    @objc @MainActor private func recordStateChanged() {
        guard let item = statusItem, let button = item.button else { return }
        if RecordSession.shared.isRecording {
            button.image = Lucide.image("circle-dot", size: 16)
            button.contentTintColor = RecordSession.shared.isPaused ? Theme.warning : Theme.danger
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = RecordUtil.durationText(RecordSession.shared.duration)
            item.length = 74          // 固定宽度,避免计时文本抖动
        } else {
            button.image = baseStatusImage
            button.contentTintColor = nil
            button.title = ""
            item.length = NSStatusItem.variableLength
        }
    }

    @objc @MainActor private func recordTicked(_ note: Notification) {
        guard let item = statusItem, let button = item.button,
              RecordSession.shared.isRecording,
              let d = note.userInfo?["duration"] as? TimeInterval else { return }
        button.title = RecordUtil.durationText(d)
    }
}
