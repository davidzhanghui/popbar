import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let monitor = SelectionMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        let trusted = promptAccessibility()
        monitor.start()
        if !trusted || !monitor.tapInstalled {
            showPermissionAlert()
        }
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
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "启用划词弹条", action: #selector(toggleEnabled(_:)),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)

        let ax = NSMenuItem(title: "辅助功能设置…", action: #selector(openAXSettings),
                            keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 PopBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    // MARK: - 权限

    @discardableResult
    private func promptAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func showPermissionAlert() {
        let a = NSAlert()
        a.messageText = "需要「辅助功能」权限"
        a.informativeText = "PopBar 需要监听鼠标划词并读取选中文字。\n请在 系统设置 → 隐私与安全性 → 辅助功能 中允许 PopBar,然后重新启动应用。"
        a.addButton(withTitle: "打开设置")
        a.addButton(withTitle: "稍后")
        if a.runModal() == .alertFirstButtonReturn {
            openAXSettings()
        }
    }

    // MARK: - 菜单动作

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        monitor.enabled = !monitor.enabled
        sender.state = monitor.enabled ? .on : .off
        if !monitor.enabled { FloatingBarController.shared.hide() }
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
